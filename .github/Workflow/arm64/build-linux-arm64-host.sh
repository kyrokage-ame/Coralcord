#!/usr/bin/env bash
set -euo pipefail
case "$(uname -m)" in aarch64|arm64) ;; *) echo "This script is for a Linux ARM64 build host." >&2; exit 2 ;; esac
exec "$(dirname "${BASH_SOURCE[0]}")/build-linux.sh" "$@"
