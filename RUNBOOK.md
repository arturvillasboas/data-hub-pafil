# Runbook de incidentes operacionais

Este runbook cobre o ambiente de desenvolvimento local (Windows, PowerShell, sem
direitos de administrador). A operação do banco de produção, na instância EC2, está
documentada separadamente em [`infra/README.md`](infra/README.md). Para entender
como esse ambiente local foi montado da primeira vez, veja
[`ONBOARDING.md`](ONBOARDING.md).

## Índice de sintomas

Use esta tabela para ir direto ao ponto, a partir da mensagem de erro que você está
vendo:

| Sintoma | Vá para |
|---|---|
| `OperationalError ... port 5433 ... Socket is not connected` ao rodar `ingestao.py` ou `aplicar_tudo.py` | [1. O banco local não sobe](#1-o-banco-local-não-sobe-porta-5433) |
| `pg_ctl: could not start server` ou `stopped waiting` | [1.2 Lock morto](#12-lock-morto-postmasterpid-órfão) e [1.3 Crash recovery](#13-crash-recovery-demorado) |
| `pg.ps1 status` reclama que o diretório não existe | [1.4 A pasta sumiu](#14-recriando-o-cluster-depois-que-a-pasta-pafil_pg-sumiu) |
| Conectou, mas os números estão estranhos, ou parece ser o banco errado | [2.2 Túnel de produção](#22-o-túnel-de-produção-está-ocupando-a-5433) |

---

## 1. O banco local não sobe (porta 5433)

**Por que isso acontece:** o Postgres de desenvolvimento não é um serviço do
Windows. É uma instância em modo user space, na porta 5433, criada com `initdb`
porque não há permissão de administrador para mexer no serviço da empresa, que usa
a porta 5432. Uma instância user space é apenas um processo do usuário, e por isso
ela morre a cada logoff ou desligamento. Existe um script `start_pafil_pg.vbs` na
pasta Startup do usuário, que roda `pg.ps1 start` de forma oculta a cada login, mas
ele só cobre o caminho feliz: quando o desligamento é sujo (sem um shutdown limpo),
o start automático também falha, e é aí que este runbook entra.

O wrapper de controle da instância é `%LOCALAPPDATA%\pafil_pg\pg.ps1`, que aceita os
comandos `start`, `stop`, `status` e `restart`.

### 1.0 Diagnóstico (sempre comece por aqui)

```powershell
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" status
```

| Resposta | O que significa |
|---|---|
| `server is running` | O banco está de pé, o problema é outra coisa (`.env`, porta, túnel). Veja a [seção 2](#2-depois-que-o-banco-sobe). |
| `no server running` | Siga para a seção 1.1. |
| Erro dizendo que o diretório de dados não existe | Vá direto para a [seção 1.4](#14-recriando-o-cluster-depois-que-a-pasta-pafil_pg-sumiu). |

### 1.1 Tentativa normal (resolve a maioria dos casos)

Antes de tentar subir o banco, anote o tamanho do arquivo de log. Esse número vai
ajudar a distinguir os cenários seguintes:

```powershell
(Get-Item "$env:LOCALAPPDATA\pafil_pg\logfile.txt").Length
```

```powershell
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start
```

- Se a resposta for `server started`, está pronto. Valide na
  [seção 2.1](#21-validação-pós-start) e siga em frente: não é preciso reingerir
  nada, os dados continuam no disco, só o processo tinha caído.
- Se a resposta for `could not start server` ou `stopped waiting`, compare o
  tamanho do log de novo:

| O log cresceu? | O que isso significa | O que fazer |
|---|---|---|
| Não | O postmaster nem chegou a nascer, algo bloqueou antes de qualquer log ser escrito | [1.2 Lock morto](#12-lock-morto-postmasterpid-órfão) |
| Sim, com a mensagem `automatic recovery in progress` | O banco está apenas refazendo o WAL depois de um desligamento sujo | [1.3 Crash recovery](#13-crash-recovery-demorado) |
| Sim, com outro erro | Leia a mensagem completa: `Get-Content "$env:LOCALAPPDATA\pafil_pg\logfile.txt" -Tail 30` | Depende do erro específico encontrado |

### 1.2 Lock morto (`postmaster.pid` órfão)

Um desligamento sujo (logoff, hibernação, queda de energia) mata o processo sem um
shutdown limpo, e deixa o arquivo `data\postmaster.pid` apontando para um PID que já
não existe mais. O `pg_ctl` se recusa a subir por causa desse arquivo, mesmo com a
porta livre.

> Desde 17 de agosto de 2026, o comando `pg.ps1 start` já limpa esse lock sozinho
> (veja [`infra/pg_local.ps1`](infra/pg_local.ps1)), e só faz isso depois de
> confirmar que não existe um servidor de verdade rodando: o PID do arquivo precisa
> estar morto, e a porta 5433 precisa estar livre. Ou seja, o caso mais comum hoje
> se resolve sozinho no próprio start, inclusive no start automático do login. O
> procedimento manual abaixo continua valendo para quando você chama o `pg_ctl`
> diretamente, ou se a cópia local do `pg.ps1` for perdida em alguma limpeza de
> perfil.

> **Atenção:** recheque a existência do arquivo imediatamente antes de cada
> tentativa de start. Em 12 de agosto de 2026, uma checagem indicou que o arquivo
> "não existe", e minutos depois ele estava lá. A ausência detectada numa checagem
> anterior não é prova de nada no momento seguinte.

Para confirmar que é realmente um lock morto, as duas checagens abaixo precisam dar
negativo:

```powershell
$p = Get-Content "$env:LOCALAPPDATA\pafil_pg\data\postmaster.pid" -TotalCount 3
"PID: $($p[0])  |  iniciado em: $(([datetimeoffset]::FromUnixTimeSeconds([int64]$p[2])).ToLocalTime())"
if (Get-Process -Id $p[0] -ErrorAction SilentlyContinue) { "PROCESSO VIVO - NAO APAGUE" } else { "processo morto" }
```

```powershell
Get-NetTCPConnection -LocalPort 5433 -State Listen -ErrorAction SilentlyContinue
```

Se o processo estiver morto e nada estiver ouvindo na porta 5433, é um lock morto.
Apague o arquivo e suba a instância:

```powershell
Remove-Item "$env:LOCALAPPDATA\pafil_pg\data\postmaster.pid" -Force
```

```powershell
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start
```

Se houver um processo vivo, ou algo ouvindo na porta 5433, não apague o arquivo de
pid: existe um servidor de verdade usando esse diretório de dados (ou então é um
túnel de produção ocupando a porta, veja a
[seção 2.2](#22-o-túnel-de-produção-está-ocupando-a-5433)). Apagar o lock nesse
caso pode corromper o cluster.

### 1.3 Crash recovery demorado

Na primeira subida depois de um desligamento sujo, o Postgres refaz o WAL antes de
aceitar conexões. O log mostra algo como:

```
LOG:  database system was not properly shut down; automatic recovery in progress
LOG:  redo starts at 3/99EACCF0
LOG:  database system is ready to accept connections
```

Neste cluster, isso costuma levar cerca de 10 segundos, mas pode ultrapassar o
tempo de espera do `pg_ctl`, que nesse caso imprime `could not start server` mesmo
que o servidor termine de subir logo em seguida. Nessa situação, não apague nada:
espere um pouco e confirme com `pg.ps1 status`.

### 1.4 Recriando o cluster depois que a pasta pafil_pg sumiu

Isso já aconteceu antes, em 7 de julho de 2026: a pasta inteira
`%LOCALAPPDATA%\pafil_pg` desapareceu, provavelmente por causa do Storage Sense ou
de uma limpeza de perfil corporativa. Os binários em
`C:\Program Files\PostgreSQL\16\bin` continuam existindo normalmente.

```powershell
Test-Path "$env:LOCALAPPDATA\pafil_pg"
```

Se o resultado for `False`, não há como simplesmente "subir" a instância: é preciso
recriar o cluster do zero.

1. Crie um arquivo de texto em ASCII, sem BOM, contendo a senha (a mesma senha que
   está em `PG_PASSWORD` no seu `.env`). Se o arquivo tiver BOM, a senha é gravada
   de forma corrompida, e você só vai descobrir isso na hora de tentar conectar.
2. Crie a pasta `pafil_pg`, mas deixe o `initdb` criar a subpasta `data`:

   ```powershell
   & "C:\Program Files\PostgreSQL\16\bin\initdb.exe" -D "$env:LOCALAPPDATA\pafil_pg\data" -U postgres -A scram-sha-256 --pwfile=<arquivo-ascii-sem-BOM> -E UTF8
   ```

3. Ajuste a porta (o padrão é 5432, que é o serviço da empresa, não o seu):

   ```powershell
   Add-Content "$env:LOCALAPPDATA\pafil_pg\data\postgresql.conf" "`nport = 5433"
   ```

4. Restaure o wrapper de controle a partir da cópia versionada, e suba a instância:

   ```powershell
   Copy-Item ".\infra\pg_local.ps1" "$env:LOCALAPPDATA\pafil_pg\pg.ps1"
   ```

   ```powershell
   & "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start
   ```

5. Recarregue o warehouse. Desta vez, sim, é preciso reingerir os dados, porque o
   cluster é novo:

   ```powershell
   python criar_database.py
   ```

   ```powershell
   python ingestao.py --full --criar-tabelas
   ```

   ```powershell
   python aplicar_tudo.py
   ```

   A flag `--full` é obrigatória neste caso: um cluster novo não tem a tabela
   `bronze._ingestao_controle`, então não existe nenhuma marca de última execução
   para calcular o incremental.

6. Confira se o arquivo `start_pafil_pg.vbs` ainda existe em
   `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`. A mesma limpeza que
   apagou o cluster pode ter apagado esse arquivo também.

---

## 2. Depois que o banco sobe

### 2.1 Validação pós-start

```powershell
& "C:\Program Files\PostgreSQL\16\bin\psql.exe" -h localhost -p 5433 -U postgres -d pafil_dw -c "select current_database(), inet_server_port(), inet_server_addr()"
```

Se `inet_server_addr()` vier vazio ou como endereço local, você está no banco
local. Se vier um IP, você está conectado à produção através de um túnel; veja a
seção 2.2 abaixo.

### 2.2 O túnel de produção está ocupando a porta 5433

O acesso à produção, seja por SSM ou por redirecionamento de porta via SSH, termina
sempre em `localhost:5433`, a mesma porta usada pelo banco local. Com o túnel
aberto:

- o comando `pg.ps1 start` falha porque a porta já está ocupada, e isso não é um
  lock morto: não apague o arquivo de pid nessa situação;
- pior ainda, é fácil achar que você está no banco local quando na verdade está no
  banco real de produção.

Feche o túnel, ou pare o banco local com `pg.ps1 stop` antes de abrir o túnel. Na
dúvida, rode o comando `inet_server_addr()` da seção anterior. Mais detalhes estão
em [`.env.example`](.env.example) e em [`infra/README.md`](infra/README.md).

### 2.3 Ver um processo `postgres` no Get-Process não significa nada

O serviço da empresa, na porta 5432, aparece como cerca de 7 processos `postgres`
diferentes (com o campo `StartTime` vazio, porque rodam sob outro usuário, e você
não tem permissão para ler esses detalhes). Nenhum deles é a sua instância. Os
sinais confiáveis para saber o que está rodando são sempre `pg.ps1 status` e
`Get-NetTCPConnection -LocalPort 5433`.

---

## 3. Histórico de incidentes

| Data | Sintoma | Causa | Correção |
|---|---|---|---|
| 07/jul/2026 | `Socket is not connected` na porta 5433 | A pasta `pafil_pg` inteira foi apagada (suspeita de Storage Sense) | Recriar o cluster do zero, com carga `--full` (veja a [seção 1.4](#14-recriando-o-cluster-depois-que-a-pasta-pafil_pg-sumiu)) |
| 07/ago/2026 | Banco caindo a cada logoff | A instância é um processo de usuário, não um serviço | Script `start_pafil_pg.vbs` na pasta Startup, que não exige permissão de administrador |
| 18/jul/2026 | `could not start server`, com a porta livre | Arquivo `postmaster.pid` órfão | Apagar o pid e subir de novo (veja a [seção 1.2](#12-lock-morto-postmasterpid-órfão)) |
| 12/ago/2026 | O mesmo sintoma, mas a checagem do pid deu um falso negativo | `postmaster.pid` órfão, deixado por uma instância de 07/ago | Rechecar o pid antes de apagar; o crash recovery levou cerca de 10 segundos; os dados continuaram intactos |
| 17/ago/2026 | O mesmo sintoma pela terceira vez; o start automático do login não recuperou sozinho | `postmaster.pid` órfão de uma instância de 14/ago; o script `.vbs` esbarrava no lock e falhava silenciosamente | Limpeza automática do lock morto embutida diretamente no `pg.ps1 start` (veja [`infra/pg_local.ps1`](infra/pg_local.ps1)) |

> Uma ideia recorrente para reduzir a reincidência desses problemas é mover a pasta
> `data` para fora do `%LOCALAPPDATA%` (por exemplo, para `C:\pafil_pg`), o que
> tira o cluster do alcance das limpezas automáticas de perfil. Isso resolveria o
> problema da pasta "sumindo", mas não resolveria o banco "caindo no logoff": esse
> segundo problema só desaparece de vez com um serviço de verdade do Windows (que
> exige permissão de administrador) ou com o banco rodando na instância EC2 de
> produção.
