# ingerir_mdnet.ps1 -- carga rotineira do CDR de telefonia da MDnet (Windows).
#
# Roda as tres cargas incrementais em sequencia: as ligacoes (ingerir_mdnet.py), as pernas
# por direcao (ingerir_mdnet_pernas.py) e o relatorio de URA (ingerir_mdnet_ura.py). Cada uma
# cobre os ultimos MDNET_JANELA_DIAS dias (3 por padrao) e preserva o que ja esta gravado,
# entao rodar de hora em hora e barato (cerca de 20 pedidos ao painel por execucao) e nao
# duplica nada.
#
# Instalado como Tarefa Agendada, rodando como SYSTEM, por RUNBOOK_WINDOWS.md (secao 5.2).
# O .env da maquina precisa do bloco MDNET_* (usuario e senha do painel da MDnet).
#
# As cargas rodam mesmo se uma falhar, porque sao independentes. O codigo de saida e o
# numero de cargas que falharam (0 = tudo certo), e o motivo fica no log e na tabela
# bronze._ingestao_controle (nome_logico mdnet_cdr, mdnet_cdr_pernas e mdnet_ura).
#
# Uso manual:  .\ingerir_mdnet.ps1

$ErrorActionPreference = "Continue"

$Raiz   = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $Raiz ".venv\Scripts\python.exe"
$Falhas = 0

Write-Output ("==== MDnet {0} ====" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))

foreach ($Script in @("ingerir_mdnet.py", "ingerir_mdnet_pernas.py", "ingerir_mdnet_ura.py")) {
    & $Python (Join-Path $Raiz $Script) --incremental
    if ($LASTEXITCODE -ne 0) {
        Write-Output ("FALHOU: {0} (codigo {1})" -f $Script, $LASTEXITCODE)
        $Falhas++
    }
}

exit $Falhas
