# atualizar.ps1 — atualização rotineira dos dados locais (até a VPS).
#
# Sobe o Postgres local (idempotente), roda o incremental da API → bronze e
# ressincroniza os seeds de-para (gerentes vêm do xlsx do SharePoint via .env).
# Silver/Gold são VIEWS: refletem na hora, não precisam ser reaplicadas.
# Depois é só "Atualizar" no Power BI.
#
# Uso:
#   .\atualizar.ps1                      # incremental de todos os 19 objetos
#   .\atualizar.ps1 --objetos reservas,distratos,vendas   # só alguns
$ErrorActionPreference = "Stop"

Write-Host "==> Subindo o Postgres local (porta 5433)..." -ForegroundColor Cyan
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start

$py = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
Write-Host "==> Rodando ingestao incremental..." -ForegroundColor Cyan
& $py (Join-Path $PSScriptRoot "ingestao.py") --incremental @args

# Seeds de-para (idempotente, TRUNCATE+INSERT: relê o xlsx inteiro a cada run).
# Xlsx autoritativos via .env:
#   DEPARA_GERENTES_XLSX      — contexto do gerente (share/house/regional da reserva)
#   HEADCOUNT_CORRETORES_XLSX — roster de corretores ATIVOS + gerente/supervisor.
#                               Corretor novo/removido/inativado no Excel entra aqui.
#   DEPARA_LEADS_XLSM         — aba Apoio (canal/mídia, MQL, ativo/receptivo dos leads)
# NÃO repassa @args aqui: são flags da ingestao (ex.: --objetos), não do popular_seeds.
Write-Host "==> Sincronizando seeds de-para (xlsx do SharePoint)..." -ForegroundColor Cyan
& $py (Join-Path $PSScriptRoot "popular_seeds.py")

Write-Host ""
Write-Host "OK. Agora abra o Power BI e clique em Atualizar." -ForegroundColor Green
