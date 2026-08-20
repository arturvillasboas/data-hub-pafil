# Runbook da infraestrutura de produção (Fase 7): versão Linux (histórico)

> **Atualização de 20 de agosto de 2026:** a EC2 Linux deste documento nunca
> chegou a ser provisionada. A TI liberou, em vez disso, credenciais de RDP
> para uma **máquina Windows 10 Pro física ou local** (confirmado por teste:
> o endereço de metadados da AWS deu timeout nela, então não é sequer uma
> instância AWS de qualquer sistema operacional). O runbook que reflete o que
> existe de verdade agora é [`RUNBOOK_WINDOWS.md`](RUNBOOK_WINDOWS.md); a
> linha do tempo completa da decisão está na memória "hospedagem-producao".
> Este arquivo continua aqui como referência: se a empresa algum dia migrar o
> banco para uma instância Linux de verdade, os scripts `.sh` e `systemd/`
> abaixo voltam a valer sem alteração.

Este é o passo a passo para sair do estado "nada provisionado" até chegar a "Power
BI lendo a camada gold no servidor da empresa". Ele cobre as etapas 7.2 a 7.5 do
`Roadmap_Projeto_Gestao.xlsx`. A etapa 7.1, que é pedir a instância, está descrita
no documento [`PEDIDO_TI.md`](PEDIDO_TI.md).

## O que tem nesta pasta

| Arquivo | Para que serve |
|---|---|
| [`PEDIDO_TI.md`](PEDIDO_TI.md) | Documento de apoio para a reunião com a TI (etapa 7.1) |
| [`provisionar_postgres.sh`](provisionar_postgres.sh) | Instala e configura o Postgres 16 na instância (etapa 7.2) |
| [`conf/postgresql-pafil.conf`](conf/postgresql-pafil.conf) | O tuning específico do projeto, aplicado como um drop-in de configuração |
| [`backup_pg.sh`](backup_pg.sh) | Roda o `pg_dump` diário, com retenção configurada (e envio opcional ao S3) |
| [`systemd/`](systemd/) | O service e o timer da ingestão diária, rodando na própria EC2 (etapa 7.4) |
| [`grants_bi.sql`](grants_bi.sql) | Concede ao Power BI a permissão de leitura sobre a gold (etapa 7.5) |

---

## 0. Pré-requisitos (o que a TI precisa entregar antes de começar)

- [ ] Instância EC2 em `sa-east-1`, com 2 vCPU, 4 GB de RAM, 50 GB em `gp3`, sempre
      ativa
- [ ] Sistema operacional definido: Ubuntu 22.04/24.04 LTS ou Amazon Linux 2023 (o
      script de provisionamento cobre os dois)
- [ ] Security Group sem nenhuma regra de entrada para a porta 5432
- [ ] Acesso administrativo configurado: um IAM Instance Profile com a policy
      `AmazonSSMManagedInstanceCore` (recomendado), ou então uma chave SSH
      combinada com uma lista de IPs liberados, incluindo o IP fixo do analista
- [ ] Saída para a internet liberada por HTTPS: a instância precisa alcançar
      `pafil.cvcrm.com.br` e os repositórios de pacotes do sistema operacional
- [ ] Snapshot diário do EBS já configurado

> Se o acesso for por SSM, nada mais precisa ser configurado do lado da rede: o
> Session Manager é a instância que se conecta para fora, em direção ao serviço da
> AWS, não o contrário.

## 1. Primeiro acesso

**Pelo SSM (recomendado).** Na máquina do analista, com a AWS CLI e o plugin do
Session Manager já instalados:

```bash
aws ssm start-session --target i-XXXXXXXXXXXX --region sa-east-1
```

**Pelo SSH (alternativa):**

```bash
ssh -i ~/.ssh/pafil-dw.pem ubuntu@<ip-privado-ou-publico>
```

Antes de seguir adiante, confirme que a instância está atualizada e enxerga a
internet:

```bash
curl -sSf -o /dev/null https://pafil.cvcrm.com.br && echo "API alcançável"
```

