# Camada gold (star schema)

Esta é a camada de consumo, usada diretamente pelo Power BI. É um star schema
construído sobre a [silver](../silver/README.md), seguindo o desenho descrito em
[`MODELO_SEMANTICO.md`](../../MODELO_SEMANTICO.md). As medidas, os KPIs e os
agregados ficam por conta do Power BI; aqui na gold entregamos apenas os fatos e
as dimensões.

Para aplicar: `python aplicar_gold.py` (idempotente, e valida contando as linhas
de cada objeto).

## Objetos

| Objeto | Tipo | Grão | Origem |
|---|---|---|---|
| `gold.fato_reservas` | fato | 1 reserva | `silver.reservas` cruzada com `silver.distratos` |
| `gold.dim_calendario` | dimensão | 1 dia | gerada, cobrindo o intervalo real das reservas |
| `gold.dim_empreendimento` | dimensão | 1 empreendimento | derivada de `silver.unidades`, com a região vinda da reserva |
| `gold.dim_unidade` | dimensão | 1 unidade | `silver.unidades` |
| `gold.dim_corretor` | dimensão | 1 corretor (`id_corretor`) | `silver.corretores`, com a equipe vindo do headcount (`dpara_corretor_headcount` como fonte primária; como fallback, o gerente da reserva mais recente cruzado com `dpara_gerente_contexto`, seguindo o override da regra DP-09) |
| `gold.dim_corretor_headcount` | dimensão | 1 corretor ativo (por nome) | `silver.dpara_corretor_headcount` (a equipe) cruzada com `dpara_imobiliaria_house` (Share, House/Parcerias e Regional, resolvidos pelo escritório). Não tem join com `silver.corretores`, que era justamente o que gerava duplicidade e valores vazios em `dim_corretor`. Relacione sempre por `corretor_chave` (veja mais abaixo) |
| `gold.fato_leads` | fato | 1 lead | `silver.leads` |
| `gold.fato_precadastros` | fato | 1 pré-cadastro | `silver.precadastros` |

## Relacionamentos (a montar no Power BI Desktop)

```
dim_calendario[data]                    1─* fato_reservas[data_venda]   (ativo; as demais datas ficam inativas)
dim_empreendimento[id_...]              1─* fato_reservas[id_empreendimento]
dim_unidade[id_unidade]                 1─* fato_reservas[id_unidade]
dim_corretor[id_corretor]               1─* fato_reservas[id_corretor]
dim_corretor_headcount[corretor_chave]  1─* fato_reservas[corretor_chave]
dim_corretor_headcount[corretor_chave]  1─* fato_leads[corretor_chave]
dim_corretor_headcount[corretor_chave]  1─* fato_precadastros[corretor_chave]
```

As mesmas dimensões também servem `fato_leads` e `fato_precadastros` (o
calendário entra por `data_cad`, além de empreendimento e corretor). Os filtros
da visão de leads, como Equipe/Corretor (via `dim_corretor[equipe]` e `[nome]`),
Produto (via `dim_empreendimento`) e mês/ano (via `dim_calendario[mes_nome]` e
`[ano]`), chegam até `fato_leads` através desses relacionamentos. Canal e Mídia,
por outro lado, já são colunas da própria fato (`canal 2.0` e `midia acdc`).

**Ranking e filtro por gerente de venda, em leads e pré-cadastros** (desde 21 de
julho de 2026): vem de `dim_corretor_headcount`, o roster mantido manualmente
pelo backoffice, relacionada às duas fatos sempre por `corretor_chave`, nunca por
`corretor`. Essa chave fica em minúsculas e sem acento (regra ING-09), o que
absorve as divergências de digitação entre o headcount e o CVDW. O nome já
formatado, para usar em slicer ou eixo, é `dim_corretor_headcount[corretor]`. As
colunas `*_chave` devem ficar ocultas no modelo. É possível agrupar por
`[supervisor]` (a equipe direta) ou por `[gerente]` (um nível acima).

**Share, House/Parcerias e Regional, em leads e pré-cadastros** (o equivalente ao
que a reserva já tem através de `dpara_gerente_contexto`): também vem de
`dim_corretor_headcount`, que traz `[share]`, `[house_parcerias]` e `[regional]`
já resolvidos pelo escritório do corretor (regra DP-13). Não existe um campo
"Gerente Responsável" nessas duas fatos, então a classificação chega pelo
corretor, não pelo gerente. Como é um atributo de dimensão, basta fatiar as
fatos por essas colunas: nada precisa ser denormalizado dentro delas.

> **Por que essa classificação não foi unificada em um único de-para:**
> `dpara_gerente_contexto` tem grão de gerente cruzado com contexto (43 linhas;
> Marcio aparece em 6 delas, Castro em 5), enquanto o headcount tem grão de
> corretor (1 linha por pessoa). Colar a coluna corretor naquela tabela quebraria
> a chave primária, ou multiplicaria linhas indevidamente. Além disso, o contexto
> é chaveado por apelido ("Fred", "Marcio"), enquanto o headcount usa o nome
> completo; 3 dos 6 supervisores e gerentes ativos não conseguem casar entre os
> dois. A unificação de verdade acontece na classificação (Share, House e
> Regional), que mora inteira em `depara_gerentes.xlsx` (nas abas "contexto" e
> "imobiliaria") e alimenta as três fatos por caminhos diferentes.

## Regras embutidas neste schema

- **A regra R1, sobre a dupla definição de venda:** a fato expõe as duas colunas,
  `eh_venda` e `eh_venda_ou_distrato`, e é o Power BI que escolhe qual usar.
- **Distrato:** enriquece a fato por reserva, com uma deduplicação defensiva (no
  máximo 1 distrato por reserva, sempre o mais recente). A visão de "vendas no
  mês da venda" e "distratos no mês do distrato" (como o legado fazia) é
  reconstruída dentro do Power BI.
- **A data de referência do distrato** usa
  `coalesce(situacao_data, data_sincronizacao, data_cad)`, nessa ordem de
  prioridade: 7 distratos têm `situacao_data` nula, e ficariam perdidos em um
  bucket vazio se essa regra de fallback não existisse.

## Validação (carga local, 14 de julho de 2026)

Nessa carga, os volumes encontrados foram: 4.789 linhas em `fato_reservas`, 19 em
`dim_empreendimento`, 5.773 em `dim_unidade`, 1.087 em `dim_corretor`, 1.461 em
`dim_calendario`, 58.494 em `fato_leads` e 6.485 em `fato_precadastros`.
