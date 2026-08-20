# Runbook da infraestrutura de produção, versão Windows (Fase 7)

Este documento substitui o `README.md` desta pasta para a etapa atual do
projeto, e reflete a **terceira** decisão de hospedagem do projeto (a memória
`hospedagem-producao` guarda a linha do tempo completa):

1. Original: VPS DigitalOcean (Linux).
2. 07/ago/2026: trocado para AWS EC2 (Linux), por causa de uma licença
   corporativa já existente. `infra/PEDIDO_TI.md` e `infra/README.md` foram
   escritos em cima dessa decisão.
3. **20/ago/2026, decisão final:** a TI não provisionou a EC2. Em vez disso,
   passou credenciais de RDP para uma **máquina Windows física ou local**, já
   em uso, e confirmou que é essa mesma máquina o destino definitivo.
   Confirmado na prática (não por suposição): `Get-CimInstance
   Win32_OperatingSystem` devolveu **Windows 10 Pro** (não Server), `
   Get-CimInstance Win32_Processor` devolveu um Intel Core i5-2400 (CPU de
   desktop de 2011), e uma chamada ao endereço de metadados da AWS
   (`169.254.169.254`, que só responde de dentro de uma instância EC2 de
   verdade) deu timeout. Ou seja: **isto não é uma instância AWS.** Não existe
   Security Group, VPC, EBS ou snapshot automático por trás desta máquina.

`README.md` (bash/systemd, pensado para EC2 Linux) e `PEDIDO_TI.md` (o pedido
formal de EC2 que a TI acabou não atendendo) continuam na pasta como
histórico. Este arquivo é o que reflete o que existe de verdade, e os passos
abaixo foram ajustados para não pressupor nada de AWS: onde a versão anterior
deste runbook mencionava Security Group, EBS ou "instância EC2", o texto
agora fala em firewall do Windows, rede local da empresa e disco físico.

Isso muda uma coisa importante em relação ao plano original: **sem EBS, o
`pg_dump` diário deixa de ser uma segunda camada de proteção e passa a ser a
única rede de segurança contra perda de disco.** A seção 5 trata isso.

## A pergunta central: como o banco fica sempre ligado sem cair no logoff

Vale entender por que isso é mais simples aqui do que foi no notebook de
desenvolvimento (ver a memória sobre o Postgres local user-space). Lá, sem
direitos de administrador, o Postgres rodava como um processo comum do
usuário, então morria toda vez que a sessão do Windows terminava.

Nesta máquina você tem administrador de verdade, e isso muda o mecanismo:

- **O Postgres roda como Serviço do Windows.** O instalador oficial já
  registra o `postgres.exe` como serviço, numa sessão de sistema separada da
  sua sessão de RDP. Fechar o RDP, desconectar, ou até deslogar, não afeta um
  serviço. Só um `Stop-Service` explícito, ou desligar a máquina, para o
  banco. Não existe truque nenhum aqui além de deixar o `Startup Type` como
  `Automatic`, que é o padrão do instalador (o `provisionar_postgres.ps1`
  confirma isso de qualquer forma).
- **Desconectar do RDP não é a mesma coisa que deslogar.** Se você fechar a
  janela do RDP (ou clicar no X), a sessão fica em estado "Disconnected", mas
  os programas que você deixou abertos dentro dela continuam rodando.
  Reconectando depois, você encontra tudo do jeito que deixou, como uma
  sessão do `tmux`. Isso só some se alguém escolher explicitamente "Sign out"
  na sessão, ou se a máquina reiniciar. Então, para rodar algo longo
  interativamente (a carga `--full`, por exemplo), já basta desconectar sem
  deslogar. Se a política de segurança da empresa tiver um GPO de logoff
  automático em sessões desconectadas, use o Agendador de Tarefas em vez
  disso (seção 4 abaixo), que é imune a isso de qualquer forma.