## 2. Instalar o PostgreSQL (etapa 7.2)

Primeiro, traga o repositório para dentro da instância. Use uma deploy key de
leitura do repositório privado (em Settings → Deploy keys), nunca a sua chave
pessoal:

```bash
sudo install -d -o "$USER" -g "$USER" /opt/pafil
git clone git@github.com:<org>/<repo>.git /opt/pafil/app
```

Depois, rode o script de provisionamento:

```bash
sudo bash /opt/pafil/app/infra/provisionar_postgres.sh
```

O script é idempotente (pode ser rodado mais de uma vez sem causar problema) e faz
o seguinte, nesta ordem: ajusta o timezone e ativa os patches automáticos, instala
o PostgreSQL 16 (usando o repositório PGDG no Ubuntu, ou o `dnf` no Amazon Linux
2023), aplica o arquivo `conf/postgresql-pafil.conf`, escreve um `pg_hba.conf` que
só aceita conexões locais, cria o banco `pafil_dw` e as roles `pafil_app` (a dona
do banco) e `pafil_bi` (somente leitura), e por fim instala o backup diário.

As senhas são geradas na própria máquina e gravadas em
`/root/pafil_credenciais.txt`, com permissão 0600. Leia esse arquivo com
`sudo cat /root/pafil_credenciais.txt` e copie os valores de lá para o `.env`.
Nenhuma senha passa por argumento de linha de comando ou fica salva no histórico
do shell.

Para conferir que deu certo:

```bash
sudo -u postgres psql -c "\l pafil_dw" -c "\du"
systemctl is-active postgresql@16-main   # no Amazon Linux 2023: systemctl is-active postgresql
```

## 3. Aplicar o schema e rodar a carga completa (etapa 7.3)

Prepare o Python dentro da própria instância. A carga completa leva algumas horas,
já que a API é limitada a cerca de 18 requisições por minuto e existem
aproximadamente 777 mil registros a carregar. Rodar isso a partir da máquina do
analista significaria depender do notebook não hibernar durante todo esse tempo.
Por isso, rode aqui, dentro de uma sessão `tmux`.

```bash
# Ubuntu 24.04 já traz o Python 3.12. No Amazon Linux 2023: sudo dnf install -y python3.11 python3.11-pip
sudo apt-get install -y python3.12-venv
python3 -m venv /opt/pafil/venv
/opt/pafil/venv/bin/pip install -r /opt/pafil/app/requirements.txt
```

Crie o arquivo de ambiente fora do repositório, legível apenas pelo serviço:

```bash
sudo install -d -m 750 /etc/pafil
sudo tee /etc/pafil/pafil.env >/dev/null <<'EOF'
CVCRM_SUBDOMINIO=pafil
CVCRM_EMAIL=<email do token>
CVCRM_TOKEN=<token>
PG_HOST=localhost
PG_PORT=5432
PG_DB=pafil_dw
PG_USER=pafil_app
PG_PASSWORD=<senha de /root/pafil_credenciais.txt>
PG_SSLMODE=disable
BRONZE_SCHEMA=bronze
EOF
sudo chmod 640 /etc/pafil/pafil.env
```

> `PG_SSLMODE=disable` é correto aqui, e só aqui: a conexão é feita em `localhost`,
> sem atravessar nenhuma rede. Qualquer conexão que saia da máquina deve usar
> `require` em vez disso.
>
> O formato do arquivo é `CHAVE=valor`, sem a palavra `export` e sem aspas. Isso
> permite que ele seja lido tanto pelo `EnvironmentFile` do systemd quanto por um
> simples `set -a; . /etc/pafil/pafil.env`.

Agora, rode a carga dentro do `tmux`, para sobreviver a uma eventual queda da
sessão:

