#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

# Builds the Galaxy S21 Ultra 5G (Snapdragon) (p3q) kernel with KernelSU Next built-in.
#
# Usage: build_kernel.sh <kernel source dir> <output dir>
#
# If the kernel source dir does not exist, $KERNEL_REPO is fetched at $KERNEL_REF (both defined below).
# The following environment variables are considered:
#   CLANG_DIR: path to the clang toolchain root (default: clang in PATH)
#   JOBS: number of parallel make jobs (default: nproc)
#
# Output dir layout:
#   Image          Uncompressed kernel image
#   Image-dtb      Kernel image with the lahaina base DTBs appended
#   dtb            lahaina base DTBs (v1, v2, v2.1) concatenated
#   dtbo.img       DTBO image built from the p3q board overlays
#   modules/       Stripped kernel modules along with modules.dep/modules.alias/modules.softdep
#   kernel.release Kernel release string
#   ksu.version    KernelSU Next version code

set -eo pipefail

# [
# Kernel source by @yanzihan, based on the SM-G9980 (CHN/HKX) Samsung OSS release
KERNEL_REPO="https://github.com/yanzihan/android_kernel_samsung_sm8350-p3q"
KERNEL_REF="3af90cf2d876e1a5a853bc1270ee0ef29387bef0"
KERNEL_DEFCONFIG="vendor/p3q_chn_hkx_defconfig"
KERNEL_LOCALVERSION="-qgki-UN1CA-KSUN"
# p3q board revisions and lahaina base DTBs, in the same order as the stock dtbo.img/vendor_boot.img
# (both are byte-identical to the stock ones once ordered like this)
P3Q_DTBO_REVS=("r03" "r09" "r11" "r05" "r07")
LAHAINA_DTBS=("lahaina-v2.1.dtb" "lahaina-v2.dtb" "lahaina.dtb")

# KernelSU Next (legacy branch for non-GKI kernels)
KSUN_REPO="https://github.com/KernelSU-Next/KernelSU-Next"
KSUN_REF="v3.4.0-legacy"

KSRC=""
OUT=""
KOUT=""

LOG()
{
    echo -e "\033[1;37m[p3q kernel]\033[0m $*"
}

ABORT()
{
    echo -e "\033[1;31m[p3q kernel] $*\033[0m" >&2
    exit 1
}

KMAKE()
{
    make -C "$KSRC" O="$KOUT" -j"${JOBS:-$(nproc)}" \
        ARCH=arm64 LLVM=1 LLVM_IAS=1 \
        CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- \
        CONFIG_BUILD_ARM64_DT_OVERLAY=y CONFIG_SECTION_MISMATCH_WARN_ONLY=y \
        DISABLE_WRAPPER=1 SKIP_FIPS_HMAC=1 LOCALVERSION= "$@"
}

FETCH_KERNEL_SOURCE()
{
    LOG "- Fetching kernel source ($KERNEL_REF)"
    mkdir -p "$KSRC"
    git -C "$KSRC" init -q
    git -C "$KSRC" remote add origin "$KERNEL_REPO"
    git -C "$KSRC" fetch -q --depth 1 origin "$KERNEL_REF"
    git -C "$KSRC" checkout -q FETCH_HEAD
}

SETUP_KERNELSU_NEXT()
{
    LOG "- Setting up KernelSU Next ($KSUN_REF)"

    # Drop any other KernelSU implementation shipped in the tree
    rm -rf "$KSRC/KernelSU"
    rm -f "$KSRC/drivers/kernelsu"

    if [ ! -d "$KSRC/KernelSU-Next/.git" ]; then
        rm -rf "$KSRC/KernelSU-Next"
        # Full commit history is required, KernelSU Next computes its version from the commit count
        git clone -q --filter=blob:none "$KSUN_REPO" "$KSRC/KernelSU-Next"
    fi
    git -C "$KSRC/KernelSU-Next" fetch -q --tags origin
    git -C "$KSRC/KernelSU-Next" checkout -q "$KSUN_REF"

    ln -sf "../KernelSU-Next/kernel" "$KSRC/drivers/kernelsu"
    grep -q "kernelsu" "$KSRC/drivers/Makefile" || \
        printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$KSRC/drivers/Makefile"
    grep -q "source \"drivers/kernelsu/Kconfig\"" "$KSRC/drivers/Kconfig" || \
        sed -i "/endmenu/i\\source \"drivers/kernelsu/Kconfig\"" "$KSRC/drivers/Kconfig"

    echo "$((30000 + $(git -C "$KSRC/KernelSU-Next" rev-list --count HEAD) + 289))" > "$OUT/ksu.version"
}

GENERATE_CONFIG()
{
    LOG "- Generating kernel config ($KERNEL_DEFCONFIG)"
    KMAKE "$KERNEL_DEFCONFIG"

    # KernelSU Next: built-in driver, syscall table hooks (no manual hooks needed on 5.4 non-GKI)
    "$KSRC/scripts/config" --file "$KOUT/.config" \
        -d KSU_TAMPER_SYSCALL_TABLE \
        -d KSU_HACK_ARM64_BRANCH_LINK \
        -d KSU_KPROBES_KSUD \
        -e KSU \
        -d KSU_DEBUG \
        -d KSU_MANUAL_HOOK \
        -d KSU_KPROBES_HOOK \
        -e KSU_SYSCALL_TABLE_HOOK \
        --set-str LOCALVERSION "$KERNEL_LOCALVERSION" \
        -d LOCALVERSION_AUTO
    KMAKE olddefconfig

    local CFG
    for CFG in KSU KSU_SYSCALL_TABLE_HOOK KPROBES MODVERSIONS; do
        grep -q "^CONFIG_$CFG=y$" "$KOUT/.config" || ABORT "CONFIG_$CFG is not enabled"
    done
}