- **A automação diária roda como conta `SYSTEM` no Agendador de Tarefas.**
  Isso é o equivalente Windows do `systemd timer` da versão Linux. Uma tarefa
  rodando como `SYSTEM` não depende de nenhuma sessão de usuário estar
  aberta, então funciona mesmo com ninguém logado na máquina.

Combinando os três: o único jeito de o banco realmente cair é alguém parar o
serviço de propósito, ou a máquina ser desligada. Nenhum dos dois acontece
por causa de logoff.

**Ressalva que não existia no plano de EC2:** como é Windows 10 Pro, e não
Server, só é permitida **uma sessão remota por vez**. Se outra pessoa
(inclusive alguém da TI) logar nessa máquina localmente ou por RDP enquanto
você está conectado, sua sessão é desconectada. Isso não derruba o Postgres
nem as tarefas agendadas (são serviços do sistema, não dependem da sua
sessão), mas vale confirmar com a TI se esta máquina é de uso exclusivo do
projeto, ou se é compartilhada com outra finalidade.

## O que tem nesta pasta (arquivos específicos do Windows)

| Arquivo | Para que serve |
|---|---|
| [`provisionar_postgres.ps1`](provisionar_postgres.ps1) | Aplica a configuração do projeto sobre um Postgres já instalado (etapa 7.2) |
| [`conf/postgresql-pafil-windows.conf`](conf/postgresql-pafil-windows.conf) | O tuning específico do projeto, aplicado como drop-in de configuração |
| [`backup_pg.ps1`](backup_pg.ps1) | Roda o `pg_dump` diário, com retenção e cópia para fora da máquina |
| [`grants_bi.sql`](grants_bi.sql) | Concede ao Power BI a permissão de leitura sobre a gold (mesmo arquivo da versão Linux, SQL puro) |

---

## 1. Primeiro acesso e conferência do ambiente

Conecte pelo Remote Desktop Connection (`mstsc`) do Windows, usando o IP e as
credenciais que a TI passou. Assim que entrar, rode isto num PowerShell
elevado (botão direito, "Executar como Administrador"). Repare que os
comandos usam `Get-CimInstance`, não `systeminfo`/`whoami /groups`: essas
duas ferramentas devolvem texto no idioma do Windows instalado, e essa
máquina está em português, então um filtro de texto em inglês (`Select-String
"OS Name"`) não acha nada e falha em silêncio. `Get-CimInstance` devolve
nomes de propriedade em inglês sempre, independente do idioma do sistema:

