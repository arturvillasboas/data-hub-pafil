# Reconciliação de Distratos — 2026-05

> ⚠️ Contém valores reais de VGV/distratos da empresa. Repositório é **privado** —
> não redistribuir fora dele (ver `SKILL.md` seção 7).

Pipeline nova (API → silver.distratos) vs. CSV legado (rel_distratos, fechamento mensal).

## Totais

| Métrica | Legado (CSV) | Pipeline (API) | Δ |
|---|--:|--:|--:|
| Qtd distratos | 54 | 54 | +0 |
| VGV distratos | R$ 12.888.599,11 | R$ 12.888.599,11 | R$ 0,00 |

## Achados

✅ **Bate número-a-número** — mesmas reservas, mesmos valores.

> Divergência é **achado**, não falha: o CSV é um snapshot do fechamento; a pipeline é estado atual (distratos novos entram). Reservas só-no-legado merecem investigação.
