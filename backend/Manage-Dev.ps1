param(
    [Parameter(Mandatory=$true,Position=0)]
    [ValidateSet('grant-admin','revoke-admin','grant-email-admin','revoke-email-admin')]
    [string]$Action,
    [Parameter(Mandatory=$true,Position=1)]
    [string]$Identifier
)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$python=Join-Path $root '.venv\Scripts\python.exe'
if(-not (Test-Path -LiteralPath $python)){throw 'Run .\.venv\Scripts\python.exe -m pip install -r requirements.txt first.'}

# Load the same private configuration as Start-Dev without printing values.
$environment=Join-Path $root '.env'
if(Test-Path -LiteralPath $environment){
    foreach($line in Get-Content -LiteralPath $environment){
        $match=[regex]::Match($line,'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$')
        if(-not $match.Success){continue}
        $name=$match.Groups[1].Value
        $value=$match.Groups[2].Value
        if($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))){
            $value=$value.Substring(1,$value.Length-2)
        }
        Set-Item -LiteralPath "Env:$name" -Value $value
    }
}

# Force the isolated development database even if the calling shell or .env
# names another database. Production administration must use an explicit,
# separately reviewed process.
$data=Join-Path $root '.local-development'
New-Item -ItemType Directory -Path $data -Force | Out-Null
$database=(Join-Path $data 'farmer.sqlite').Replace('\','/')
$env:FARMER_DATA_DIR=$data
$env:DATABASE_URL="sqlite:///$database"

& $python (Join-Path $root 'manage.py') $Action $Identifier
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