```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, OSArchitecture, @{n='RAM_GB';e={[math]::Round($_.TotalVisibleMemorySize/1MB,1)}}
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors
Get-Volume | Select-Object DriveLetter, FileSystemLabel, SizeRemaining, Size
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, Size
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

O que conferir:

- **Memória real.** O `postgresql-pafil-windows.conf` foi escrito com os
  valores do pedido original à TI (2 vCPU / 4 GB), pensados para a EC2 que
  não veio a existir. Ajuste `shared_buffers` (~25% da RAM) e
  `effective_cache_size` (~75% da RAM) para o valor real de RAM_GB acima
  antes do passo 2.
- **Tipo de disco (`MediaType` do `Get-PhysicalDisk`).** O drop-in de config
  assume `random_page_cost = 1.1`, que só faz sentido em SSD. Se o resultado
  vier `HDD` (ou `Unspecified` numa máquina antiga, o que é comum), volte
  esse parâmetro para o padrão do Postgres (`4.0`) antes de aplicar a
  configuração, ou o planner do banco vai tomar decisões erradas de índice.
- **Discos disponíveis.** Se houver um segundo volume além do `C:`, é
  possível apontar o diretório de dados do Postgres para lá no passo 2. Se só
  existir o `C:`, confirme que sobra espaço suficiente (o banco tem hoje
  cerca de 777 mil linhas na bronze, folga de alguns GB já é confortável).
- **Direitos de administrador.** O último comando acima precisa devolver
  `True`. Sem isso, nenhum passo deste runbook funciona.

## 2. Instalar e configurar o PostgreSQL (etapa 7.2)

O `provisionar_postgres.ps1` não instala o Postgres: ele só configura por
cima de uma instalação que já existe. Instale primeiro pelo instalador
oficial da EnterpriseDB (o mesmo distribuidor usado no `pg_local.ps1` de
desenvolvimento), baixando a versão **16** para Windows x86-64 no site oficial
do PostgreSQL. Durante a instalação:

- Anote a senha do superusuário `postgres` que você definir no instalador.
  Ela não é salva em lugar nenhum pelo instalador, e o script do passo
  seguinte vai pedir ela.
- Deixe o "Data Directory" no padrão, dentro do `C:`. O `D:` desta máquina
  (rotulado "DADOS") está com só ~200 MB livres de 480 GB, não serve de
  destino. O `C:` tem ~105 GB livres, de sobra para este projeto.
- Deixe a porta como `5432` (padrão) e o locale como `Portuguese, Brazil` ou
  `C` (qualquer um serve, a camada silver já tipa os dados explicitamente).
- Pode desmarcar o Stack Builder ao final, não é necessário.

Confirme que o serviço subiu:

```powershell
Get-Service postgresql*
```

(Nesta máquina já confirmado: os dois discos são SSD, então o
`random_page_cost = 1.1` do drop-in já está correto, não precisa mexer. Se a
máquina mudar no futuro, reconfira com `Get-PhysicalDisk` antes deste passo.)

Agora clone o repositório na máquina (instale o Git primeiro, se não estiver
presente: `winget install --id Git.Git -e`) e rode o script de configuração:

```powershell
git clone https://github.com/<org>/<repo>.git C:\pafil\app
cd C:\pafil\app\infra
.\provisionar_postgres.ps1
```

O script vai pedir a senha do `postgres` uma vez, e então: escreve o
`postgresql-pafil.conf` como drop-in, restringe o `pg_hba.conf` a conexões
locais com senha (`scram-sha-256`), cria os roles `pafil_app` (dono do banco)
e `pafil_bi` (somente leitura), cria o banco `pafil_dw`, grava as senhas
geradas em `C:\pafil\pafil_credenciais.txt` (permissão restrita ao grupo
Administrators via `icacls`), e confirma que o serviço está com `Startup
Type = Automatic`.

Para conferir que deu certo:

```powershell
Get-Service postgresql-x64-16
Get-Content C:\pafil\pafil_credenciais.txt
```

## 3. Preparar o Python e aplicar o schema (etapa 7.3)

Instale o Python 3.12 (`winget install --id Python.Python.3.12 -e`, ou o
instalador do python.org) e monte o ambiente virtual:

```powershell
cd C:\pafil\app
py -3.12 -m venv .venv
.\.venv\Scripts\pip install -r requirements.txt
```

Crie o `.env` do projeto (fora do controle de versão, igual ao `.env.example`
da raiz), com os dados do banco local desta máquina e o token do CVDW:

```
CVCRM_SUBDOMINIO=pafil
CVCRM_EMAIL=<email do token>
CVCRM_TOKEN=<token>
PG_HOST=localhost
PG_PORT=5432
PG_DB=pafil_dw
PG_USER=pafil_app
PG_PASSWORD=<senha de C:\pafil\pafil_credenciais.txt>
PG_SSLMODE=disable
BRONZE_SCHEMA=bronze
```

> `PG_SSLMODE=disable` é correto aqui, e só aqui: a conexão é feita em
> `localhost`, sem atravessar rede nenhuma. Qualquer conexão que saia da
> máquina (o túnel do analista, seção 8) deve usar `require`.

A carga completa (`--full`) demora horas, porque a API do CVDW é limitada a
cerca de 18 requisições por minuto e há aproximadamente 777 mil registros.
Como uma sessão de RDP desconectada (não deslogada) mantém os processos
vivos, o jeito mais simples é rodar direto, e só desconectar do RDP sem
deslogar:

```powershell
cd C:\pafil\app
.\.venv\Scripts\python criar_database.py                  # idempotente
.\.venv\Scripts\python ingestao.py --full --criar-tabelas  # leva horas
.\.venv\Scripts\python aplicar_tudo.py                     # silver, gold e seeds
.\.venv\Scripts\python conferir_carga.py                   # valida origem vs bronze
```

Se preferir não depender de lembrar de não deslogar, ou se outra pessoa pode
precisar logar nessa máquina (ver a ressalva de sessão única acima), use uma
tarefa agendada de disparo único, rodando como `SYSTEM` (mesmo mecanismo da
seção 5, então sobrevive a qualquer desconexão ou troca de sessão):

```powershell
schtasks /Create /TN "PafilDW - Carga full (unica)" /RU SYSTEM /RL HIGHEST /SC ONCE /ST 23:59 /F `
  /TR "cmd /c C:\pafil\app\.venv\Scripts\python.exe C:\pafil\app\ingestao.py --full --criar-tabelas > C:\pafil\logs\carga_full.log 2>&1"
schtasks /Run /TN "PafilDW - Carga full (unica)"
```

