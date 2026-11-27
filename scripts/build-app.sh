#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${1:-"$project_dir/.build/luma-dev"}
app_dir="$output_dir/Luma.app"
fail() { printf 'Luma build: %s\n' "$*" >&2; exit 1; }

mkdir -p "$output_dir/cache" || fail "Cannot create $output_dir."
stage=$(mktemp -d "$output_dir/.luma-build.XXXXXX") || fail "Cannot stage the app."
lock="$output_dir/.luma-build-lock"
if ! mkdir "$lock"; then
    rmdir "$stage"
    fail "Another build owns $lock."
fi

cleanup() {
    if [ -d "$stage/Previous.app" ] && [ ! -e "$app_dir" ]; then
        if ! mv "$stage/Previous.app" "$app_dir"; then
            printf 'Luma build: Recover the previous build at %s.\n' "$stage/Previous.app" >&2
            rmdir "$lock"
            return
        fi
    fi
    rm -rf "$stage"
    rmdir "$lock"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

candidate="$stage/Luma.app"
mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources"
cp "$project_dir/Resources/Info.plist" "$candidate/Contents/Info.plist"
plutil -lint "$candidate/Contents/Info.plist" >/dev/null || fail "Invalid Info.plist."

swiftc -target x86_64-apple-macosx12.0 -O -module-cache-path "$output_dir/cache" \
    "$project_dir"/Sources/Luma/*.swift -o "$candidate/Contents/MacOS/Luma" ||
    fail "Swift compilation failed."
swiftc -target x86_64-apple-macosx12.0 -O -module-cache-path "$output_dir/cache" \
    "$project_dir/scripts/AppIcon.swift" -o "$stage/icon-generator" ||
    fail "Icon generator compilation failed."
"$stage/icon-generator" "$candidate/Contents/Resources/AppIcon.icns" || fail "Icon packaging failed."

codesign --sign - "$candidate" || fail "Ad-hoc signing failed."
codesign --verify --strict "$candidate" || fail "Signature validation failed."
if [ -e "$app_dir" ] || [ -L "$app_dir" ]; then
    [ -d "$app_dir" ] && [ ! -L "$app_dir" ] &&
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Contents/Info.plist" 2>/dev/null |
        /usr/bin/grep -qx 'com.fathirbrb.luma' || fail "The existing output is not a Luma bundle."
    mv "$app_dir" "$stage/Previous.app" || fail "Cannot stage the previous build."
fi
mv "$candidate" "$app_dir" || fail "Cannot publish the new bundle."
printf 'Built %s\n' "$app_dir"
