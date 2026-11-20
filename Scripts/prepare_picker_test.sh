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

# A known photo for the viewer test.
photo="$RUNNER_TEMP/nx-photo.png"
python3 - "$photo" <<'PNG'
import struct, sys, zlib
width, height = 96, 64
rows = b"".join(b"\x00" + bytes([30, 160, 170]) * width for _ in range(height))
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PNG
xcrun simctl addmedia "$device" "$photo"
