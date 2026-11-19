#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Galaxy S21 Ultra 5G (Snapdragon) (p3q) CI helper, run after extract_fw.sh:
# - prints a report of the extracted stock firmware and checks it against target/p3q/config.sh
# - copies the stock-derived files required by the build into target/p3q when missing
#   (they are also copied into $1 so that they can be uploaded and committed)
#
# Usage: prepare_p3q.sh <output dir>

set -eo pipefail

if [ "$#" != "1" ]; then
    echo "Usage: prepare_p3q.sh <output dir>" >&2
    exit 1
fi

OUT="$1"
mkdir -p "$OUT"

TARGET_DIR="$SRC_DIR/target/p3q"
SOURCE_FW="$FW_DIR/$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
TARGET_FW="$FW_DIR/$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
SDHMS="system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk"

ERRORS=0

GET_PROP()
{
    grep -m 1 "^$2=" "$1" 2> /dev/null | cut -d "=" -f 2-
}

CHECK()
{
    local NAME="$1"
    local EXPECTED="$2"
    local ACTUAL="$3"

    if [ ! "$ACTUAL" ]; then
        echo "[??]   $NAME: not found in stock firmware, config has \"$EXPECTED\""
    elif [[ "$EXPECTED" == "$ACTUAL" ]]; then
        echo "[OK]   $NAME: $ACTUAL"
    else
        echo "[FAIL] $NAME: config has \"$EXPECTED\", stock firmware has \"$ACTUAL\""
        ERRORS=$((ERRORS + 1))
    fi
}

COPY_IF_MISSING()
{
    local DEST="$1"
    local SRC="$2"

    if [ -f "$TARGET_DIR/$DEST" ]; then
        echo "- target/p3q/$DEST already present"
    elif [ -f "$SRC" ]; then
        echo "- Adding target/p3q/$DEST from stock firmware"
        mkdir -p "$(dirname "$TARGET_DIR/$DEST")" "$(dirname "$OUT/target/p3q/$DEST")"
        cp -a "$SRC" "$TARGET_DIR/$DEST"
        cp -a "$SRC" "$OUT/target/p3q/$DEST"
    else
        echo "! ${SRC//$FW_DIR\//} not found in stock firmware"
    fi
}

[ -d "$TARGET_FW" ] || { echo "Target firmware not extracted: $TARGET_FW" >&2; exit 1; }

