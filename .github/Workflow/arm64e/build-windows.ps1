param([string]$Distribution = "Ubuntu-24.04")
$ErrorActionPreference = "Stop"
$Repo = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
$Drive = $Repo.Substring(0, 1).ToLowerInvariant()
$WslRepo = "/mnt/$Drive" + $Repo.Substring(2).Replace('\', '/')
$BuildScript = "$WslRepo/.github/Workflow/arm64e/build-linux.sh"
& wsl.exe -d $Distribution -- bash -lc "test -f '$BuildScript' && bash '$BuildScript'"
if ($LASTEXITCODE -ne 0) {
  Write-Error "WSL build failed. Install Ubuntu-24.04 with 'wsl --install -d Ubuntu-24.04', then install Theos and the iPhoneOS 15.6 SDK inside WSL."
  exit $LASTEXITCODE
}
