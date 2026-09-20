#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then printf 'Run with Bash.\n' >&2; exit 3; fi
set -u
set -o pipefail
entry=${BASH_SOURCE[0]}; [[ $entry == */* ]] || entry=./$entry
SOURCE_DIR=$(cd -- "${entry%/*}" && pwd -P) || exit 3
# shellcheck source=maintenance.sh
source "$SOURCE_DIR/maintenance.sh"
maintenance_main uninstall "$@"