Acompanhe com `Get-Content C:\pafil\logs\carga_full.log -Wait -Tail 20`, e
apague a tarefa quando terminar (`schtasks /Delete /TN "PafilDW - Carga full (unica)" /F`).

**O critério de aceite da etapa 7.3** é o mesmo da versão Linux:
`conferir_carga.py` não pode apontar divergência nenhuma, e a contagem de
reservas precisa ficar acima das 4.756 da carga local parcial.

## 4. Seeds de-para: a fronteira que continua manual

Igual à versão Linux: `aplicar_tudo.py` popula os seeds a partir de planilhas
do SharePoint/OneDrive, que não existem dentro desta máquina. A atualização
dos de-paras continua rodando da máquina do analista, com o `.env` local
apontando para cá através do túnel (seção 8):

```powershell
python popular_seeds.py
```

Isso não é dívida técnica, é uma fronteira real enquanto as planilhas de
origem forem mantidas à mão pelo backoffice (seção 4 de `ARCHITECTURE.md`).

## 5. Backup e atualização diária automática (etapa 7.4)

**Isto é mais importante aqui do que era no plano de EC2.** Lá, o `pg_dump`
era uma segunda camada de proteção, atrás do snapshot automático do EBS. Sem
EBS, se o disco desta máquina falhar (ou a máquina for perdida, roubada,
reimaginada numa manutenção), **o único jeito de recuperar o banco é um dump
que tenha sido copiado para fora dela.** `infra/backup_pg.ps1` já grava o
dump localmente em `C:\pafil\backups`; abra o arquivo e configure pelo menos
um destino externo antes de considerar o backup real:

- **Mais simples de começar hoje:** preencha `$PastaExterna` no topo do
  `backup_pg.ps1` com o caminho de uma pasta do OneDrive/SharePoint já
  sincronizada nesta máquina (o projeto já depende pesado dessas pastas para
  outras fontes, ver `.env.example`). O script copia o dump para lá depois de
  gerar.
- **Mais robusto, mas depende de credencial AWS própria:** preencher a
  variável `$BucketS3` no topo do script com um bucket S3 e configurar a AWS
  CLI (`aws configure`) nesta máquina com uma IAM user de escopo mínimo
  (`s3:PutObject` só nesse bucket). Isso funciona mesmo a máquina não sendo
  EC2, só exige credenciais configuradas manualmente em vez de uma IAM role.

Escolha pelo menos um antes de considerar a etapa 7.4 concluída. Um backup
que só existe no mesmo disco que ele deveria proteger não é backup.

Crie as pastas de log e a variável de ambiente de sistema que dá ao
`pg_dump`/`ingestao.py` como achar a senha do banco sem ela aparecer em
nenhum argumento de linha de comando:

