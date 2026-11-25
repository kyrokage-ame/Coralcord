#!/usr/bin/env bash
set -euo pipefail
ARCH="arm64"
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
make package -j2 ARCHS="$ARCH" TARGET=iphone:clang:15.6:15.0
