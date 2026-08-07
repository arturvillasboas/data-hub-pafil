# Camada Gold (star schema)

Camada de **consumo** (Power BI). Star schema sobre a [silver](../silver/README.md), seguindo o
[`MODELO_SEMANTICO.md`](../../MODELO_SEMANTICO.md). Medidas/KPIs e agregados vivem no Power BI;
aqui entregamos apenas os **fatos** e as **dimensões**.

Aplicar: `python aplicar_gold.py` (idempotente; valida contando linhas).

## Objetos

| Objeto | Tipo | Grão | Origem |
|---|---|---|---|
| `gold.fato_reservas` | fato | 1 reserva | `silver.reservas` ⨝ `silver.distratos` |
| `gold.dim_calendario` | dim | 1 dia | gerada (intervalo real das reservas) |
| `gold.dim_empreendimento` | dim | 1 empreend. | derivada de `silver.unidades` (+ região da reserva) |
| `gold.dim_unidade` | dim | 1 unidade | `silver.unidades` |
| `gold.dim_corretor` | dim | 1 corretor (id_corretor) | `silver.corretores` + equipe (headcount `dpara_corretor_headcount` — fonte primária; fallback: gerente da reserva mais recente ⨝ `dpara_gerente_contexto`, override DP-09) |
| `gold.dim_corretor_headcount` | dim | 1 corretor ATIVO (nome) | `silver.dpara_corretor_headcount` (equipe) ⨝ `dpara_imobiliaria_house` (Share/House-Parcerias/Regional pelo escritório). Sem join com `silver.corretores` — é o que gerava duplicidade/vazios na `dim_corretor`. **Relacionar por `corretor_chave`** (ver abaixo) |
| `gold.fato_leads` | fato | 1 lead | `silver.leads` |
| `gold.fato_precadastros` | fato | 1 pré-cadastro | `silver.precadastros` |

## Relacionamentos (montar no Power BI Desktop)

```
dim_calendario[data]                    1─* fato_reservas[data_venda]   (ativo; demais datas inativas)
dim_empreendimento[id_...]              1─* fato_reservas[id_empreendimento]
dim_unidade[id_unidade]                 1─* fato_reservas[id_unidade]
dim_corretor[id_corretor]               1─* fato_reservas[id_corretor]
dim_corretor_headcount[corretor_chave]  1─* fato_reservas[corretor_chave]
dim_corretor_headcount[corretor_chave]  1─* fato_leads[corretor_chave]
dim_corretor_headcount[corretor_chave]  1─* fato_precadastros[corretor_chave]
```

As dims também servem `fato_leads`/`fato_precadastros` (calendário por `data_cad`,
empreendimento e corretor). Os filtros da visão de leads (Equipe/Corretor via
`dim_corretor[equipe]`/`[nome]`, Produto via `dim_empreendimento`, mês/ano via
`dim_calendario[mes_nome]`+`[ano]`) chegam ao `fato_leads` por esses relacionamentos;
Canal/Mídia são colunas do próprio fato (`canal 2.0` / `midia acdc`).

**Ranking/filtro por gerente de venda em leads e pré-cadastros** (21/jul/2026): sai da
`dim_corretor_headcount` (roster manual do backoffice), relacionada às duas fatos por
**`corretor_chave`** — nunca por `corretor`. A chave é minúscula e sem acento (ING-09),
o que absorve a divergência de digitação entre o headcount e o CVDW; o nome bonito para
slicer/eixo é `dim_corretor_headcount[corretor]`. Ocultar as colunas `*_chave` no modelo.
Agrupar por `[supervisor]` (equipe direta) ou `[gerente]` (nível acima).

**Share / House-Parcerias / Regional em leads e pré-cadastros** (o equivalente ao que a
reserva tem via `dpara_gerente_contexto`): também sai da `dim_corretor_headcount`, que
traz `[share]`, `[house_parcerias]` e `[regional]` resolvidos pelo **escritório** do
corretor (DP-13). Não existe "Gerente Responsavel" nessas duas fatos, então a
classificação chega pelo corretor, não pelo gerente. Como é atributo de dimensão, basta
fatiar as fatos por essas colunas — nada precisa ser denormalizado nos fatos.

> **Por que a classificação NÃO foi fundida num de-para só:** `dpara_gerente_contexto`
> tem grão *gerente × contexto* (43 linhas; Marcio em 6, Castro em 5) e o headcount tem
> grão *corretor* (1 linha). Colar corretor lá quebraria a PK ou multiplicaria linhas.
> Além disso o contexto é chaveado por apelido ("Fred", "Marcio") e o headcount por nome
> completo — 3 dos 6 supervisores/gerentes ativos não casam. A unificação real acontece
> na **classificação** (Share/House/Regional), que mora toda no `depara_gerentes.xlsx`
> (abas "contexto" e "imobiliaria") e serve as três fatos por caminhos diferentes.

## Regras embutidas

- **R1 (dual-def de venda):** a fato expõe `eh_venda` e `eh_venda_ou_distrato`; o Power BI escolhe.
- **Distrato:** enriquece a fato por reserva (dedup defensivo: 1 distrato/reserva, o mais recente).
  Vendas no mês da venda e distratos no mês do distrato (como o legado) são reconstruídos no Power BI.
- **Data-ref do distrato:** `coalesce(situacao_data, data_sincronizacao, data_cad)` — 7 distratos têm
  `situacao_data` nula e seriam perdidos num bucket vazio.

## Validação (carga local, 14/jul/2026)

- `fato_reservas` 4.789 · `dim_empreendimento` 19 · `dim_unidade` 5.773 · `dim_corretor` 1.087 ·
  `dim_calendario` 1.461 · `fato_leads` 58.494 · `fato_precadastros` 6.485.
