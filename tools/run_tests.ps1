<#
.SYNOPSIS
Runs every test layer that does not need a phone, on Windows.

.DESCRIPTION
The protocol and state-machine tests are pure JVM, so this is the whole local suite. The device
tests (tools/cross_device_test.py) need two phones and are run from the Mac that has them attached;
see docs/testing.md.

.EXAMPLE
pwsh -NoProfile -File tools/run_tests.ps1
pwsh -NoProfile -File tools/run_tests.ps1 -WithBuild -WithLint
#>
param(
    # Also build the debug APK (compiles every module, including the Compose UI).
    [switch]$WithBuild,
    # Also run Android lint. Slower, and only worth it before a commit or a release.
    [switch]$WithLint
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$build = Join-Path $repo "android/build.ps1"

$tasks = @(":core-protocol:test")
if ($WithBuild) { $tasks += ":app:assembleDebug" }
if ($WithLint) { $tasks += ":app:lintDebug" }

Write-Host "==> gradle $($tasks -join ' ')" -ForegroundColor Cyan
# build.ps1 exists because the JDK's unix-socket path handling breaks on deep Windows temp paths.
& pwsh -NoProfile -File $build @tasks
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Local suites passed. Still to run elsewhere:" -ForegroundColor Green
Write-Host "  macOS, Swift tests      : ./tools/run_tests.sh"
Write-Host "  two phones, device tests: python3 tools/cross_device_test.py [--reset]"
Write-Host "  see docs/testing.md for what each layer proves."
