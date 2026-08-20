# provisionar_postgres.ps1 -- configura o PostgreSQL 16 na maquina Windows de
# producao do Pafil DW.
#
# Etapa 7.2 do roadmap (versao Windows -- a TI passou credenciais de RDP para
# uma maquina Windows fisica/local, NAO uma EC2; ver RUNBOOK_WINDOWS.md e a
# memoria "hospedagem-producao" para o historico da decisao). Idempotente:
# pode rodar de novo sem quebrar nada.
#
# Este script NAO instala o PostgreSQL: pressupoe que o instalador oficial do
# PostgreSQL 16 (EDB, postgresql.org/download/windows) ja rodou e criou o
# servico do Windows. Ele so aplica a configuracao do projeto por cima disso
# (drop-in de config, pg_hba, roles, database, startup automatico).
#
# Requer sessao elevada (Administrador). Rode de dentro do clone do
# repositorio, na propria maquina.
#
# Uso:
#   .\provisionar_postgres.ps1

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$PgVersion = "16"
$DbNome    = "pafil_dw"
$RoleApp   = "pafil_app"   # dono do banco: ingestao + DDL das camadas
$RoleBi    = "pafil_bi"    # somente leitura: Power BI / gateway
$CredDir   = "C:\pafil"
$ArqCred   = Join-Path $CredDir "pafil_credenciais.txt"
$ScriptDir = $PSScriptRoot

function Log($msg)   { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Aviso($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }

# --- 0. Localiza o servico, os binarios e o data dir --------------------------
$servico = Get-Service -Name "postgresql-x64-$PgVersion*" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $servico) {
    throw "Servico do PostgreSQL $PgVersion nao encontrado (Get-Service postgresql*). Instale primeiro com o instalador oficial -- ver RUNBOOK_WINDOWS.md, passo 2."
}
Log "Servico encontrado: $($servico.Name) ($($servico.Status))"

$svcInfo = Get-CimInstance Win32_Service -Filter "Name='$($servico.Name)'"
if ($svcInfo.PathName -notmatch '-D\s+"([^"]+)"') {
    throw "Nao consegui deduzir o data dir a partir do comando do servico ($($svcInfo.PathName)). Edite o script e informe `$DataDir manualmente."
}
$DataDir = $Matches[1]
$PgBin   = Split-Path (Split-Path $svcInfo.PathName.Trim('"').Split(' ')[0])
$Psql    = Join-Path $PgBin "psql.exe"
Log "Data dir: $DataDir"
Log "Binarios: $PgBin"

if (-not (Test-Path $Psql)) {
    throw "psql.exe nao encontrado em $PgBin. Confira a instalacao."
}

# --- 1. Senha do superusuario (pedida uma unica vez nesta sessao) -------------
if (-not $env:PGPASSWORD) {
    $senhaSegura = Read-Host "Senha do superusuario 'postgres' (definida na instalacao)" -AsSecureString
    $env:PGPASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($senhaSegura))
}

function Psql-Root([string]$sql) {
    & $Psql -U postgres -h 127.0.0.1 -p 5432 -v ON_ERROR_STOP=1 -tAc $sql
}

# --- 2. Aplica a configuracao do projeto (drop-in em conf.d) ------------------
Log "Aplicando conf.d\postgresql-pafil.conf"
$dropinDir = Join-Path $DataDir "conf.d"
New-Item -ItemType Directory -Force -Path $dropinDir | Out-Null
Copy-Item (Join-Path $ScriptDir "conf\postgresql-pafil-windows.conf") (Join-Path $dropinDir "postgresql-pafil.conf") -Force

$confPrincipal = Join-Path $DataDir "postgresql.conf"
if (-not (Select-String -Path $confPrincipal -Pattern "^include_dir" -Quiet)) {
    Add-Content -Path $confPrincipal -Value "`ninclude_dir = 'conf.d'"
}

# --- 3. pg_hba.conf: so localhost, sempre com senha ---------------------------
Log "Escrevendo pg_hba.conf"
$pgHba = Join-Path $DataDir "pg_hba.conf"
@'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
# host  pafil_dw        pafil_bi        10.0.0.0/16             scram-sha-256   # gateway Power BI (7.5)
'@ | Set-Content -Path $pgHba -Encoding ascii

Restart-Service $servico.Name
Start-Sleep -Seconds 3

# --- 4. Roles e database -------------------------------------------------------
function New-SenhaForte {
    -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
}
function Existe-Role([string]$nome) { (Psql-Root "SELECT 1 FROM pg_roles WHERE rolname='$nome'") -eq "1" }
function Existe-Db([string]$nome)   { (Psql-Root "SELECT 1 FROM pg_database WHERE datname='$nome'") -eq "1" }

if (Test-Path $ArqCred) {
    Aviso "$ArqCred ja existe -- mantendo as senhas atuais (nao regenero)."
} else {
    Log "Gerando senhas e criando roles"
    $SenhaApp = New-SenhaForte
    $SenhaBi  = New-SenhaForte
    New-Item -ItemType Directory -Force -Path $CredDir | Out-Null

    if (-not (Existe-Role $RoleApp)) { Psql-Root "CREATE ROLE $RoleApp LOGIN PASSWORD '$SenhaApp'" | Out-Null }
    if (-not (Existe-Role $RoleBi))  { Psql-Root "CREATE ROLE $RoleBi LOGIN PASSWORD '$SenhaBi'" | Out-Null }

    @"
# Credenciais do Pafil DW -- geradas por provisionar_postgres.ps1 em $(Get-Date -Format o)
# Copie para o .env da maquina do analista. NAO versionar. NAO colar em chat/e-mail.
$RoleApp=$SenhaApp
$RoleBi=$SenhaBi
"@ | Set-Content -Path $ArqCred -Encoding ascii

    icacls $ArqCred /inheritance:r | Out-Null
    icacls $ArqCred /grant:r "*S-1-5-32-544:(R,W)" | Out-Null  # grupo Administrators, por SID (independe do idioma do SO)
}

if (-not (Existe-Db $DbNome)) {
    Psql-Root "CREATE DATABASE $DbNome OWNER $RoleApp ENCODING 'UTF8' TEMPLATE template0" | Out-Null
}

Psql-Root "REVOKE ALL ON DATABASE $DbNome FROM PUBLIC" | Out-Null
Psql-Root "GRANT CONNECT ON DATABASE $DbNome TO $RoleApp, $RoleBi" | Out-Null

Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue

# --- 5. Garante que o servico sobrevive a logoff/reboot -----------------------
# Isto e o que substitui o systemd enable da versao Linux: um servico do
# Windows roda sob a sessao de servicos do SO, nao sob a sessao RDP de ninguem
# -- fechar ou deslogar o RDP nao afeta ele. So um "Stop-Service" explicito, ou
# desligar a instancia, para o banco.
Set-Service -Name $servico.Name -StartupType Automatic
Log "Servico $($servico.Name) configurado como Automatic (sobrevive a logoff e reboot)."

# --- 6. Resumo ------------------------------------------------------------------
Log "Pronto."
@"

  Servico ......... $($servico.Name) ($((Get-Service $servico.Name).Status))
  Database ........ $DbNome
  Roles ........... $RoleApp (dono) | $RoleBi (somente leitura)
  Config .......... $dropinDir\postgresql-pafil.conf
  pg_hba .......... $pgHba (apenas localhost)
  Credenciais ..... $ArqCred

  Proximo passo: RUNBOOK_WINDOWS.md, secao "3. Aplicar o schema e rodar a carga full".

"@
