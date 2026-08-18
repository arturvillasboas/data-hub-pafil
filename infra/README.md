# Runbook — Infraestrutura de produção (Fase 7)

> Passo a passo para sair de "nada provisionado" até "Power BI lendo a gold no
> servidor da empresa". Cobre as etapas **7.2 a 7.5** do `Roadmap_Projeto_Gestao.xlsx`.
> A etapa **7.1** (pedir a instância) é o documento [`PEDIDO_TI.md`](PEDIDO_TI.md).
>
> **Estado em 12/ago/2026:** instância ainda não provisionada. Tudo aqui está escrito
> para ser executado, não para ser planejado — quando a EC2 existir, é seguir de cima
> para baixo.

## O que tem nesta pasta

| Arquivo | Para quê |
|---|---|
| [`PEDIDO_TI.md`](PEDIDO_TI.md) | Documento de apoio da reunião com a TI (etapa 7.1) |
| [`provisionar_postgres.sh`](provisionar_postgres.sh) | Instala e configura o Postgres 16 na instância (7.2) |
| [`conf/postgresql-pafil.conf`](conf/postgresql-pafil.conf) | Tuning do projeto, aplicado como drop-in |
| [`backup_pg.sh`](backup_pg.sh) | `pg_dump` diário com retenção (+ S3 opcional) |
| [`systemd/`](systemd/) | Service + timer da ingestão diária na própria EC2 (7.4) |
| [`grants_bi.sql`](grants_bi.sql) | Permissão de leitura do Power BI sobre a gold (7.5) |

---

## 0. Pré-requisitos (o que a TI precisa entregar)

- [ ] Instância EC2 em `sa-east-1`, 2 vCPU / 4 GB, 50 GB `gp3`, always-on
- [ ] SO definido: **Ubuntu 22.04/24.04 LTS** ou **Amazon Linux 2023** (o script cobre os dois)
- [ ] Security Group **sem nenhuma regra de entrada** para a porta 5432
- [ ] Acesso administrativo: **IAM Instance Profile com `AmazonSSMManagedInstanceCore`**
      (recomendado) **ou** chave SSH + allowlist do IP fixo do analista
- [ ] Saída para a internet liberada (HTTPS) — a instância precisa alcançar
      `pafil.cvcrm.com.br` e os repositórios de pacote
- [ ] Snapshot EBS diário configurado

> **Se o acesso for SSM**, nada mais é necessário do lado da rede: o Session Manager
> sai da instância para o serviço da AWS, não entra.

## 1. Primeiro acesso

**Via SSM (recomendado)** — na máquina do analista, com a AWS CLI e o plugin do
Session Manager instalados:

```bash
aws ssm start-session --target i-XXXXXXXXXXXX --region sa-east-1
```

**Via SSH (alternativa)**:

```bash
ssh -i ~/.ssh/pafil-dw.pem ubuntu@<ip-privado-ou-publico>
```

Confirme antes de seguir que a instância está atualizada e enxerga a internet:

```bash
curl -sSf -o /dev/null https://pafil.cvcrm.com.br && echo "API alcançável"
```

## 2. Instalar o PostgreSQL (etapa 7.2)

Traga o repositório para a instância. Use uma **deploy key de leitura** do repositório
privado (Settings → Deploy keys), nunca a sua chave pessoal:

```bash
sudo install -d -o "$USER" -g "$USER" /opt/pafil
git clone git@github.com:<org>/<repo>.git /opt/pafil/app
```

Rode o provisionamento:

```bash
sudo bash /opt/pafil/app/infra/provisionar_postgres.sh
```

O script é idempotente e faz: timezone + patches automáticos → PostgreSQL 16 (PGDG no
Ubuntu, `dnf` no AL2023) → aplica `conf/postgresql-pafil.conf` → escreve um `pg_hba.conf`
que só aceita conexão local → cria o database `pafil_dw` e as roles `pafil_app` (dono) e
`pafil_bi` (somente leitura) → instala o backup diário.