```bash
tmux new -s carga
set -a; . /etc/pafil/pafil.env; set +a
cd /opt/pafil/app
/opt/pafil/venv/bin/python criar_database.py                  # idempotente
/opt/pafil/venv/bin/python ingestao.py --full --criar-tabelas # leva horas: aplica bronze.sql + faz a carga real
/opt/pafil/venv/bin/python aplicar_tudo.py                    # roda silver, gold e seeds
/opt/pafil/venv/bin/python conferir_carga.py                  # valida a origem (API) contra a bronze carregada
```

Use `Ctrl-b d` para desanexar da sessão, e `tmux attach -t carga` para voltar a
ela depois.

**O critério de aceite da etapa 7.3** é o seguinte: `conferir_carga.py` não pode
apontar nenhuma divergência, e a contagem de reservas precisa ficar acima das
4.756 da carga local parcial. É justamente essa carga completa que destrava a
reconciliação de totais (hoje só é possível reconciliar por chave individual).

## 4. Seeds de-para: a fronteira que continua manual

O comando `aplicar_tudo.py` popula os seeds a partir de planilhas do SharePoint e
do OneDrive, que simplesmente não existem em uma EC2 Linux. Dentro da instância,
os carregadores que dependem de arquivos `.xlsx` ou `.xlsm` não têm o que ler.

**Por isso, a atualização dos de-paras continua sendo rodada da máquina do
analista**, com o `.env` local apontando as variáveis `PG_*` para a EC2, através do
túnel descrito na seção 7 abaixo:

```bash
python popular_seeds.py
```

Isso não é uma dívida técnica a ser resolvida: é uma fronteira real, que existe
enquanto as planilhas de origem continuarem sendo mantidas à mão pelo backoffice
(veja a seção 4 de `ARCHITECTURE.md` para mais detalhes).

## 5. Atualização diária automática (etapa 7.4)

Crie o usuário de serviço e instale o timer:

```bash
sudo useradd --system --home /opt/pafil --shell /usr/sbin/nologin pafil
sudo chown -R pafil:pafil /opt/pafil
sudo install -d -o pafil -g pafil /var/log/pafil
sudo chgrp pafil /etc/pafil/pafil.env

sudo install -m 644 /opt/pafil/app/infra/systemd/pafil-ingestao.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pafil-ingestao.timer
```

Para verificar que funcionou:

```bash
systemctl list-timers pafil-ingestao.timer     # mostra o próximo disparo agendado
sudo systemctl start pafil-ingestao.service    # dispara a ingestão uma vez, agora
journalctl -u pafil-ingestao.service -f
```

> **Por que a ingestão roda aqui, e não no GitHub Actions.** O workflow
> `ingestao-diaria.yml` foi escrito originalmente supondo que um runner hospedado
> pelo GitHub se conectaria ao banco através de um `PG_HOST` público, com
> `sslmode=require`. Isso é incompatível com a regra de nunca expor a porta 5432:
> os runners do GitHub têm um IP dinâmico dentro de uma faixa pública enorme,
> então "liberar só o runner" na prática significa liberar meio mundo. Rodando
> dentro da própria instância, a conexão é feita em `localhost`, e nenhum segredo
> `PG_*` precisa existir fora da EC2. O workflow do GitHub Actions permanece
> apenas como um disparo manual de emergência.

## 6. Power BI (etapa 7.5)

Depois que a camada gold já existir, conceda a permissão de leitura:

```bash
sudo -u postgres psql -d pafil_dw -f /opt/pafil/app/infra/grants_bi.sql
```

**Atenção a um pré-requisito de plataforma:** o On-premises Data Gateway, da
Microsoft, só roda em Windows. Se a EC2 for Linux, o gateway simplesmente não pode
morar nela (veja a seção 4c de `PEDIDO_TI.md`). Existem dois caminhos possíveis:

- **Sem gateway, funcionando de imediato:** o Power BI Desktop conecta em
  `localhost:5432` através do túnel descrito na seção 7, usando o usuário
  `pafil_bi`. A atualização é manual, mas já é suficiente para montar o `.pbix`
  (etapa 6.5).
