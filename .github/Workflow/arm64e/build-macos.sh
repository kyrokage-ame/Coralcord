#!/usr/bin/env bash
set -euo pipefail
ARCH="arm64e"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
if [[ "$(uname -s)" != "Darwin" ]]; then echo "Run this script on macOS." >&2; exit 2; fi
if ! xcode-select -p >/dev/null 2>&1; then echo "Install Xcode and select its command-line tools first." >&2; exit 2; fi
if [[ ! -f "$THEOS/makefiles/common.mk" ]]; then echo "Theos not found at $THEOS." >&2; exit 2; fi
export THEOS
for p in "$THEOS/toolchain/darwin/host/bin" "$THEOS/toolchain/darwin/iphone/bin"; do [[ -d "$p" ]] && export PATH="$p:$PATH"; done
cd "$ROOT"
make clean
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if make package -j2 ARCHS="$ARCH" TARGET=iphone:clang:15.6:15.0 2>&1 | tee "$log"; then
  :
else
  status=$?
  exit "$status"
fi
if grep -Eqi 'incompatible arm64e ABI' "$log"; then
  echo "Build produced an incompatible arm64e ABI warning; refusing to report this IPA as validated." >&2
  exit 3
fi