{
    echo "========== p3q stock firmware report =========="
    echo "Target firmware: $(cat "$TARGET_FW/.extracted" 2> /dev/null)"
    echo "Source firmware: $(cat "$SOURCE_FW/.extracted" 2> /dev/null)"
    echo

    echo "---------- Checks ----------"
    CHECK "TARGET_PLATFORM_SDK_VERSION" "$TARGET_PLATFORM_SDK_VERSION" \
        "$(GET_PROP "$TARGET_FW/system/system/build.prop" "ro.build.version.sdk")"
    CHECK "TARGET_PRODUCT_SHIPPING_API_LEVEL" "$TARGET_PRODUCT_SHIPPING_API_LEVEL" \
        "$(GET_PROP "$TARGET_FW/vendor/build.prop" "ro.product.first_api_level")"
    CHECK "TARGET_BOARD_API_LEVEL" "$TARGET_BOARD_API_LEVEL" \
        "$(GET_PROP "$TARGET_FW/vendor/build.prop" "ro.board.api_level")"
    CHECK "TARGET_CODENAME" "$TARGET_CODENAME" \
        "$(GET_PROP "$TARGET_FW/vendor/build.prop" "ro.product.vendor.device")"
    CHECK "TARGET_OS_SINGLE_SYSTEM_IMAGE" "$TARGET_OS_SINGLE_SYSTEM_IMAGE" \
        "$(GET_PROP "$TARGET_FW/system/system/build.prop" "ro.build.product")"
    CHECK "TARGET_SUPER_PARTITION_SIZE" "$TARGET_SUPER_PARTITION_SIZE" \
        "$(GET_PROP "$TARGET_FW/os_partitions_metadata.txt" "super_partition_size")"
    GROUP="$(GET_PROP "$TARGET_FW/os_partitions_metadata.txt" "super_partition_group")"
    CHECK "TARGET_SUPER_GROUP_NAME" "$TARGET_SUPER_GROUP_NAME" "$GROUP"
    CHECK "TARGET_QTI_DYNAMIC_PARTITIONS_SIZE" "$TARGET_QTI_DYNAMIC_PARTITIONS_SIZE" \
        "$(GET_PROP "$TARGET_FW/os_partitions_metadata.txt" "super_${GROUP}_group_size")"
    for p in boot dtbo vendor_boot; do
        VAR="TARGET_$(tr "[:lower:]" "[:upper:]" <<< "$p")_PARTITION_SIZE"
        CHECK "$VAR" "${!VAR}" "$(GET_PROP "$TARGET_FW/${p}.img_metadata.txt" "partition_size")"
    done
    echo

    echo "---------- os_partitions_metadata.txt ----------"
    cat "$TARGET_FW/os_partitions_metadata.txt" 2> /dev/null || true
    echo
    for f in "$TARGET_FW"/*.img_metadata.txt; do
        [ -f "$f" ] || continue
        echo "---------- $(basename "$f") ----------"
        cat "$f"
        echo
    done

    echo "---------- Kernel ----------"
    if command -v unpack_bootimg &> /dev/null && [ -f "$TARGET_FW/kernel/boot.img" ]; then
        TMP="$(mktemp -d)"
        unpack_bootimg --boot_img "$TARGET_FW/kernel/boot.img" --out "$TMP" > /dev/null 2>&1 || true
        grep -a -o -m 1 "Linux version [^(]*([^)]*)" "$TMP/kernel" 2> /dev/null || true
        rm -rf "$TMP"
    fi
    echo

    echo "---------- Props ----------"
    for prop in ro.build.version.release ro.build.version.sdk ro.build.version.oneui ro.build.PDA \
            ro.build.version.security_patch ro.product.system.model; do
        echo "$prop=$(GET_PROP "$TARGET_FW/system/system/build.prop" "$prop")"
    done
    for prop in ro.product.vendor.model ro.product.vendor.device ro.vndk.version ro.board.platform \
            ro.product.first_api_level ro.board.api_level ro.netflix.bsp_rev ro.telephony.sim_slots.count; do
        echo "$prop=$(GET_PROP "$TARGET_FW/vendor/build.prop" "$prop")"
    done
    echo

    echo "---------- Framework features ----------"
    TMP="$(mktemp -d)"
    unzip -q -o "$TARGET_FW/system/system/framework/framework.jar" "classes*.dex" -d "$TMP" &> /dev/null || true
    echo "RIL feature tokens: $(cat "$TMP"/classes*.dex 2> /dev/null | strings -a | \
        grep -o -E "\b(onebinary|satellite_carrier|entitlement_sa|[a-z]+cdmaless)\b" | sort -u | tr "\n" " ")"
    echo "eSE COS candidates: $(cat "$TMP"/classes*.dex 2> /dev/null | strings -a | \
        grep -o -E "\b(JCOP[0-9.]+[A-Z]?|UT[0-9.]+[A-Z]?)\b" | sort -u | tr "\n" " ")"
    rm -rf "$TMP"
    echo "eUICC: $(find "$TARGET_FW/system/system" "$TARGET_FW/vendor/etc/permissions" -maxdepth 3 \
        \( -iname "*euicc*" -o -iname "EuiccGoogle" \) 2> /dev/null | sed "s|$TARGET_FW||" | tr "\n" " ")"
    echo

    echo "---------- /vendor/lib/modules ----------"
    find "$TARGET_FW/vendor/lib/modules" -maxdepth 2 2> /dev/null | sed "s|$TARGET_FW||" | LC_ALL=C sort || true
    echo

    echo "---------- Floating features ----------"
    sed -e "s/^ *//" "$TARGET_FW/system/system/etc/floating_feature.xml" 2> /dev/null || true
    echo
} > "$OUT/p3q_stock_report.txt"
cat "$OUT/p3q_stock_report.txt"

echo "---------- Stock-derived files ----------"
COPY_IF_MISSING "vintf/compatibility_matrix.device.xml" "$TARGET_FW/system/system/etc/vintf/compatibility_matrix.device.xml"
COPY_IF_MISSING "camera/camera-feature.xml" "$TARGET_FW/system/system/cameradata/camera-feature.xml"

TMP="$(mktemp -d)"
if [ -f "$TARGET_FW/$SDHMS" ]; then
    unzip -q -o "$TARGET_FW/$SDHMS" -d "$TMP/sdhms" &> /dev/null || true
fi

