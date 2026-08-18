# Como consultar as camadas localmente

Este é o passo a passo para inspecionar o warehouse local (as camadas bronze, silver
e gold, nessa ordem) rodando na instância PostgreSQL em modo user space, na porta
5433, banco `pafil_dw`. Vale só para validação local: o banco de produção vai rodar
numa instância EC2 da empresa (veja `ROADMAP.md` para o andamento desse
provisionamento).

## 1. Garantir que o banco está de pé

A instância local cai a cada logoff ou reinício do computador, porque roda como
processo de usuário, não como serviço do Windows. No PowerShell:

```powershell
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" status   # ver se está rodando
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start    # subir, se estiver parada
```

Se o `start` falhar, o roteiro de diagnóstico completo está em `RUNBOOK.md`.

## 2. Conectar

O jeito mais rápido é usar o atalho `consultar.ps1`, que lê as credenciais
diretamente do `.env`:

```powershell
.\consultar.ps1                      # abre uma sessão psql interativa
.\consultar.ps1 -c "SELECT 1"        # roda um comando específico e sai
.\consultar.ps1 -c "\dt silver.*"    # qualquer flag do psql pode ser repassada assim
```

Para usar um cliente gráfico como DBeaver ou pgAdmin, os parâmetros de conexão são:

| Campo | Valor |
|---|---|
| Host | `localhost` |
| Porta | `5433` |
| Database | `pafil_dw` |
| Usuário | `postgres` |
| Senha | `PafilLocalDev2026` (válida só para o ambiente local de desenvolvimento) |
| SSL | desabilitado (`disable`) |

## 3. Explorar o catálogo com os comandos de barra invertida do psql

```
\dn                     -- lista os schemas (bronze, silver, gold)
\dt bronze.*            -- tabelas da bronze
\dv silver.*            -- views da silver
\dt silver.*            -- tabelas (de-paras) da silver
\dv gold.*              -- views da gold
\d+ gold.fato_reservas  -- estrutura (colunas e tipos) de um objeto específico
\df silver.*            -- funções disponíveis (tentar_timestamptz, conformar_empreendimento, entre outras)
```

## 4. O que existe em cada schema

- **`bronze`**: 20 tabelas cruas, uma cópia fiel de cada objeto trazido da API
  (`reservas`, `vendas`, `distratos`, `unidades`, `corretores`, `imobiliarias`,
  `leads`, `precadastros`, `comissoes`, entre outras), mais uma tabela `_snapshot`
  para cada uma delas e a tabela de controle `_ingestao_controle`.
- **`silver`**: seis views conformadas (`reservas`, `vendas`, `distratos`,
  `unidades`, `corretores`, `imobiliarias`) e doze tabelas de-para, entre elas
  `dpara_canal_midia`, `dpara_gerente_contexto` (regra DP-01, usada só para
  classificar a reserva), `dpara_corretor_headcount` (regra DP-12, a fonte de
  equipe do corretor, que vem de uma planilha do backoffice),
  `dpara_empreendimento`, `dpara_qualificacao_lead`, `dpara_ordem_etapa` e
  `dpara_ativo_receptivo`, entre outras.
- **`gold`**: sete views, sendo três fatos (`fato_reservas`, `fato_leads`,
  `fato_precadastros`) e quatro dimensões (`dim_calendario`, `dim_empreendimento`,
  `dim_unidade`, `dim_corretor`).

## 5. Consultas de exemplo, por camada

**Bronze (o dado cru, exatamente como vem da API):**
```sql
SELECT idreserva, situacao, valor_contrato, data_venda FROM bronze.reservas LIMIT 10;
SELECT count(*) FROM bronze.reservas;
```

**Silver (já conformado, com as flags de cada regra aplicada):**
```sql
-- distribuição de situação com as flags da regra R1 (a dupla definição de "venda")
SELECT situacao, count(*),
       count(*) FILTER (WHERE eh_venda)    AS vendas,
       count(*) FILTER (WHERE eh_distrato) AS distratos
FROM silver.reservas GROUP BY situacao ORDER BY 2 DESC;

-- de-para de gerentes: o contexto da reserva e o headcount (equipe do corretor)
SELECT * FROM silver.dpara_gerente_contexto;
SELECT * FROM silver.dpara_corretor_headcount;

-- normalização de nome de pessoa (regra ING-09): forma de exibição vs. chave de junção
SELECT silver.nome_proprio('MAISA CRISTINA DE PAULA E SILVA');  -- Maisa Cristina de Paula e Silva
SELECT silver.chave_nome('Estéfane Vitória Alves de Souza');    -- estefane vitoria alves de souza
```

**Gold (fatos e dimensões; agregações mais elaboradas ficam por conta do Power BI):**
```sql
-- total geral, agregando direto na fato
SELECT round(sum(valor_contrato) FILTER (WHERE eh_venda))    AS vgv_bruto,
       count(*)                   FILTER (WHERE eh_venda)     AS qtd,
       round(sum(valor_contrato)  FILTER (WHERE eh_distrato)) AS vgv_distrato
FROM gold.fato_reservas;

-- VGV por mês e por empreendimento (nome já conformado)
SELECT ano_mes_venda, empreendimento_conformado,
       count(*) qtd, round(sum(valor_contrato)) vgv
FROM gold.fato_reservas
WHERE eh_venda AND ano_mes_venda >= '2026-01'
GROUP BY ano_mes_venda, empreendimento_conformado
ORDER BY ano_mes_venda DESC, vgv DESC;

-- a fato detalhada, linha a linha
SELECT id_reserva, empreendimento_conformado, situacao, valor_contrato, eh_venda, tem_distrato
FROM gold.fato_reservas WHERE eh_venda LIMIT 20;
```

## 6. Sair ou parar a instância

```
\q                                             -- sai do psql
```
```powershell
& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" stop     # opcional: para a instância local
```

## Dicas úteis dentro do psql

- `\x on` liga o modo expandido, útil para tabelas largas, como `bronze.reservas`,
  que tem cerca de 90 colunas.
- `\timing on` mostra quanto tempo cada consulta levou para rodar.
- `\o saida.txt` redireciona o resultado das próximas consultas para um arquivo; para
  voltar a exibir no console, basta digitar `\o` sozinho.
- `\copy (SELECT ...) TO 'arquivo.csv' CSV HEADER` exporta o resultado de uma
  consulta diretamente para um arquivo CSV.