```powershell
New-Item -ItemType Directory -Force -Path C:\pafil\logs, C:\pafil\backups | Out-Null

# Arquivo de senha no formato do libpq (hostname:porta:database:usuario:senha).
@"
127.0.0.1:5432:pafil_dw:pafil_app:<senha de pafil_app, de pafil_credenciais.txt>
"@ | Set-Content -Path C:\pafil\pgpass.conf -Encoding ascii
icacls C:\pafil\pgpass.conf /inheritance:r /grant:r "*S-1-5-18:(R)" "*S-1-5-32-544:(R,W)" | Out-Null

[Environment]::SetEnvironmentVariable("PGPASSFILE", "C:\pafil\pgpass.conf", "Machine")
```

> `*S-1-5-18` é o SID fixo da conta `SYSTEM` em qualquer instalação Windows
> (não depende de idioma do sistema operacional), e `*S-1-5-32-544` é o grupo
> `Administrators`. Usar o SID em vez do nome evita depender de o Windows
> estar em português ou inglês.

Agora registre as duas tarefas, ambas como `SYSTEM` (por isso rodam mesmo com
ninguém logado):

```powershell
schtasks /Create /TN "PafilDW - Backup diario" /RU SYSTEM /RL HIGHEST /SC DAILY /ST 02:30 /F `
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\pafil\app\infra\backup_pg.ps1"

schtasks /Create /TN "PafilDW - Ingestao diaria" /RU SYSTEM /RL HIGHEST /SC DAILY /ST 03:00 /F `
  /TR "cmd /c C:\pafil\app\.venv\Scripts\python.exe C:\pafil\app\ingestao.py --incremental >> C:\pafil\logs\ingestao.log 2>&1"
```

Os horários replicam a versão Linux: backup às 02:30, ingestão às 03:00 (dá
30 minutos de folga entre um e outro), sempre horário de Brasília, porque é o
fuso configurado no Windows desta máquina (confirme com `Get-TimeZone`; se
não for `E. South America Standard Time`, ajuste com `Set-TimeZone` ou os
horários acima vão disparar na hora errada).

Para conferir que funcionou:

```powershell
Get-ScheduledTask -TaskName "PafilDW*" | Select-Object TaskName, State
schtasks /Run /TN "PafilDW - Ingestao diaria"    # dispara uma vez, agora, fora do horário
Get-Content C:\pafil\logs\ingestao.log -Tail 30
```

> **Por que a ingestão roda aqui, e não no GitHub Actions.** Mesmo motivo da
> versão Linux: o `pg_hba.conf` só aceita `127.0.0.1`, então um runner
> hospedado pelo GitHub, com IP dinâmico numa faixa pública enorme, não
> conseguiria alcançar o banco sem abrir a porta 5432 para fora, que é
> exatamente a regra que protege o dado de LGPD. Rodando na própria máquina,
> a conexão é `localhost`, e nenhum segredo `PG_*` precisa existir fora dela.
> O workflow `ingestao-diaria.yml` do GitHub Actions continua existindo só
> como disparo manual de emergência.

## 6. Power BI (etapa 7.5)

Depois que a camada gold já existir (fim da seção 3), conceda a permissão de
leitura. O `grants_bi.sql` é SQL puro, roda igual em qualquer sistema
operacional:

```powershell
& "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U pafil_app -h 127.0.0.1 -d pafil_dw -f C:\pafil\app\infra\grants_bi.sql
```

Como esta máquina já é Windows, a pendência que o `PEDIDO_TI.md` (seção 4c)
deixava em aberto está resolvida por construção: instale o **On-premises Data
Gateway** da Microsoft direto nesta máquina (baixe o instalador oficial na
página do Power BI, procurando por "On-premises Data Gateway"). Ele fica
sempre ativo pelo mesmo motivo do Postgres, é serviço do Windows, e conecta
no banco por `localhost`, sem precisar abrir a porta 5432 para fora da
própria máquina. Isso destrava a atualização agendada dentro do Power BI
Service, não só a manual pelo Power BI Desktop.

