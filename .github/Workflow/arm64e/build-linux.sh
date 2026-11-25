#!/usr/bin/env bash
set -euo pipefail
ARCH="arm64e"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
if [[ ! -f "$THEOS/makefiles/common.mk" ]]; then
  echo "Theos not found at $THEOS. Install Theos and the iPhoneOS 15.6 SDK first." >&2
  exit 2
fi
export THEOS
export PATH="$THEOS/toolchain/linux/host/bin:$THEOS/toolchain/linux/iphone/bin:$PATH"
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
