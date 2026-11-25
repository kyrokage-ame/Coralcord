# arm64e build targets

This directory contains local build scripts for Linux, Linux ARM64 hosts, macOS, and Windows through WSL, plus a workflow template. The executable GitHub Actions entry point is `.github/workflows/build-arm64e.yml` (GitHub only discovers workflows from that lowercase directory).

Run `build-linux.sh` in Linux/WSL, `build-linux-arm64-host.sh` on a Linux ARM64 host, or `build-macos.sh` on macOS. On Windows, install WSL Ubuntu 24.04 and Theos in that distribution, then run `build-windows.ps1` from PowerShell. All scripts use the repository's existing source and request an iOS 15.0 deployment target with the selected architecture.

In the current Linux x86_64 test environment, the arm64e compiler/linker emitted an `incompatible arm64e ABI compiler` warning. The Linux and macOS arm64e scripts now detect that warning and exit with failure so an untrusted output is not reported as a successful IPA. This is not validated for installation or device use. The armv7 attempt was rejected by the current compiler because it cannot emit armv7 binaries/IR for iOS 11 and later; iOS 15 is the deployment target here.