Se, por qualquer razão, o gateway acabar precisando morar em outra máquina
Windows da empresa, aí sim é necessário: trocar `listen_addresses` para o IP
privado desta máquina no `postgresql-pafil-windows.conf`, descomentar a linha
do `pg_hba.conf` com o CIDR de origem do gateway, e pedir a quem administra a
rede da empresa para liberar a porta 5432 apenas para o IP daquela máquina,
nunca de forma ampla. Isso é um pedido de rede, não um passo que se faz de
dentro desta máquina (ver observação na seção 8).

## 7. Firewall do Windows

Sem Security Group da AWS por trás desta máquina, **o Firewall do Windows
deixa de ser uma camada redundante e passa a ser a principal defesa de
rede.** Por padrão ele já bloqueia conexões de entrada não solicitadas,
incluindo a 5432, o que é o comportamento desejado: mesmo que alguém, por
engano, mude `listen_addresses` para além de `localhost`, o Firewall do
Windows ainda barra. Confirme que ele está ativo:

```powershell
Get-NetFirewallProfile | Select-Object Name, Enabled
```

Só abra a porta explicitamente se o gateway do Power BI acabar morando em
outra máquina (seção 6), e sempre escopado por IP de origem, nunca "qualquer
um":

```powershell
New-NetFirewallRule -DisplayName "PafilDW - Postgres (gateway)" -Direction Inbound `
  -Protocol TCP -LocalPort 5432 -RemoteAddress <IP do host do gateway> -Action Allow
