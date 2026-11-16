<#
  Packages the Windows build (run on Windows, e.g. the windows-latest CI runner):
    dist/girocrab-windows-x86_64.zip           portable: girocrab.exe + THIRD_PARTY_NOTICES.md + README-Windows.txt
    dist/girocrab-windows-x86_64-setup.exe     Inno Setup installer (Start Menu shortcut, uninstaller, version info)
    dist/SHA256SUMS.txt

  Usage: pwsh scripts/package-windows.ps1 [-Version 0.7.5] [-OutDir dist]
  Expects `cargo build --release --manifest-path GiroCrabWindows/Cargo.toml` to have run.
  The binaries are NOT code-signed (see docs/windows.md, "SmartScreen").
#>
param(
    [string]$Version = "",
    [string]$OutDir = "dist"
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $root

if (-not $Version) {
    $m = Select-String -Path "GiroCrabWindows/Cargo.toml" -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1
    $Version = $m.Matches[0].Groups[1].Value
}
$Version = $Version.TrimStart("v")
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    # tags such as 0.7.5-nightly.3: Inno Setup wants a numeric version, the zip name stays fixed
    $Version = ($Version -replace '^(\d+\.\d+\.\d+).*$', '$1')
}

$exe = "GiroCrabWindows/target/release/girocrab.exe"
if (-not (Test-Path $exe)) { throw "$exe not found: run cargo build --release first" }

$out = Join-Path $root $OutDir
$stage = Join-Path $out "stage"
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null

Copy-Item $exe (Join-Path $stage "girocrab.exe")
Copy-Item "THIRD_PARTY_NOTICES.md" $stage
Copy-Item "GiroCrabWindows/packaging/README-Windows.txt" $stage

# portable zip: exactly the three files, flat
$zip = Join-Path $out "girocrab-windows-x86_64.zip"
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip
Write-Host "wrote $zip"

# installer
Copy-Item "LICENSE" $stage
$iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    foreach ($p in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe")) {
        if (Test-Path $p) { $iscc = $p; break }
    }
}
if (-not $iscc) {
    Write-Host "Inno Setup not found, installing via Chocolatey"
    choco install innosetup -y --no-progress | Out-Host
    $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
}
if (-not (Test-Path $iscc)) { throw "ISCC.exe not found" }
& $iscc "/DAppVersion=$Version" "/DSourceDir=$stage" "/DOutputDir=$out" "/Qp" "GiroCrabWindows/packaging/girocrab.iss"
if ($LASTEXITCODE -ne 0) { throw "iscc failed ($LASTEXITCODE)" }

Remove-Item $stage -Recurse -Force
Get-ChildItem $out -File | Where-Object { $_.Name -ne "SHA256SUMS.txt" } | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
} | Set-Content (Join-Path $out "SHA256SUMS.txt")
Get-Content (Join-Path $out "SHA256SUMS.txt")
