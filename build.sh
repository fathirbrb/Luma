#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec /bin/sh "$project_dir/scripts/build-app.sh" "$@"