```

Vale também confirmar com a TI/rede em que segmento da rede da empresa esta
máquina está: se ela está no mesmo segmento que estações de trabalho comuns
(em vez de isolada como um servidor costuma ficar), o Firewall do Windows é
a única coisa entre o banco (com dado pessoal, LGPD) e qualquer outro
computador da rede interna. Isso não bloqueia a etapa 7.2 a seguir, mas é
uma pergunta que vale a pena levar à TI em paralelo.

## 8. Acesso do analista ao banco

Como o acesso a esta máquina é por RDP, o caminho mais direto é **instalar o
Power BI Desktop dentro da própria máquina** e trabalhar ali, conectando em
`localhost:5432` sem nenhum túnel. É a opção mais simples e a que exige
menos coordenação com a TI. A ressalva da sessão única do Windows 10 Pro
(seção "pergunta central") se aplica aqui: se outra pessoa logar nesta
máquina enquanto você trabalha, sua sessão (e o Power BI Desktop aberto
nela) é desconectada.

Se preferir continuar usando o Power BI Desktop e o `psql` do seu próprio
notebook (mais confortável no dia a dia, evita depender desta máquina estar
disponível para RDP), habilite o recurso opcional **OpenSSH Server** do
Windows aqui, que é o equivalente Windows ao SSH usado na versão Linux:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

Isso exige pedir a quem administra a rede da empresa para permitir a porta
22 até esta máquina, restrita ao seu IP fixo (o mesmo modelo de acesso que o
`PEDIDO_TI.md` já descrevia como alternativa ao SSM na versão Linux, só que
agora é uma regra de rede local em vez de Security Group). Do seu notebook,
o túnel fica assim (mesma porta local 5433 usada pelo Postgres de
desenvolvimento, então `consultar.ps1` e os `.pbids` continuam funcionando
sem alteração):

```powershell
ssh -L 5433:localhost:5432 -N <usuario>@<ip-da-maquina>
```

> Cuidado: se o Postgres local de desenvolvimento já estiver de pé na porta
> 5433, o túnel não sobe, porque a porta já está ocupada. Pare o banco local
> antes (`%LOCALAPPDATA%\pafil_pg\pg.ps1 stop`), ou use uma porta local
> diferente. Confira sempre a qual banco você está conectado antes de rodar
> qualquer carga: `psql -h localhost -p 5433 -c "select inet_server_addr(), current_database()"`.

**A porta 5432 nunca é liberada para fora da rede da empresa em nenhum dos
dois caminhos.** A abertura da porta 22 (se for o caminho escolhido) depende
de quem administra a rede local. Leve isso como um pedido específico, não
como algo que se resolve de dentro desta máquina.

## 9. Operação do dia a dia

| Situação | Comando |
|---|---|
| O Postgres está de pé? | `Get-Service postgresql-x64-16` |
| A ingestão rodou hoje? | `Get-ScheduledTaskInfo -TaskName "PafilDW - Ingestao diaria"` |
| Ver o log da última ingestão | `Get-Content C:\pafil\logs\ingestao.log -Tail 50` |
| Rodar a ingestão fora do horário programado | `schtasks /Run /TN "PafilDW - Ingestao diaria"` |
| O backup rodou (e foi copiado pra fora)? | `Get-ScheduledTaskInfo -TaskName "PafilDW - Backup diario"` |
| Fazer um backup manual antes de mexer em algo | `.\infra\backup_pg.ps1` (sessão elevada) |
| Restaurar o banco inteiro | `pg_restore -U pafil_app -h 127.0.0.1 -d pafil_dw -c C:\pafil\backups\<arquivo>.dump` |
| Restaurar apenas uma tabela | `pg_restore -U pafil_app -h 127.0.0.1 -d pafil_dw -t <tabela> C:\pafil\backups\<arquivo>.dump` |
| Ver espaço em disco | `Get-Volume` |
| Ver o tamanho do banco | `psql -U pafil_app -h 127.0.0.1 -d pafil_dw -c "\l+ pafil_dw"` |

## 10. Checklist de aceite da Fase 7 (versão Windows, máquina física/local)

- [ ] Etapa 7.2: Postgres 16 ativo como serviço `Automatic`, `pg_hba`
      restrito a `127.0.0.1`/`::1`, senhas geradas na própria máquina, roles
      `pafil_app`/`pafil_bi` criados
- [ ] Etapa 7.2: `random_page_cost` conferido contra o tipo de disco real
      (SSD mantém 1.1, HDD volta para 4.0)
- [ ] Etapa 7.3: `ingestao.py --full` concluída sem erro; `conferir_carga.py`
      sem apontar divergências; contagem de reservas acima de 4.756
- [ ] Etapa 7.3: `aplicar_tudo.py` reconstrói silver e gold no banco novo sem
      erro
- [ ] Etapa 7.3: reconciliação de totais refeita contra os relatórios legados
- [ ] Etapa 7.4: as duas tarefas agendadas (`PafilDW - Backup diario` e
      `PafilDW - Ingestao diaria`) aparecem como `Ready` em
      `Get-ScheduledTask`, rodando como `SYSTEM`
- [ ] Etapa 7.4: um run diário observado de ponta a ponta no log
- [ ] Etapa 7.4: `backup_pg.ps1` configurado com pelo menos um destino FORA
      desta máquina (pasta sincronizada de OneDrive/SharePoint, ou S3)
- [ ] Etapa 7.5: `grants_bi.sql` aplicado; o usuário `pafil_bi` lê a gold e
      não consegue ler a bronze
- [ ] Etapa 7.5: Power BI conectado (direto na máquina, ou pelo túnel SSH),
      usando o usuário `pafil_bi`
- [ ] Etapa 7.5: On-premises Data Gateway instalado nesta mesma máquina, ou
      a decisão de adiar isso está registrada conscientemente
- [ ] A porta 5432 foi confirmada como inalcançável de fora da rede da
      empresa (Firewall do Windows ativo, e confirmado com a TI/rede o que
      mais protege esta máquina na rede interna)
- [ ] Testado que o Postgres continua respondendo depois de: fechar o RDP
      sem deslogar, deslogar de propósito, outra pessoa logar na máquina
      (sessão única do Windows 10 Pro), e reiniciar a máquina
- [ ] Uma restauração de backup foi testada de verdade, a partir da cópia
      que está FORA desta máquina (um backup nunca restaurado, ou que só
      existe no mesmo disco que protege, não é backup confiável)
- [ ] Confirmado com a TI se esta máquina é de uso exclusivo do projeto, e
      se ela está fora do ciclo normal de reimageamento/manutenção de
      estações de trabalho da empresa
