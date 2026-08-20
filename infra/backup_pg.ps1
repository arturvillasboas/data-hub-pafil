# backup_pg.ps1 -- dump logico diario do Pafil DW, com retencao (Windows).
#
# Instalado como uma Tarefa Agendada (rodando como SYSTEM) por
# RUNBOOK_WINDOWS.md, as 02:30 (America/Sao_Paulo), antes da ingestao diaria
# das 03:00. Rodar como SYSTEM e o que garante que ela dispara mesmo sem
# ninguem logado na instancia -- e o equivalente Windows do cron.d da versao
# Linux (infra/backup_pg.sh).
#
# Esta maquina NAO e uma instancia EC2 (confirmado em 20/ago/2026, ver a
# memoria "hospedagem-producao"): e fisica ou local, sem EBS e sem snapshot
# automatico por baixo. Por isso este dump nao e uma segunda camada de
# protecao, e a UNICA: se o disco desta maquina falhar, so existe recuperacao
# se $PastaExterna ou $BucketS3 abaixo estiver configurado e realmente
# copiando para fora dela. Deixar os dois vazios significa nao ter backup de
# verdade, so uma copia que morre junto com o problema que deveria cobrir.
#
# Ponto importante de retencao: a bronze e reconstruivel a partir da API com
# "ingestao.py --full", mas os SEEDS DE-PARA NAO SAO -- vem de planilhas
# mantidas a mao pelo backoffice. Se este backup falhar, e isso que se perde.
#
# Autenticacao: le a senha de $env:PGPASSFILE (ver RUNBOOK_WINDOWS.md, secao
# 6, para como criar o arquivo e a variavel de ambiente de sistema). Sem isso,
# o pg_dump abaixo trava esperando senha interativa -- e como e a SYSTEM que
# roda, ninguem ve o prompt, so falha silenciosamente.
#
# Uso manual (sessao elevada):  .\backup_pg.ps1

$ErrorActionPreference = "Stop"

$PgVersion    = "16"
$PgBin        = "C:\Program Files\PostgreSQL\$PgVersion\bin"
$DbNome       = "pafil_dw"
$UsuarioDump  = "pafil_app"
$DirBackup    = "C:\pafil\backups"
$RetencaoDias = 7
# Destino externo mais simples: uma pasta ja sincronizada nesta maquina (ex.:
# OneDrive/SharePoint do projeto, ver .env.example). Deixe vazio para pular.
# Caminho fixo (nao $env:OneDrive) de proposito: quem roda este script e a
# conta SYSTEM via Tarefa Agendada, que nao tem a sessao/perfil do OneDrive
# do usuario interativo, entao a variavel de ambiente nao existiria pra ela.
$PastaExterna = "C:\Users\rpa02\OneDrive - Pafil Construtora e Empreendimentos Imobiliarios\PafilDW-Backups"
# Alternativa mais robusta: um bucket S3 (requer AWS CLI instalada e
# credenciais configuradas nesta maquina via "aws configure" -- como nao e
# EC2, nao existe IAM role automatica). Deixe vazio para pular.
$BucketS3 = ""

function Log($msg) { Write-Host "$(Get-Date -Format o) $msg" }

$carimbo = Get-Date -Format "yyyyMMdd_HHmmss"
$arquivo = Join-Path $DirBackup "${DbNome}_${carimbo}.dump"

New-Item -ItemType Directory -Force -Path $DirBackup | Out-Null

# -Fc = formato custom: comprimido e restauravel seletivamente com pg_restore -t.
& (Join-Path $PgBin "pg_dump.exe") -U $UsuarioDump -h 127.0.0.1 -Fc -d $DbNome -f $arquivo
if ($LASTEXITCODE -ne 0) {
    Log "ERRO pg_dump falhou (codigo $LASTEXITCODE)"
    exit 1
}

$tamanho = (Get-Item $arquivo).Length
Log "OK  $arquivo ($([math]::Round($tamanho / 1MB, 1)) MB)"

# Replica fora da maquina -- um backup que so existe no disco que ele
# protege nao e backup. Os dois destinos sao independentes: pode usar so um,
# os dois, ou nenhum (mas nenhum e um risco real de perda, ver o topo do
# arquivo).
if ($PastaExterna) {
    if (Test-Path $PastaExterna) {
        Copy-Item $arquivo $PastaExterna -Force
        Log "OK  copiado para $PastaExterna"
    } else {
        Log "ERRO PastaExterna definida ($PastaExterna) mas o caminho nao existe"
    }
}

if ($BucketS3) {
    if (Get-Command aws -ErrorAction SilentlyContinue) {
        aws s3 cp $arquivo "$BucketS3/$(Split-Path $arquivo -Leaf)" --only-show-errors
        Log "OK  replicado para $BucketS3"
    } else {
        Log "ERRO BucketS3 definido mas a AWS CLI nao esta instalada"
    }
}

if (-not $PastaExterna -and -not $BucketS3) {
    Log "AVISO nenhum destino externo configurado -- este backup so existe nesta maquina"
}

# Retencao local. Roda depois do dump do dia, entao nunca fica sem copia.
Get-ChildItem $DirBackup -Filter "${DbNome}_*.dump" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetencaoDias) } |
    Remove-Item -Force

# Falha ruidosa: se o dump mais recente tiver menos de 1 MB, algo esta errado
# (banco vazio, permissao negada) e e melhor gritar do que acumular lixo.
if ($tamanho -lt 1MB) {
    Log "ALERTA dump com menos de 1MB -- verificar!"
    exit 1
}