**As senhas são geradas na própria máquina** e gravadas em `/root/pafil_credenciais.txt`
(modo 0600). Leia com `sudo cat /root/pafil_credenciais.txt` e copie de lá para o `.env`.
Nenhuma senha passa por argumento de linha de comando ou histórico de shell.

Confira:

```bash
sudo -u postgres psql -c "\l pafil_dw" -c "\du"
systemctl is-active postgresql@16-main   # AL2023: systemctl is-active postgresql
```

## 3. Aplicar o schema e rodar a carga full (etapa 7.3)

Prepare o Python **na instância**. A carga completa leva horas (a API é limitada a ~18
requisições/minuto e são ~777 mil registros) — rodar da máquina do analista significa
depender do notebook não hibernar. Rode aqui, dentro de um `tmux`.

```bash
# Ubuntu 24.04 já traz o 3.12. No AL2023: sudo dnf install -y python3.11 python3.11-pip
sudo apt-get install -y python3.12-venv
python3 -m venv /opt/pafil/venv
/opt/pafil/venv/bin/pip install -r /opt/pafil/app/requirements.txt
```

Crie o arquivo de ambiente — **fora do repositório**, legível só pelo serviço:

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

> `PG_SSLMODE=disable` é correto **aqui e só aqui**: a conexão é `localhost`, não
> atravessa rede nenhuma. Qualquer conexão que saia da máquina usa `require`.
>
> Formato do arquivo: `CHAVE=valor`, sem `export` e sem aspas — é lido tanto pelo
> `EnvironmentFile` do systemd quanto por `set -a; . /etc/pafil/pafil.env`.

Agora a carga, em `tmux` para sobreviver à queda da sessão:

```bash
tmux new -s carga
set -a; . /etc/pafil/pafil.env; set +a
cd /opt/pafil/app
/opt/pafil/venv/bin/python criar_database.py                  # idempotente
/opt/pafil/venv/bin/python ingestao.py --full --criar-tabelas # ~horas: bronze.sql + carga real
/opt/pafil/venv/bin/python aplicar_tudo.py                    # silver -> gold -> seeds
/opt/pafil/venv/bin/python conferir_carga.py                  # valida origem (API) x bronze
```

`Ctrl-b d` desanexa; `tmux attach -t carga` volta.

**Critério de aceite da 7.3:** `conferir_carga.py` sem divergência, e a contagem de
reservas **acima** das 4.756 da carga local parcial — é justamente a carga completa que
destrava a reconciliação de **totais** (hoje só dá para reconciliar por chave).

## 4. Seeds de-para — a fronteira que continua manual

`aplicar_tudo.py` popula os seeds a partir de **planilhas do SharePoint/OneDrive**, que
não existem numa EC2 Linux. Na instância, os loaders que dependem de `.xlsx`/`.xlsm`
simplesmente não têm o que ler.

**Como fica:** a atualização dos de-paras é rodada **da máquina do analista**, com o
`.env` local apontando `PG_*` para a EC2 através do túnel (seção 7):

```bash
python popular_seeds.py
```

Isso não é débito técnico — é uma fronteira real enquanto as planilhas fonte forem
mantidas à mão pelo backoffice (ver `ARCHITECTURE.md` seção 4).

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

Verifique:

```bash
systemctl list-timers pafil-ingestao.timer     # próximo disparo
sudo systemctl start pafil-ingestao.service    # dispara uma vez, agora
journalctl -u pafil-ingestao.service -f
```

> **Por que aqui e não no GitHub Actions.** O workflow `ingestao-diaria.yml` foi escrito
> para um runner hospedado conectar no banco via `PG_HOST` público com `sslmode=require`.
> Isso é incompatível com a regra de não expor a porta 5432 — os runners do GitHub têm IP
> dinâmico numa faixa pública enorme, então "liberar só o runner" na prática é liberar
> meio mundo. Rodando na própria instância a conexão é `localhost`, e nenhum segredo
> `PG_*` precisa existir fora da EC2. O workflow fica como disparo manual de emergência.

## 6. Power BI (etapa 7.5)

Depois que a gold existir, conceda a leitura:

```bash
sudo -u postgres psql -d pafil_dw -f /opt/pafil/app/infra/grants_bi.sql
```

