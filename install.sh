#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
source_app="$project_dir/.build/luma-dev/Luma.app"
install_dir=${1:-"$HOME/Applications"}
destination="$install_dir/Luma.app"
bundle_id=com.fathirbrb.luma

fail() { printf 'Luma install: %s\n' "$*" >&2; exit 1; }
is_luma() {
    [ -d "$1" ] && [ ! -L "$1" ] &&
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" = "$bundle_id" ]
}

is_luma "$source_app" || fail "Build Luma first with ./build.sh."
codesign --verify --strict "$source_app" || fail "The build has an invalid signature."
mkdir -p "$install_dir" || fail "Cannot create $install_dir."
lock="$install_dir/.luma-install-lock"
mkdir "$lock" || fail "Another installation owns $lock."

stage=''
cleanup() {
    if [ -n "$stage" ]; then
        if [ -d "$stage/Previous.app" ] && [ ! -e "$destination" ]; then
            if ! mv "$stage/Previous.app" "$destination"; then
                printf 'Luma install: Recover the previous installation at %s.\n' "$stage/Previous.app" >&2
                rmdir "$lock"
                return
            fi
        fi
        rm -rf "$stage"
    fi
    rmdir "$lock"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

stage=$(mktemp -d "$install_dir/.luma-install.XXXXXX") || fail "Cannot stage the installation."
candidate="$stage/Luma.app"
ditto "$source_app" "$candidate" || fail "Copy failed."
codesign --verify --strict "$candidate" || fail "The staged copy failed signature validation."

if [ -e "$destination" ] || [ -L "$destination" ]; then
    is_luma "$destination" || fail "Refusing to replace an unrelated item at $destination."
    mv "$destination" "$stage/Previous.app" || fail "Cannot stage the previous installation."
fi
mv "$candidate" "$destination" || fail "Cannot move the staged copy into place."
printf 'Installed %s\n' "$destination"
printf '%s\n' 'Open Luma in Finder. If an earlier version is running, quit and reopen it.'
