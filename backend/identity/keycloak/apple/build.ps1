param([Parameter(Mandatory=$true)][string]$KeycloakHome,
      [Parameter(Mandatory=$true)][string]$JavaHome)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$build = Join-Path $root 'build'
New-Item -ItemType Directory -Force $build | Out-Null
$jars = Join-Path $KeycloakHome 'lib/lib/main/*'
$sources = (Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -Filter '*.java').FullName
& (Join-Path $JavaHome 'bin/javac.exe') --release 21 -cp $jars -d $build @sources
if ($LASTEXITCODE) { throw 'Apple adapter compilation failed' }
Copy-Item -LiteralPath (Join-Path $root 'resources/META-INF') -Destination $build -Recurse -Force
& (Join-Path $JavaHome 'bin/jar.exe') --create --file (Join-Path $KeycloakHome 'providers/farmerplus-apple.jar') -C $build .
if ($LASTEXITCODE) { throw 'Apple adapter packaging failed' }
Write-Output 'Apple adapter built for the selected Keycloak distribution.'
