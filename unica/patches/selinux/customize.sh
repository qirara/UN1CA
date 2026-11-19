# UN1CA SELinux entries removal list
# - Append new type entries to the ENTRIES list
# - Add the EXACT type entry, DO NOT just add a common pattern (eg. "fabriccrypto", "fabriccrypto_exec" and NOT just "fabriccrypto")
# - DO NOT add the API version at the end of the entry (eg. "fabriccrypto" and NOT "fabriccrypto_30_0")
# - DO NOT add any parenthesis or statements (eg. "fabriccrypto" and NOT "expanttypeattribute ... (fabriccrypto)")
# - DO NOT add unnecessary types or remove the existing ones unless they aren't necessary anymore for all devices

# One UI 8.0 additions
ENTRIES+="
heatmap_default
heatmap_default_exec
"

DUPLICATES+="
init.svc.vendor.wvkprov_server_hal
"

# One UI 7.0 additions
ENTRIES+="
attiqi_app
attiqi_app_data_file
ker_app
kpp_app
kpp_data_file
"

# One UI 6.1.1 additions
ENTRIES+="
hal_dsms_default
hal_dsms_default_exec
proc_compaction_proactiveness
sbauth
sbauth_exec
"

# One UI 5.1.1 additions
ENTRIES+="
audiomirroring
audiomirroring_exec
audiomirroring_service
fabriccrypto
fabriccrypto_exec
fabriccrypto_data_file
hal_dsms_service
uwb_regulation_skip_prop
"

# [
GET_SYSTEM_EXT()
{
    if $TARGET_OS_BUILD_SYSTEM_EXT_PARTITION; then
        echo "system_ext"
    else
        echo "system/system/system_ext"
    fi
}

CIL_NAME="$(head -n 1 "$WORK_DIR/vendor/etc/selinux/plat_sepolicy_vers.txt")"
PATCHED=false
VENDOR_API_LIST="$(find "$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux/mapping" -type f -printf "%f\n" | \
                    sed '/.compat./d' | sed 's/.cil//' | sed 's/\./_/' | sort)"
# ]

for e in $ENTRIES; do
    if grep -q -F "($e)" "$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux/mapping/$CIL_NAME.cil" || \
         grep -q -F "${e}_${CIL_NAME//./_}" "$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux/mapping/$CIL_NAME.cil"; then
        # the problematic entry is currently present in system_ext, check if we need to remove it
        if ! grep -q -F "(type $e)" "$WORK_DIR/vendor/etc/selinux/plat_pub_versioned.cil"; then
            PATCHED=true
            # the problematic entry is not supported by the target device
            LOG "- \"$e\" SELinux entry not supported. Removing"
            sed -i "/($e)/d" "$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux/mapping/$CIL_NAME.cil"
            for a in $VENDOR_API_LIST; do
                sed -i "/${e}_${a}/d" "$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux/mapping/$CIL_NAME.cil"
            done
            if grep -q "genfscon.*$e" "$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux/system_ext_sepolicy.cil"; then
                sed -i "/genfscon.*$e/d" "$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux/system_ext_sepolicy.cil"
            fi
            if grep -q "genfscon.*$e" "$WORK_DIR/system/system/etc/selinux/plat_sepolicy.cil"; then
                sed -i "/genfscon.*$e/d" "$WORK_DIR/system/system/etc/selinux/plat_sepolicy.cil"
            fi
        fi
    fi
done

for e in $DUPLICATES; do
    if grep -q "^$e.*" "$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux/system_ext_property_contexts"; then
        # the problematic entry is currently present in system_ext, check if we need to remove it
        if grep -q "^$e.*" "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts"; then
            PATCHED=true
            # the problematic entry is found in target vendor
            LOG "- \"$e\" SELinux duplicate entry found. Removing"
            sed -i "s/^$e/#SEC_DUPLICATE: $e/g" "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts"
        fi
    fi
done

# init aborts on boot if the same property_contexts entry (same name and match type) is defined twice,
# even with the same context (property_info_serializer), keep the source system one for any other
# entry also defined by the target vendor/odm
SYSTEM_PROPERTY_CONTEXTS=()
for f in "$WORK_DIR/system/system/etc/selinux/plat_property_contexts" \
         "$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux/system_ext_property_contexts" \
         "$WORK_DIR/product/etc/selinux/product_property_contexts"; do
    [ -f "$f" ] && SYSTEM_PROPERTY_CONTEXTS+=("$f")
done
for f in "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts" \
         "$WORK_DIR/odm/etc/selinux/odm_property_contexts"; do
    [ -f "$f" ] && [ "${#SYSTEM_PROPERTY_CONTEXTS[@]}" != "0" ] || continue
    # shellcheck disable=SC2016
    awk -v target="$f" '
        function key() { return $1 " " ($3 == "exact" ? "exact" : "prefix") }
        FILENAME != target { if ($1 !~ /^#/ && NF >= 2) seen[key()] = 1; next }
        $1 !~ /^#/ && NF >= 2 && (key() in seen) { print "#SEC_DUPLICATE: " $0; print $1 > "/dev/stderr"; next }
        { print }
    ' "${SYSTEM_PROPERTY_CONTEXTS[@]}" "$f" > "$f.tmp" 2> "$f.dup" || ABORT "Failed to check $f for duplicate entries"
    while IFS= read -r e; do
        PATCHED=true
        LOG "- \"$e\" SELinux duplicate entry found in ${f//$WORK_DIR/}. Removing"
    done < "$f.dup"
    mv -f "$f.tmp" "$f"
    rm -f "$f.dup"
done

if ! $PATCHED; then
    LOG "\033[0;33m! Nothing to do\033[0m"
fi

unset ENTRIES DUPLICATES CIL_NAME PATCHED VENDOR_API_LIST SYSTEM_PROPERTY_CONTEXTS
unset -f GET_SYSTEM_EXT
