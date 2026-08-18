# Gerencia a instancia PostgreSQL user-space do projeto Pafil (porta 5433).
# Necessaria porque nao ha admin para usar o servico da empresa (porta 5432).
# A instancia roda como processo do usuario -> para no logoff/reboot; rode
# ".\pg.ps1 start" para subir de novo (o start_pafil_pg.vbs da pasta Startup
# faz isso automaticamente a cada login).
#
# O "start" limpa sozinho o postmaster.pid orfao que sobra de desligamento
# sujo -- mas so quando comprova que nao ha servidor de verdade: o PID do
# arquivo tem que estar morto E a porta 5433 tem que estar livre.
#
# Esta e a copia VERSIONADA. A que roda de verdade fica em
# %LOCALAPPDATA%\pafil_pg\pg.ps1 (essa pasta ja foi apagada por limpeza de
# perfil uma vez -- se sumir de novo, copie este arquivo de volta para la).
# Diagnostico completo de falhas: RUNBOOK.md.
#
# Uso:  .\pg.ps1 start | stop | status | restart [-Raiz <caminho>]
param(
    [Parameter(Mandatory=$true)][ValidateSet('start','stop','status','restart')]$acao,
    [string]$Raiz = (Join-Path $env:LOCALAPPDATA 'pafil_pg')
)

$bin     = 'C:\Program Files\PostgreSQL\16\bin'
$dataDir = Join-Path $Raiz 'data'
$logfile = Join-Path $Raiz 'logfile.txt'
$porta   = 5433

function Remove-LockOrfao {
    $pidFile = Join-Path $dataDir 'postmaster.pid'
    if (-not (Test-Path $pidFile)) { return }

    $pidAlvo = 0
    [void][int]::TryParse((Get-Content $pidFile -TotalCount 1), [ref]$pidAlvo)

    $proc = if ($pidAlvo -gt 0) { Get-Process -Id $pidAlvo -ErrorAction SilentlyContinue } else { $null }
    if ($proc -and $proc.ProcessName -like 'postgres*') {
        Write-Host "postmaster.pid aponta para o processo $pidAlvo, que esta vivo: nao vou mexer no lock."
        return
    }

    $ouvindo = @(Get-NetTCPConnection -LocalPort $porta -State Listen -ErrorAction SilentlyContinue)
    if ($ouvindo.Count -gt 0) {
        Write-Host "Ha algo ouvindo na porta $porta (PID $($ouvindo[0].OwningProcess)) -- servidor de verdade ou tunel de producao: nao vou mexer no lock."
        return
    }

    Write-Host "Lock orfao detectado (PID $pidAlvo morto, porta $porta livre): removendo postmaster.pid."
    Remove-Item $pidFile -Force
}

switch ($acao) {
    'start'   { Remove-LockOrfao; & "$bin\pg_ctl.exe" -D "$dataDir" -l "$logfile" start }
    'stop'    { & "$bin\pg_ctl.exe" -D "$dataDir" stop }
    'restart' { Remove-LockOrfao; & "$bin\pg_ctl.exe" -D "$dataDir" -l "$logfile" restart }
    'status'  { & "$bin\pg_ctl.exe" -D "$dataDir" status }
}
