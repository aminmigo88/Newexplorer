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
