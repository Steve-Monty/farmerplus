param([int]$Port=8088,[switch]$NoReload)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$python=Join-Path $root '.venv\Scripts\python.exe'
if(-not (Test-Path -LiteralPath $python)){throw 'Run .\.venv\Scripts\python.exe -m pip install -r requirements.txt first.'}
$environment=Join-Path $root '.env'
if(Test-Path -LiteralPath $environment){
    foreach($line in Get-Content -LiteralPath $environment){
        $trimmed=$line.Trim()
        if(-not $trimmed -or $trimmed.StartsWith('#')){continue}
        $separator=$trimmed.IndexOf('=')
        if($separator -lt 1){throw "Invalid .env line; expected NAME=value"}
        $name=$trimmed.Substring(0,$separator).Trim()
        if($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$'){throw "Invalid environment variable name: $name"}
        Set-Item -LiteralPath "Env:$name" -Value $trimmed.Substring($separator+1)
    }
}
$arguments=@('-m','uvicorn','app:app','--host','127.0.0.1','--port',"$Port")
if(-not $NoReload){$arguments+='--reload'}
Push-Location -LiteralPath $root
try{& $python @arguments}finally{Pop-Location}
