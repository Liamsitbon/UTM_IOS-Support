#!/bin/sh
set -eu
# Optional staging is deliberately per existing UTM sysroot, including -TCI.
STAGE="${LTM_RUNTIME_DIR:-${SRCROOT}/${SYSROOT_DIR}/LightTouch}"
if [ ! -d "$STAGE/LightTouchQEMU.framework" ]; then
    if [ "${LTM_REQUIRED:-0}" = 1 ]; then
        echo "error: Missing LightTouch engine at $STAGE" >&2
        exit 1
    fi
    echo "warning: LightTouch engine is absent for this build; guest launch will report it."
    exit 0
fi
if echo " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " | /usr/bin/grep -q ' WITH_QEMU_TCI '; then
    /usr/bin/plutil -extract interpreter raw -o - "$STAGE/runtime.json" | /usr/bin/grep -qx true || {
        echo "error: UTM SE requires an interpreter-only LightTouch engine." >&2
        exit 1
    }
fi
# Every non-system dependency must have been staged as a sibling framework.
# No developer-machine paths or undeclared rpaths may escape into the app.
for FRAMEWORK in "$STAGE"/*.framework; do
    NAME=$(basename "$FRAMEWORK" .framework)
    BINARY="$FRAMEWORK/$NAME"
    /usr/bin/lipo -verify_arch $ARCHS "$BINARY"
    case "$PLATFORM_NAME" in
        macosx) EXPECTED=MACOS ;;
        iphoneos) EXPECTED=IOS ;;
        iphonesimulator) EXPECTED=IOSSIMULATOR ;;
        xros) EXPECTED=XROS ;;
        xrsimulator) EXPECTED=XROSSIMULATOR ;;
        *) echo "error: Unknown LightTouch host platform $PLATFORM_NAME" >&2; exit 1 ;;
    esac
    ACTUAL=$(/usr/bin/vtool -show-build "$BINARY" | /usr/bin/awk '$1 == "platform" { print $2 }' | /usr/bin/sort -u)
    [ "$ACTUAL" = "$EXPECTED" ] || {
        echo "error: LightTouch framework platform $ACTUAL does not match $EXPECTED" >&2
        exit 1
    }
    /usr/bin/otool -L "$BINARY" | /usr/bin/tail -n +2 | while read -r LINE; do
        LOAD=${LINE%% (*}
        case "$LOAD" in
            /System/Library/*|/usr/lib/*) ;;
            @rpath/*.framework/*)
                REL=${LOAD#@rpath/}
                [ -f "$STAGE/$REL" ] || { echo "error: Missing LightTouch dependency $REL" >&2; exit 1; }
                ;;
            *) echo "error: Unstaged LightTouch dependency $LOAD" >&2; exit 1 ;;
        esac
    done
    /bin/mkdir -p "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
    /usr/bin/ditto "$FRAMEWORK" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/$NAME.framework"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none \
            "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/$NAME.framework"
    fi
done