**Atenção ao pré-requisito de plataforma:** o *On-premises Data Gateway* da Microsoft
**só roda em Windows**. Se a EC2 for Linux, ele não mora nela (ver `PEDIDO_TI.md` seção
4c). Dois caminhos:

- **Sem gateway (imediato):** Power BI Desktop conecta em `localhost:5432` através do
  túnel da seção 7, com o usuário `pafil_bi`. Atualização manual — suficiente para montar
  o `.pbix` (etapa 6.5).
- **Com gateway (atualização agendada):** instale o gateway no host Windows always-on,
  troque `listen_addresses` para o IP privado da instância em
  `conf/postgresql-pafil.conf`, descomente a linha do `pg_hba.conf` com o CIDR do gateway,
  e libere a 5432 no Security Group **referenciando o SG de origem** — nunca um IP público
  nem `0.0.0.0/0`. Depois: `sudo systemctl reload postgresql@16-main`.

## 7. Túnel para acesso local (analista)

**Via SSM** — abre a 5432 da instância na sua 5433 local (a mesma porta do Postgres de
dev, então `consultar.ps1` e os `.pbids` continuam funcionando sem alteração):

```bash
aws ssm start-session --target i-XXXXXXXXXXXX --region sa-east-1 --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["5432"],"localPortNumber":["5433"]}'
```

**Via SSH:**

```bash
ssh -i ~/.ssh/pafil-dw.pem -L 5433:localhost:5432 -N ubuntu@<ip>
```

> Cuidado: se o Postgres **local** de dev estiver de pé na 5433, o túnel não sobe (porta
> ocupada) — pare com `%LOCALAPPDATA%\pafil_pg\pg.ps1 stop` antes, ou use outra porta
> local. Vale conferir onde você está conectado antes de rodar qualquer carga:
> `psql -h localhost -p 5433 -c "select inet_server_addr(), current_database()"`.

## 8. Operação do dia a dia

| Situação | Comando |
|---|---|
| A ingestão rodou hoje? | `systemctl status pafil-ingestao.service` |
| Log da última ingestão | `journalctl -u pafil-ingestao.service --since today` |
| Rodar a ingestão fora de hora | `sudo systemctl start pafil-ingestao.service` |
| Backup rodou? | `tail /var/log/pafil-backup.log` |
| Backup manual antes de mexer em algo | `sudo /usr/local/sbin/backup_pg.sh` |
| Restaurar o banco inteiro | `pg_restore -d pafil_dw -c /var/backups/pafil/<arquivo>.dump` |
| Restaurar **uma** tabela | `pg_restore -d pafil_dw -t <tabela> /var/backups/pafil/<arquivo>.dump` |
| Espaço em disco | `df -h /` e `sudo du -sh /var/lib/postgresql /var/backups/pafil` |
| Tamanho do banco | `sudo -u postgres psql -d pafil_dw -c "\l+ pafil_dw"` |

## 9. Checklist de aceite da Fase 7

- [ ] **7.2** Postgres 16 ativo, `pg_hba` só local, senhas geradas na máquina, backup diário no cron
- [ ] **7.3** `ingestao.py --full` concluída sem erro; `conferir_carga.py` limpo; contagem de reservas > 4.756
- [ ] **7.3** `aplicar_tudo.py` reconstrói silver/gold no banco novo sem erro
- [ ] **7.3** Reconciliação de **totais** refeita contra os relatórios legados (a parcial só permitia por chave)
- [ ] **7.4** `pafil-ingestao.timer` habilitado e com disparo confirmado no `list-timers`
- [ ] **7.4** Um run diário observado de ponta a ponta no `journalctl`
- [ ] **7.5** `grants_bi.sql` aplicado; `pafil_bi` lê a gold e **não** lê a bronze
- [ ] **7.5** Power BI Desktop conectado pelo túnel com o usuário `pafil_bi`
- [ ] **7.5** Decisão do gateway registrada (host Windows definido **ou** adiado conscientemente)
- [ ] Porta 5432 confirmada como **não alcançável** de fora da VPC
- [ ] Uma restauração de backup testada de verdade (backup não testado não é backup)