# https://android.googlesource.com/platform/system/libufdt/+/refs/heads/main/utils/src/mkdtboimg.py
MAKE_DTBO_IMAGE()
{
    python3 -I - "$@" << 'EOF'
import struct
import sys

out, dtbos = sys.argv[1], sys.argv[2:]
blobs = [open(f, "rb").read() for f in dtbos]
for f, b in zip(dtbos, blobs):
    if b[:4] != b"\xd0\x0d\xfe\xed":
        sys.exit("not a DTB: " + f)
header_size = 32
entry_size = 32
offset = header_size + entry_size * len(blobs)
total = offset + sum(len(b) for b in blobs)
data = struct.pack(">8I", 0xd7b7ab1e, total, header_size, entry_size, len(blobs), header_size, 4096, 0)
for b in blobs:
    data += struct.pack(">8I", len(b), offset, 0, 0, 0, 0, 0, 0)
    offset += len(b)
data += b"".join(blobs)
open(out, "wb").write(data)
EOF
}

BUILD_KERNEL()
{
    LOG "- Building kernel"
    # dtbs also builds the p3q board overlays (CONFIG_BUILD_ARM64_DT_OVERLAY)
    KMAKE Image modules dtbs
}

COLLECT_ARTIFACTS()
{
    local DTS_OUT="$KOUT/arch/arm64/boot/dts"

    LOG "- Collecting artifacts"
    cp -a "$KOUT/arch/arm64/boot/Image" "$OUT/Image"

    : > "$OUT/dtb"
    local DTB
    for DTB in "${LAHAINA_DTBS[@]}"; do
        [ -f "$DTS_OUT/vendor/qcom/$DTB" ] || ABORT "$DTB not found"
        cat "$DTS_OUT/vendor/qcom/$DTB" >> "$OUT/dtb"
    done
    cat "$OUT/Image" "$OUT/dtb" > "$OUT/Image-dtb"

    local DTBO_FILES=()
    local REV
    for REV in "${P3Q_DTBO_REVS[@]}"; do
        [ -f "$DTS_OUT/samsung/palette/p3q/p3q_chn_hkx_w00_$REV.dtbo" ] || ABORT "p3q_chn_hkx_w00_$REV.dtbo not found"
        DTBO_FILES+=("$DTS_OUT/samsung/palette/p3q/p3q_chn_hkx_w00_$REV.dtbo")
    done
    MAKE_DTBO_IMAGE "$OUT/dtbo.img" "${DTBO_FILES[@]}"

    KMAKE -s kernelrelease > "$OUT/kernel.release"

    # Install the modules in a temporary tree so that depmod generates modules.dep/modules.alias/modules.softdep,
    # then flatten it (vendor modules all live in /vendor/lib/modules)
    local MOD_TREE="$KOUT/modules_install"
    local MOD_DIR
    MOD_DIR="$MOD_TREE/lib/modules/$(cat "$OUT/kernel.release")"
    rm -rf "$MOD_TREE"
    KMAKE INSTALL_MOD_PATH="$MOD_TREE" INSTALL_MOD_STRIP=1 modules_install
    [ -f "$MOD_DIR/modules.dep" ] || ABORT "modules.dep not generated, is depmod (kmod) installed?"

    rm -rf "$OUT/modules"
    mkdir -p "$OUT/modules"
    while IFS= read -r f; do
        if [ -f "$OUT/modules/$(basename "$f")" ]; then
            ABORT "Duplicate module name: $(basename "$f")"
        fi
        cp -a "$f" "$OUT/modules/"
    done < <(find "$MOD_DIR" -name "*.ko" | sort)
    sed -E "s|[^ :]*/([^/ :]+\.ko)|\1|g" "$MOD_DIR/modules.dep" > "$OUT/modules/modules.dep"
    for f in modules.alias modules.softdep; do
        if [ -f "$MOD_DIR/$f" ]; then
            cp -a "$MOD_DIR/$f" "$OUT/modules/$f"
        fi
    done

    LOG "- Kernel release: $(cat "$OUT/kernel.release")"
    LOG "- KernelSU Next version: $(cat "$OUT/ksu.version")"
    LOG "- Modules: $(find "$OUT/modules" -name "*.ko" | wc -l)"
}
# ]

if [ "$#" != "2" ]; then
    echo "Usage: build_kernel.sh <kernel source dir> <output dir>" >&2
    exit 1
fi

KSRC="$(realpath -m "$1")"
mkdir -p "$2"
OUT="$(realpath "$2")"
KOUT="$KSRC/out"

[ -d "$KSRC" ] || FETCH_KERNEL_SOURCE
[ -f "$KSRC/Makefile" ] || ABORT "Kernel source not found: $KSRC"

if [ "$CLANG_DIR" ]; then
    export PATH="$CLANG_DIR/bin:$PATH"
fi
command -v clang &> /dev/null || ABORT "clang not found"
LOG "- Using $(clang --version | head -n 1)"

SETUP_KERNELSU_NEXT
GENERATE_CONFIG
BUILD_KERNEL
COLLECT_ARTIFACTS

exit 0
