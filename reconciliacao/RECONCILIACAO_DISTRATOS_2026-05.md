# Reconciliação de distratos: maio de 2026

**Atenção:** este documento contém valores reais de VGV e distratos da empresa. O
repositório é privado; não redistribua esse conteúdo fora dele (veja a seção 7 de
`SKILL.md`).

Esta comparação coloca lado a lado a pipeline nova (dados vindos da API, através
de `silver.distratos`) e o CSV legado (`rel_distratos`, o fechamento mensal
tradicional).

## Totais

| Métrica | Legado (CSV) | Pipeline (API) | Diferença |
|---|--:|--:|--:|
| Quantidade de distratos | 54 | 54 | +0 |
| VGV dos distratos | R$ 12.888.599,11 | R$ 12.888.599,11 | R$ 0,00 |

## Achados

Concluído: os números batem exatamente, reserva por reserva, valor por valor.

Vale registrar uma ressalva: uma eventual divergência aqui seria um achado, não
necessariamente uma falha. O CSV é um retrato do fechamento em um instante fixo,
enquanto a pipeline reflete o estado atual dos dados, então distratos novos podem
entrar na pipeline depois do fechamento. Reservas que aparecessem só no legado
mereceriam investigação, mas isso não aconteceu neste mês.
