# KernelSU Next enabled kernel, built with target/p3q/kernel/build_kernel.sh.
# The kernel artifacts are read from $P3Q_KERNEL_DIR (defaults to $OUT_DIR/kernel/p3q).
#
# - boot.img: kernel replaced with Image + lahaina base DTBs, stock header/ramdisk kept
# - dtbo.img: replaced with the p3q board overlays built from the same tree
# - /vendor/lib/modules: stock modules replaced with the ones built from the same tree
#   (the kernel is not ABI compatible with the stock modules)
# - vendor_boot.img: untouched, the drivers shipped in it as GKI modules are built-in

KERNEL_DIR="${P3Q_KERNEL_DIR:-$OUT_DIR/kernel/p3q}"

for f in "Image-dtb" "dtbo.img" "kernel.release"; do
    if [ ! -f "$KERNEL_DIR/$f" ]; then
        ABORT "File not found: $KERNEL_DIR/$f\n\nBuild the kernel first with:\n  target/p3q/kernel/build_kernel.sh <kernel source dir> $KERNEL_DIR"
    fi
done

if [ ! -f "$WORK_DIR/kernel/boot.img" ]; then
    ABORT "File not found: ${WORK_DIR//$SRC_DIR\//}/kernel/boot.img"
fi

if [ -d "$TMP_DIR" ]; then
    EVAL "rm -rf \"$TMP_DIR\""
fi
EVAL "mkdir -p \"$TMP_DIR\""

LOG_STEP_IN "- Installing kernel $(cat "$KERNEL_DIR/kernel.release")"

LOG "- Extracting boot.img"
EVAL "cp -a \"$WORK_DIR/kernel/boot.img\" \"$TMP_DIR/boot.img\""
if ! MKBOOTIMG_ARGS="$(unpack_bootimg --boot_img "$TMP_DIR/boot.img" --out "$TMP_DIR/boot" --format mkbootimg 2>&1)"; then
    ABORT "Failed to extract boot.img\n\n$MKBOOTIMG_ARGS"
fi
EVAL "rm -f \"$TMP_DIR/boot.img\""

LOG "- Replacing kernel image"
EVAL "cp -a \"$KERNEL_DIR/Image-dtb\" \"$TMP_DIR/boot/kernel\""

LOG "- Repacking boot.img"
EVAL "mkbootimg $MKBOOTIMG_ARGS -o \"$TMP_DIR/new-boot.img\""
echo -n "SEANDROIDENFORCE" >> "$TMP_DIR/new-boot.img"
EVAL "mv -f \"$TMP_DIR/new-boot.img\" \"$WORK_DIR/kernel/boot.img\""

LOG "- Replacing dtbo.img"
EVAL "cp -a \"$KERNEL_DIR/dtbo.img\" \"$WORK_DIR/kernel/dtbo.img\""

if [ -d "$KERNEL_DIR/modules" ]; then
    LOG_STEP_IN "- Replacing kernel modules in /vendor/lib/modules"
    EVAL "mkdir -p \"$TMP_DIR/root/vendor/lib/modules\""
    while IFS= read -r f; do
        MODULE="$(basename "$f")"
        if [ -f "$WORK_DIR/vendor/lib/modules/$MODULE" ]; then
            EVAL "cp -a \"$f\" \"$TMP_DIR/root/vendor/lib/modules/$MODULE\""
            ADD_TO_WORK_DIR "$TMP_DIR/root" "vendor" "lib/modules/$MODULE" 0 0 644 "u:object_r:vendor_file:s0"
        fi
    done < <(find "$KERNEL_DIR/modules" -maxdepth 1 -type f -name "*.ko" | LC_ALL=C sort)
    while IFS= read -r f; do
        MODULE="$(basename "$f")"
        if [ ! -f "$KERNEL_DIR/modules/$MODULE" ]; then
            LOGW "Stock module not rebuilt (built-in or unsupported): $MODULE"
        fi
    done < <(find "$WORK_DIR/vendor/lib/modules" -maxdepth 1 -type f -name "*.ko" | LC_ALL=C sort)
    LOG_STEP_OUT
fi

LOG_STEP_OUT

EVAL "rm -rf \"$TMP_DIR\""

unset KERNEL_DIR MODULE MKBOOTIMG_ARGS
