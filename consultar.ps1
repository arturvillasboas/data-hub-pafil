# consultar.ps1 — abre o psql no banco local lendo as credenciais do .env.
#
# Uso:
#   .\consultar.ps1                      # abre sessão psql interativa
#   .\consultar.ps1 -c "SELECT 1"        # roda um comando e sai
#   .\consultar.ps1 -f script.sql        # roda um arquivo .sql
#   .\consultar.ps1 -c "\dt silver.*"    # qualquer flag do psql é repassada
$ErrorActionPreference = "Stop"

$envFile = Join-Path $PSScriptRoot ".env"
$cfg = @{}
Get-Content $envFile | Where-Object { $_ -match '^\s*PG_' } | ForEach-Object {
    $parts = $_ -split '=', 2
    $cfg[$parts[0].Trim()] = $parts[1].Trim()
}

$psql = "C:\Program Files\PostgreSQL\16\bin\psql.exe"
if (-not (Test-Path $psql)) { throw "psql não encontrado em $psql" }

$env:PGPASSWORD = $cfg['PG_PASSWORD']
# Console do Windows + PowerShell 5.1 mandam bytes cp1252; dizer ao psql que é WIN1252
# faz a conversão p/ o UTF-8 do banco funcionar nos dois sentidos (entrada e saída).
# (Se for rodar um .sql salvo em UTF-8 via -f, troque para: $env:PGCLIENTENCODING='UTF8'.)
$env:PGCLIENTENCODING = 'WIN1252'
& $psql -h $cfg['PG_HOST'] -p $cfg['PG_PORT'] -U $cfg['PG_USER'] -d $cfg['PG_DB'] @args
