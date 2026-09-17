#requires -version 5
<#
  AirChat Gradle launcher.

  Why this wrapper exists
  -----------------------
  Some Windows hosts expand the process TEMP/TMP to an 8.3 short path
  (e.g. C:\Users\<Account>~1\...). Windows AF_UNIX `connect()` rejects such a path with
  EINVAL, which breaks the JDK's PipeImpl / SelectorProvider.openPipe() and makes
  every JVM-based tool die with "Unable to establish loopback connection".

  Gradle needs pipes for its daemon, so we point TEMP/TMP at a plain long path
  inside the checkout before launching. Nothing else about the environment changes.

  Usage:  pwsh -File android\build.ps1 :core-protocol:test
          pwsh -File android\build.ps1 :app:assembleDebug
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $GradleArgs
)

$ErrorActionPreference = "Stop"
$androidDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $androidDir
$tmpDir = Join-Path $repoRoot ".tmp"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

# Long-form path only: 8.3 short names break Windows AF_UNIX sockets.
$env:TEMP = $tmpDir
$env:TMP = $tmpDir

if (-not $GradleArgs -or $GradleArgs.Count -eq 0) {
    $GradleArgs = @("projects")
}

# Gradle treats the *current* directory as the project directory, so the helper must run from
# android/ regardless of where the caller happened to be.
Push-Location $androidDir
try {
    & (Join-Path $androidDir "gradlew.bat") @GradleArgs
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
