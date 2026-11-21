#!/bin/bash
# Give the simulator a second app with a Files-visible Documents folder.
set -eu
source_app="$1"
device="$2"
fixture="$RUNNER_TEMP/PickerFixture.app"
bundle="com.example.newexplorer-picker-fixture"
cp -R "$source_app" "$fixture"
plist="$fixture/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Folder Test Source" "$plist"
codesign --force --sign - "$fixture"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$fixture"
container=$(xcrun simctl get_app_container "$device" "$bundle" data)
mkdir -p "$container/Documents/Downloads"
echo "picker round trip" > "$container/Documents/Downloads/inside.txt"
echo "top-level file" > "$container/Documents/root-file.txt"

# Two known photos for the viewer test.
photos_dir="$RUNNER_TEMP/nx-photos"
mkdir -p "$photos_dir"
python3 - "$photos_dir" <<'PNG'
import os, struct, sys, zlib
def png(path, width, height, colour):
    rows = b"".join(b"\x00" + bytes(colour) * width for _ in range(height))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)
png(os.path.join(sys.argv[1], "nx-photo.png"), 96, 64, [30, 160, 170])
png(os.path.join(sys.argv[1], "nx-photo-2.png"), 64, 48, [230, 120, 40])
PNG
xcrun simctl addmedia "$device" "$photos_dir/nx-photo.png" "$photos_dir/nx-photo-2.png"
