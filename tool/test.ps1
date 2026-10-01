$ErrorActionPreference = 'Stop'
$flutter = 'C:\e-learning\farmerplus-mobile\tooling\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter)) {
  $flutter = (Get-Command flutter -ErrorAction Stop).Source
}
Push-Location -LiteralPath (Join-Path $PSScriptRoot '..')
try {
  & $flutter test
  if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed' }
} finally { Pop-Location }
