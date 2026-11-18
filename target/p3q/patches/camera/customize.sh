TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"

# Add target camera libs (if shipped in the target firmware)
for i in \
    "libsame_source_hdr.arcsoft.so:arcsoft" \
    "libsuperresolution_raw.arcsoft.so:arcsoft" \
    "libsuperresolutionraw_wrapper_v2.camera.samsung.so:" \
    "libuwsuperresolution.arcsoft.so:arcsoft" \
    "libuwsuperresolution_wrapper_v1.camera.samsung.so:camera.samsung"; do
    LIB="${i%%:*}"
    PUBLIC_LIBRARIES="${i#*:}"

    if [ ! -f "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/lib64/$LIB" ]; then
        continue
    fi

    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/$LIB" 0 0 644 "u:object_r:system_lib_file:s0"
    if [ "$PUBLIC_LIBRARIES" ] && \
            ! grep -q -x "$LIB" "$WORK_DIR/system/system/etc/public.libraries-$PUBLIC_LIBRARIES.txt" 2> /dev/null; then
        EVAL "echo \"$LIB\" >> \"$WORK_DIR/system/system/etc/public.libraries-$PUBLIC_LIBRARIES.txt\""
    fi
done

unset TARGET_FIRMWARE_PATH LIB PUBLIC_LIBRARIES
