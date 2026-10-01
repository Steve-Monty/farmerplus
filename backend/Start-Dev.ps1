param([int]$Port=8088,[switch]$NoReload)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$python=Join-Path $root '.venv\Scripts\python.exe'
if(-not (Test-Path -LiteralPath $python)){throw 'Run .\.venv\Scripts\python.exe -m pip install -r requirements.txt first.'}

# Load private local settings into this child process without echoing values.
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

# Match the combined PWA launcher and keep development data isolated and durable.
$data=Join-Path $root '.local-development'
New-Item -ItemType Directory -Path $data -Force | Out-Null
$database=(Join-Path $data 'farmer.sqlite').Replace('\','/')
$env:FARMER_DATA_DIR=$data
$env:DATABASE_URL="sqlite:///$database"
$env:FARMER_SECURE_COOKIES='0'
if([string]::IsNullOrWhiteSpace($env:FARMER_PUBLIC_URL)){$env:FARMER_PUBLIC_URL="http://127.0.0.1:$Port"}
if([string]::IsNullOrWhiteSpace($env:FARMER_PWA_PUBLIC_URL)){$env:FARMER_PWA_PUBLIC_URL='http://127.0.0.1:5173'}

$arguments=@('-m','uvicorn','app:app','--host','127.0.0.1','--port',"$Port")
if(-not $NoReload){$arguments+='--reload'}
Push-Location -LiteralPath $root
try{
    Write-Host "FarmerPlus backend: http://127.0.0.1:$Port"
    Write-Host "Local development data: $data"
    & $python @arguments
}finally{Pop-Location}
