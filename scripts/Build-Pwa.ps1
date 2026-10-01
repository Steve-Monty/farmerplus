$ErrorActionPreference = 'Stop'
$farmerWorkspace = Split-Path -Parent $PSScriptRoot
$farmerFlutter = 'C:\e-learning\farmerplus-mobile\tooling\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $farmerFlutter)) {
    $farmerFlutter = (Get-Command flutter -ErrorAction Stop).Source
}
Push-Location $farmerWorkspace
try {
    & $farmerFlutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'PWA dependency resolution failed.' }
    & $farmerFlutter build web --target lib/pwa_main.dart --release --no-wasm-dry-run --pwa-strategy=none --no-web-resources-cdn
    if ($LASTEXITCODE -ne 0) { throw 'PWA web build failed.' }
    & (Join-Path $farmerWorkspace 'tool\install_sw.ps1')
} finally { Pop-Location }