- **Com gateway, permitindo atualização agendada:** instale o gateway em um host
  Windows sempre ativo, troque o `listen_addresses` para o IP privado da instância
  dentro de `conf/postgresql-pafil.conf`, descomente a linha do `pg_hba.conf` que
  contém o CIDR do gateway, e libere a porta 5432 no Security Group referenciando
  o Security Group de origem, nunca um IP público nem `0.0.0.0/0`. Depois disso,
  rode `sudo systemctl reload postgresql@16-main`.

## 7. Túnel para acesso local do analista

**Pelo SSM.** Abre a porta 5432 da instância na sua porta 5433 local, a mesma
porta usada pelo Postgres de desenvolvimento, então o `consultar.ps1` e os
arquivos `.pbids` continuam funcionando sem nenhuma alteração:

```bash
aws ssm start-session --target i-XXXXXXXXXXXX --region sa-east-1 --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["5432"],"localPortNumber":["5433"]}'
```

**Pelo SSH:**

```bash
ssh -i ~/.ssh/pafil-dw.pem -L 5433:localhost:5432 -N ubuntu@<ip>
```

> Cuidado: se o Postgres local de desenvolvimento já estiver de pé na porta 5433,
> o túnel não vai conseguir subir, porque a porta já está ocupada. Pare o banco
> local antes, com `%LOCALAPPDATA%\pafil_pg\pg.ps1 stop`, ou use uma porta local
> diferente. Vale sempre conferir a qual banco você está conectado antes de rodar
> qualquer carga: `psql -h localhost -p 5433 -c "select inet_server_addr(), current_database()"`.

## 8. Operação do dia a dia

| Situação | Comando |
|---|---|
| A ingestão rodou hoje? | `systemctl status pafil-ingestao.service` |
| Ver o log da última ingestão | `journalctl -u pafil-ingestao.service --since today` |
| Rodar a ingestão fora do horário programado | `sudo systemctl start pafil-ingestao.service` |
| O backup rodou? | `tail /var/log/pafil-backup.log` |
| Fazer um backup manual antes de mexer em algo | `sudo /usr/local/sbin/backup_pg.sh` |
| Restaurar o banco inteiro | `pg_restore -d pafil_dw -c /var/backups/pafil/<arquivo>.dump` |
| Restaurar apenas uma tabela | `pg_restore -d pafil_dw -t <tabela> /var/backups/pafil/<arquivo>.dump` |
| Ver espaço em disco | `df -h /` e `sudo du -sh /var/lib/postgresql /var/backups/pafil` |
| Ver o tamanho do banco | `sudo -u postgres psql -d pafil_dw -c "\l+ pafil_dw"` |

## 9. Checklist de aceite da Fase 7

- [ ] Etapa 7.2: Postgres 16 ativo, `pg_hba` restrito a acesso local, senhas
      geradas na própria máquina, backup diário agendado no cron
- [ ] Etapa 7.3: `ingestao.py --full` concluída sem erro; `conferir_carga.py`
      sem apontar divergências; contagem de reservas acima de 4.756
- [ ] Etapa 7.3: `aplicar_tudo.py` reconstrói silver e gold no banco novo sem
      erro
- [ ] Etapa 7.3: reconciliação de totais refeita contra os relatórios legados (a
      carga parcial só permitia reconciliar por chave)
- [ ] Etapa 7.4: `pafil-ingestao.timer` habilitado, com disparo confirmado em
      `list-timers`
- [ ] Etapa 7.4: um run diário observado de ponta a ponta no `journalctl`
- [ ] Etapa 7.5: `grants_bi.sql` aplicado; o usuário `pafil_bi` lê a gold e não
      consegue ler a bronze
- [ ] Etapa 7.5: Power BI Desktop conectado pelo túnel, usando o usuário
      `pafil_bi`
- [ ] Etapa 7.5: a decisão sobre o gateway está registrada, seja com um host
      Windows já definido, seja adiada de forma consciente
- [ ] A porta 5432 foi confirmada como inalcançável de fora da VPC
- [ ] Uma restauração de backup foi testada de verdade (um backup nunca testado
      não é, na prática, um backup confiável)