# SIOP policy: SDHMS/SSRM ship it encrypted (AES-256-CBC, key: SHA-256 of the policy file name, IV: first 16 bytes)
SSRM="$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME"
DECODE_SIOP()
{
    if grep -a -q "<siop_document" "$1"; then
        cp -a "$1" "$2"
    else
        local KEY IV
        KEY="$(printf "%s" "$SSRM" | sha256sum | cut -d " " -f 1)"
        IV="$(head -c 16 "$1" | od -A n -t x1 -v | tr -d " \n")"
        tail -c +17 "$1" | openssl enc -d -aes-256-cbc -K "$KEY" -iv "$IV" > "$2" 2> /dev/null || return 1
    fi
    grep -a -q "<siop_document" "$2"
}

SIOP_CANDIDATES=()
if [ -d "$TMP/sdhms" ]; then
    while IFS= read -r f; do
        SIOP_CANDIDATES+=("$f")
    done < <(find "$TMP/sdhms" -type f \( -name "siop_model" -o -name "$SSRM" -o -name "$SSRM.xml" \) | LC_ALL=C sort)
fi
if [ -f "$TARGET_FW/system/system/framework/ssrm.jar" ]; then
    unzip -q -o "$TARGET_FW/system/system/framework/ssrm.jar" -d "$TMP/ssrm" &> /dev/null || true
    while IFS= read -r f; do
        SIOP_CANDIDATES+=("$f")
    done < <(find "$TMP/ssrm" -type f \( -name "siop_model" -o -name "$SSRM" -o -name "$SSRM.xml" \) 2> /dev/null | LC_ALL=C sort)
fi
while IFS= read -r f; do
    SIOP_CANDIDATES+=("$f")
done < <(find "$TARGET_FW/system" "$TARGET_FW/vendor" "$TARGET_FW/product" -type f \
    \( -name "siop_model" -o -name "$SSRM" -o -name "$SSRM.xml" \) 2> /dev/null | LC_ALL=C sort)

SIOP_FOUND=false
for f in "${SIOP_CANDIDATES[@]}"; do
    if DECODE_SIOP "$f" "$TMP/siop_model.xml"; then
        echo "- Found SIOP policy ($SSRM): ${f//$TMP\//}"
        COPY_IF_MISSING "dvfs/siop_model.xml" "$TMP/siop_model.xml"
        SIOP_FOUND=true
        break
    else
        echo "! Unable to decode SIOP policy candidate: ${f//$TMP\//}"
    fi
done
if ! $SIOP_FOUND; then
    echo "! SIOP policy $SSRM not found in stock firmware, falling back to the generic one"
    echo "  SDHMS entries: $(find "$TMP/sdhms" -type f \( -path "*/assets/*" -o -iname "*siop*" -o -iname "*ssrm*" \) 2> /dev/null | sed "s|$TMP/sdhms/||" | tr "\n" " ")"
    echo "  ssrm.jar entries: $(find "$TMP/ssrm" -type f 2> /dev/null | sed "s|$TMP/ssrm/||" | tr "\n" " ")"
    COPY_IF_MISSING "dvfs/siop_model.xml" "$SRC_DIR/unica/patches/dvfs/assets/siop_default.xml"
fi

if ! unzip -l "$SOURCE_FW/$SDHMS" 2> /dev/null | grep -q "res/raw/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml"; then
    COPY_IF_MISSING "dvfs/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml" "$TMP/sdhms/res/raw/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml"
fi
rm -rf "$TMP"

# SELinux pre-check on the unpatched source system/system_ext/product and stock vendor/odm files,
# unica/patches/selinux fixes some of the known issues, the final check runs on the built work dir
echo
echo "SELinux pre-check (unpatched files):"
SEPOL_WORK="$(mktemp -d)"
mkdir -p "$SEPOL_WORK/system"
ln -s "$SOURCE_FW/system/system" "$SEPOL_WORK/system/system"
for p in "system_ext" "product"; do
    [ -d "$SOURCE_FW/$p" ] && ln -s "$SOURCE_FW/$p" "$SEPOL_WORK/$p"
done
for p in "vendor" "odm"; do
    [ -d "$TARGET_FW/$p" ] && ln -s "$TARGET_FW/$p" "$SEPOL_WORK/$p"
done
python3 "$SRC_DIR/.github/scripts/check_selinux.py" "$SEPOL_WORK" | tee "$OUT/selinux_precheck.txt" || true
rm -rf "$SEPOL_WORK"

if [ "$ERRORS" != "0" ]; then
    echo "$ERRORS config check(s) failed, please update target/p3q/config.sh or platform/sm8350/config.sh" >&2
    exit 1
fi

exit 0
