param([string]$BuildDirectory = (Join-Path $PSScriptRoot '..\build\web'))
$ErrorActionPreference = 'Stop'
$build = (Resolve-Path -LiteralPath $BuildDirectory).Path
$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\web\farmerplus-sw.template.js') -Raw
$buildPrefix = $build.TrimEnd('\') + '\'
$sourceFiles = @(Get-ChildItem -LiteralPath $build -Recurse -File |
  Where-Object { $_.Name -notin @('farmerplus-sw.js', 'flutter_service_worker.js') } |
  Sort-Object FullName)
$files = @($sourceFiles | ForEach-Object {
  '/' + $_.FullName.Substring($buildPrefix.Length).Replace('\', '/')
})
$json = ConvertTo-Json -InputObject @($files) -Compress
$hashInput = ($sourceFiles | ForEach-Object {
  $fileStream = [IO.File]::OpenRead($_.FullName)
  $fileHasher = [Security.Cryptography.SHA256]::Create()
  try { $fileHash = [BitConverter]::ToString($fileHasher.ComputeHash($fileStream)).Replace('-', '') }
  finally { $fileStream.Dispose(); $fileHasher.Dispose() }
  $_.FullName.Substring($buildPrefix.Length) + ':' + $fileHash
}) -join "`n"
$algorithm = [Security.Cryptography.SHA256]::Create()
try { $sha = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($hashInput)) }
finally { $algorithm.Dispose() }
$hash = (($sha | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
$worker = $template.Replace('__PRECACHE__', $json).Replace('__BUILD_HASH__', $hash)
[IO.File]::WriteAllText((Join-Path $build 'farmerplus-sw.js'), $worker, [Text.UTF8Encoding]::new($false))
Write-Output "Installed FarmerPlus service worker $hash with $($files.Count) local resources."
