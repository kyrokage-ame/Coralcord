# armv7 build targets

This directory contains local build scripts for Linux, Linux ARM64 hosts, macOS, and Windows through WSL, plus a workflow template. The executable GitHub Actions entry point is `.github/workflows/build-armv7.yml` (GitHub only discovers workflows from that lowercase directory).

Run `build-linux.sh` in Linux/WSL, `build-linux-arm64-host.sh` on a Linux ARM64 host, or `build-macos.sh` on macOS. On Windows, install WSL Ubuntu 24.04 and Theos in that distribution, then run `build-windows.ps1` from PowerShell. All scripts use the repository's existing source and request an iOS 15.0 deployment target with the selected architecture.

The armv7 workflow intentionally attempts the requested target but the app's SwiftUI/iOS 15 source and current SDK may not support it; the job reports the real compiler result. arm64e is also attempted separately. Neither architecture is claimed as validated until its workflow completes successfully.
