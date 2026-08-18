# Runbook — incidentes operacionais

> **Escopo:** ambiente de **dev local** (Windows, PowerShell, sem direitos de admin).
> Operação do banco de **produção** (EC2) fica em [`infra/README.md`](infra/README.md).
> Como o ambiente foi montado da primeira vez: [`ONBOARDING.md`](ONBOARDING.md).

## Índice de sintomas

| Sintoma | Vá para |
|---|---|
| `OperationalError ... port 5433 ... Socket is not connected` ao rodar `ingestao.py`/`aplicar_tudo.py` | [1. O banco local não sobe](#1-o-banco-local-não-sobe-porta-5433) |
| `pg_ctl: could not start server` / `stopped waiting` | [1.2 Lock morto](#12-lock-morto-postmasterpid-órfão) e [1.3 Crash recovery](#13-crash-recovery-demorado) |
| `pg.ps1 status` reclama que o diretório não existe | [1.4 A pasta sumiu](#14-a-pasta-pafil_pg-sumiu--recriar-o-cluster) |
| Conectou, mas os números estão estranhos / é o banco errado | [2.2 Túnel de produção](#22-o-túnel-de-produção-está-ocupando-a-5433) |

---

## 1. O banco local não sobe (porta 5433)

**Por que acontece:** o Postgres de dev não é serviço do Windows — é uma instância
*user-space* na porta 5433, criada com `initdb` porque não há admin para mexer no
serviço da empresa (porta 5432). Instância user-space é **processo do usuário**:
morre em todo logoff/shutdown. Existe um `start_pafil_pg.vbs` na pasta Startup do
usuário que roda `pg.ps1 start` oculto a cada login, mas ele só cobre o caminho
feliz — quando o desligamento é sujo, o start automático também falha e cai neste
runbook.

O wrapper de controle é `%LOCALAPPDATA%\pafil_pg\pg.ps1` (`start|stop|status|restart`).

### 1.0 Diagnóstico (sempre comece aqui)

```powershell
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" status
```

| Resposta | O que é |
|---|---|
| `server is running` | O banco está de pé — o problema é outro (`.env`, porta, túnel). Veja a [seção 2](#2-depois-que-o-banco-sobe). |
| `no server running` | Siga para 1.1. |
| Erro dizendo que o diretório de dados não existe | Vá direto para [1.4](#14-a-pasta-pafil_pg-sumiu--recriar-o-cluster). |

### 1.1 Tentativa normal (resolve na maioria das vezes)

Anote o tamanho do log **antes** — é ele que vai distinguir os cenários seguintes:

```powershell
(Get-Item "$env:LOCALAPPDATA\pafil_pg\logfile.txt").Length
```

```powershell
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start
```

- **`server started`** → pronto. Valide na [seção 2.1](#21-validação-pós-start) e siga a vida.
  **Não precisa reingerir nada**: os dados estão no disco, só o processo tinha caído.
- **`could not start server` / `stopped waiting`** → compare o tamanho do log de novo:

| O log cresceu? | Significado | Ação |
|---|---|---|
| **Não** | O postmaster nem chegou a nascer — algo bloqueou antes de qualquer log | [1.2 Lock morto](#12-lock-morto-postmasterpid-órfão) |
| **Sim**, com `automatic recovery in progress` | Está só refazendo o WAL do desligamento sujo | [1.3 Crash recovery](#13-crash-recovery-demorado) |
| **Sim**, com outro erro | Leia o erro: `Get-Content "$env:LOCALAPPDATA\pafil_pg\logfile.txt" -Tail 30` | — |

### 1.2 Lock morto (`postmaster.pid` órfão)

Desligamento sujo (logoff, hibernação, queda de energia) mata o processo sem
shutdown limpo e deixa o `data\postmaster.pid` apontando para um PID que não
existe mais. O `pg_ctl` se recusa a subir por causa dele, mesmo com a porta livre.

> **Desde 17/ago/2026 o `pg.ps1 start` limpa esse lock sozinho** (ver
> [`infra/pg_local.ps1`](infra/pg_local.ps1)), e só quando comprova que não há
> servidor de verdade: PID do arquivo morto **e** porta 5433 livre. Ou seja, o
> caso mais comum agora se resolve no próprio start — inclusive no start
> automático do login. O procedimento manual abaixo continua valendo para quando
> você chama o `pg_ctl` direto, ou se a cópia local do `pg.ps1` for perdida numa
> limpeza de perfil.

> ⚠️ **Recheque a existência do arquivo imediatamente antes de cada tentativa de
> start.** Em 12/ago/2026 uma checagem disse "não existe" e minutos depois o
> arquivo estava lá — ausência num check anterior não vale como prova.

Confirme que é lock morto — **as duas checagens têm que dar negativo**:

```powershell
$p = Get-Content "$env:LOCALAPPDATA\pafil_pg\data\postmaster.pid" -TotalCount 3
"PID: $($p[0])  |  iniciado em: $(([datetimeoffset]::FromUnixTimeSeconds([int64]$p[2])).ToLocalTime())"
if (Get-Process -Id $p[0] -ErrorAction SilentlyContinue) { "PROCESSO VIVO - NAO APAGUE" } else { "processo morto" }
```

```powershell
Get-NetTCPConnection -LocalPort 5433 -State Listen -ErrorAction SilentlyContinue
```

Processo morto **e** nada ouvindo na 5433 → é lock morto. Apague e suba:

```powershell
Remove-Item "$env:LOCALAPPDATA\pafil_pg\data\postmaster.pid" -Force
```

```powershell
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start
```

Se houver processo vivo ou algo ouvindo na 5433, **não apague o pid** — há um
servidor de verdade usando esse data dir (ou um túnel na porta, ver [2.2](#22-o-túnel-de-produção-está-ocupando-a-5433));
apagar o lock nesse caso pode corromper o cluster.

### 1.3 Crash recovery demorado

Na primeira subida depois de um desligamento sujo, o Postgres refaz o WAL antes de
aceitar conexões. O log mostra:

```
LOG:  database system was not properly shut down; automatic recovery in progress
LOG:  redo starts at 3/99EACCF0
LOG:  database system is ready to accept connections
```

Neste cluster isso leva ~10 s, mas pode passar da espera do `pg_ctl`, que então
imprime `could not start server` **mesmo com o servidor subindo logo depois**.
Nesse caso não apague nada: espere e confirme com `pg.ps1 status`.

### 1.4 A pasta `pafil_pg` sumiu — recriar o cluster

Já aconteceu (07/jul/2026): a `%LOCALAPPDATA%\pafil_pg` inteira desapareceu —
suspeita de Storage Sense / limpeza de perfil corporativa. Os binários em
`C:\Program Files\PostgreSQL\16\bin` continuam.

```powershell
Test-Path "$env:LOCALAPPDATA\pafil_pg"
```

`False` → não dá para "subir", tem que recriar do zero:

1. Crie um arquivo texto **ASCII sem BOM** contendo a senha (a mesma do
   `PG_PASSWORD` no seu `.env`). Com BOM, a senha é gravada corrompida e você só
   descobre na hora de conectar.
2. Crie a pasta `pafil_pg`, mas deixe o `initdb` criar o `data`:

   ```powershell
   & "C:\Program Files\PostgreSQL\16\bin\initdb.exe" -D "$env:LOCALAPPDATA\pafil_pg\data" -U postgres -A scram-sha-256 --pwfile=<arquivo-ascii-sem-BOM> -E UTF8
   ```

3. Ajuste a porta (o default é 5432, que é o serviço da empresa):

   ```powershell
   Add-Content "$env:LOCALAPPDATA\pafil_pg\data\postgresql.conf" "`nport = 5433"
   ```

4. Restaure o wrapper a partir da cópia versionada e suba:

   ```powershell
   Copy-Item ".\infra\pg_local.ps1" "$env:LOCALAPPDATA\pafil_pg\pg.ps1"
   ```

   ```powershell
   & "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start
   ```

5. Recarregue o warehouse — aqui **sim** precisa reingerir, porque o cluster é novo:

   ```powershell
   python criar_database.py
   ```

   ```powershell
   python ingestao.py --full --criar-tabelas
   ```

   ```powershell
   python aplicar_tudo.py
   ```

   `--full` é obrigatório: cluster novo não tem `bronze._ingestao_controle`, logo
   não há marca de última execução para o delta.

6. Cheque se o `start_pafil_pg.vbs` ainda existe em
   `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` — a mesma limpeza que
   levou o cluster pode ter levado ele.

---

## 2. Depois que o banco sobe

### 2.1 Validação pós-start

```powershell
& "C:\Program Files\PostgreSQL\16\bin\psql.exe" -h localhost -p 5433 -U postgres -d pafil_dw -c "select current_database(), inet_server_port(), inet_server_addr()"
```

`inet_server_addr()` vazio/local = banco local. Se vier um IP, você está na
produção via túnel — ver 2.2.

### 2.2 O túnel de produção está ocupando a 5433

O acesso à produção (SSM/SSH port forwarding) termina em `localhost:5433`, a
**mesma porta** do banco local. Com o túnel aberto:

- `pg.ps1 start` falha (porta ocupada) — e não é lock morto, não apague o pid;
- pior, você pode achar que está no local quando está no banco real.

Feche o túnel, ou pare o local (`pg.ps1 stop`) antes de abri-lo. Na dúvida, rode o
`inet_server_addr()` acima. Detalhes no [`.env.example`](.env.example) e em
[`infra/README.md`](infra/README.md).

### 2.3 Ver processo `postgres` no Get-Process não significa nada

O serviço da empresa na 5432 aparece como ~7 processos `postgres` (com `StartTime`
vazio, porque rodam sob outro usuário e você não tem permissão de ler). Eles não
são a sua instância. Os sinais confiáveis são `pg.ps1 status` e
`Get-NetTCPConnection -LocalPort 5433`.

---

## 3. Histórico de incidentes

| Data | Sintoma | Causa | Correção |
|---|---|---|---|
| 07/jul/2026 | `Socket is not connected` na 5433 | Pasta `pafil_pg` inteira apagada (Storage Sense?) | Recriar cluster do zero + carga `--full` ([1.4](#14-a-pasta-pafil_pg-sumiu--recriar-o-cluster)) |
| 07/ago/2026 | Banco caindo a cada logoff | Instância é processo de usuário | `start_pafil_pg.vbs` na pasta Startup (não precisa de admin) |
| 18/jul/2026 | `could not start server`, porta livre | `postmaster.pid` órfão | Apagar o pid e subir ([1.2](#12-lock-morto-postmasterpid-órfão)) |
| 12/ago/2026 | Idem, mas a checagem do pid deu falso negativo | `postmaster.pid` órfão do servidor de 07/ago | Recheck do pid + apagar; crash recovery de ~10 s; dados intactos |
| 17/ago/2026 | Idem (3ª vez) — o auto-start do login não recuperou | `postmaster.pid` órfão do servidor de 14/ago; o `.vbs` tromba no lock e falha em silêncio | Limpeza automática do lock morto embutida no `pg.ps1 start` ([`infra/pg_local.ps1`](infra/pg_local.ps1)) |

> Ideia recorrente para reduzir reincidência: mover o `data` para fora do
> `%LOCALAPPDATA%` (ex.: `C:\pafil_pg`) tira o cluster do alvo das limpezas de
> perfil. Resolve o "sumiu", **não** resolve o "cai no logoff" — esse só some com
> serviço do Windows (precisa de admin) ou com o banco na EC2.
