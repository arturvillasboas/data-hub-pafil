# Como consultar as camadas localmente

Passo a passo para inspecionar o warehouse local (`bronze → silver → gold`) na instância
PostgreSQL user-space (porta 5433, db `pafil_dw`). Validação local apenas — o run de
produção vai para a VPS (ver `ROADMAP.md`).

## 1. Garantir o banco de pé

A instância local cai no logoff/reboot. No PowerShell:

```powershell
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" status   # ver se está rodando
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start    # subir se estiver parada
```

## 2. Conectar

Use o atalho **`consultar.ps1`** (lê as credenciais do `.env`):

```powershell
.\consultar.ps1                      # abre sessão psql interativa
.\consultar.ps1 -c "SELECT 1"        # roda um comando e sai
.\consultar.ps1 -c "\dt silver.*"    # qualquer flag do psql é repassada
```

Para um cliente gráfico (**DBeaver / pgAdmin**), os parâmetros de conexão:

| Campo | Valor |
|---|---|
| Host | `localhost` |
| Porta | `5433` |
| Database | `pafil_dw` |
| Usuário | `postgres` |
| Senha | `PafilLocalDev2026` (só dev local) |
| SSL | desabilitado (`disable`) |

## 3. Explorar o catálogo (comandos `\` do psql)

```
\dn                     -- lista os schemas (bronze, silver, gold)
\dt bronze.*            -- tabelas da bronze
\dv silver.*            -- views da silver
\dt silver.*            -- tabelas (de-paras) da silver
\dv gold.*              -- views da gold
\d+ gold.fato_reservas  -- estrutura (colunas/tipos) de um objeto
\df silver.*            -- funções (tentar_timestamptz, conformar_empreendimento...)
```

## 4. O que existe (inventário)

- **`bronze`** — 20 tabelas cruas da API (`reservas`, `vendas`, `distratos`, `unidades`,
  `corretores`, `imobiliarias`, `leads`, `precadastros`, `comissoes`...) + um `_snapshot`
  de cada e a `_ingestao_controle`.
- **`silver`** — 6 **views** conformadas (`reservas`, `vendas`, `distratos`, `unidades`,
  `corretores`, `imobiliarias`) + 12 **tabelas** de-para (`dpara_canal_midia`,
  `dpara_gerente_contexto` (DP-01, só p/ classificação de reserva),
  `dpara_corretor_headcount` (DP-12, fonte de equipe do corretor — planilha do backoffice),
  `dpara_empreendimento`, `dpara_qualificacao_lead`, `dpara_ordem_etapa`, `dpara_ativo_receptivo`...).
- **`gold`** — 7 **views**: `fato_reservas`, `fato_leads`, `fato_precadastros`,
  `dim_calendario`, `dim_empreendimento`, `dim_unidade`, `dim_corretor`.

## 5. Consultas de exemplo por camada

**Bronze (cru — como vem da API):**
```sql
SELECT idreserva, situacao, valor_contrato, data_venda FROM bronze.reservas LIMIT 10;
SELECT count(*) FROM bronze.reservas;
```

**Silver (conformado + flags de regra):**
```sql
-- distribuição de situação com as flags da R1 (dual-definição de "venda")
SELECT situacao, count(*),
       count(*) FILTER (WHERE eh_venda)    AS vendas,
       count(*) FILTER (WHERE eh_distrato) AS distratos
FROM silver.reservas GROUP BY situacao ORDER BY 2 DESC;

-- de-para de gerentes: contexto (reserva) + headcount (equipe do corretor)
SELECT * FROM silver.dpara_gerente_contexto;
SELECT * FROM silver.dpara_corretor_headcount;

-- normalização de nome de pessoa (ING-09): exibição vs chave de junção
SELECT silver.nome_proprio('MAISA CRISTINA DE PAULA E SILVA');  -- Maisa Cristina de Paula e Silva
SELECT silver.chave_nome('Estéfane Vitória Alves de Souza');    -- estefane vitoria alves de souza
```

**Gold (fatos + dimensões; agregados no Power BI):**
```sql
-- total geral (agrega direto na fato)
SELECT round(sum(valor_contrato) FILTER (WHERE eh_venda))    AS vgv_bruto,
       count(*)                   FILTER (WHERE eh_venda)     AS qtd,
       round(sum(valor_contrato)  FILTER (WHERE eh_distrato)) AS vgv_distrato
FROM gold.fato_reservas;

-- VGV por mês × empreendimento (nome já conformado)
SELECT ano_mes_venda, empreendimento_conformado,
       count(*) qtd, round(sum(valor_contrato)) vgv
FROM gold.fato_reservas
WHERE eh_venda AND ano_mes_venda >= '2026-01'
GROUP BY ano_mes_venda, empreendimento_conformado
ORDER BY ano_mes_venda DESC, vgv DESC;

-- a fato detalhada
SELECT id_reserva, empreendimento_conformado, situacao, valor_contrato, eh_venda, tem_distrato
FROM gold.fato_reservas WHERE eh_venda LIMIT 20;
```

## 6. Sair / parar

```
\q                                             -- sai do psql
```
```powershell
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" stop     -- (opcional) parar a instância
```

## Dicas (dentro do psql)

- `\x on` — modo expandido (bom para tabelas largas como `bronze.reservas`, ~90 colunas).
- `\timing on` — mostra o tempo de cada query.
- `\o saida.txt` — redireciona o resultado para arquivo; `\o` sozinho volta ao console.
- `\copy (SELECT ...) TO 'arquivo.csv' CSV HEADER` — exporta uma consulta para CSV.
