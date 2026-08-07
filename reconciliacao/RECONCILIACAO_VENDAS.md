# Reconciliação de Vendas — pipeline vs. Vendas Consolidadas (legado)

> ⚠️ Contém valores reais de VGV/vendas da empresa. Repositório é **privado** —
> não redistribuir fora dele (ver `SKILL.md` seção 7).

Pipeline nova (API → `silver.reservas`) vs. planilha de fechamento manual `Vendas Consolidadas.xlsm` (depois consumida pelo PBI). Chave: Proposta = idreserva.

> ⚠️ **Bronze local é parcial** — o run completo vai para a VPS. Por isso a comparação honesta é **por proposta no overlap**, não o total geral.

## Overlap por proposta

| | Propostas |
|---|--:|
| Legado (planilha) | 3194 |
| Pipeline (reservas) | 4756 |
| **Em ambos** | **1892** |
| Só no legado (ausente no bronze local) | 1302 |

## (a) VGV no overlap — `valor_contrato` vs. `VGV (Praticado)`

| Métrica | Legado | Pipeline | Δ |
|---|--:|--:|--:|
| VGV (1892 propostas) | R$ 482.685.046,75 | R$ 482.413.195,41 | R$ -271.851,34 |
| Δ % | | | -0.06% |
| Propostas com VGV **idêntico** (≤ R$ 0,01) | | | **1869 / 1892** |

<details><summary>23 proposta(s) com VGV divergente</summary>

| Proposta | Legado | Pipeline | Δ |
|--:|--:|--:|--:|
| 337 | R$ 189.036,00 | R$ 0,00 | R$ -189.036,00 |
| 5410 | R$ 297.803,94 | R$ 323.594,04 | R$ 25.790,10 |
| 4800 | R$ 328.333,33 | R$ 350.183,14 | R$ 21.849,81 |
| 5258 | R$ 420.045,00 | R$ 399.444,94 | R$ -20.600,06 |
| 6155 | R$ 270.000,00 | R$ 255.600,00 | R$ -14.400,00 |
| 6719 | R$ 221.783,76 | R$ 235.283,76 | R$ 13.500,00 |
| 4956 | R$ 224.279,00 | R$ 211.059,05 | R$ -13.219,95 |
| 4946 | R$ 224.994,25 | R$ 212.846,45 | R$ -12.147,80 |
| 5332 | R$ 254.936,61 | R$ 243.266,20 | R$ -11.670,41 |
| 5242 | R$ 219.900,00 | R$ 209.156,45 | R$ -10.743,55 |
| 5315 | R$ 225.663,33 | R$ 216.113,09 | R$ -9.550,24 |
| 5030 | R$ 219.900,20 | R$ 210.350,07 | R$ -9.550,13 |
| 5096 | R$ 224.414,00 | R$ 214.863,88 | R$ -9.550,12 |
| 4911 | R$ 223.900,00 | R$ 214.350,17 | R$ -9.549,83 |
| 5314 | R$ 232.350,50 | R$ 222.850,48 | R$ -9.500,02 |
| 5117 | R$ 261.353,00 | R$ 251.853,05 | R$ -9.499,95 |
| 5263 | R$ 232.350,47 | R$ 222.850,53 | R$ -9.499,94 |
| 3370 | R$ 225.836,00 | R$ 235.335,80 | R$ 9.499,80 |
| 5501 | R$ 232.350,41 | R$ 224.207,47 | R$ -8.142,94 |
| 4916 | R$ 194.428,28 | R$ 187.378,16 | R$ -7.050,12 |
| 4174 | R$ 288.859,00 | R$ 295.359,01 | R$ 6.500,01 |
| 3946 | R$ 380.000,00 | R$ 386.199,98 | R$ 6.199,98 |
| 5137 | R$ 442.500,00 | R$ 441.020,02 | R$ -1.479,98 |
</details>

## (b) Drift de status — Status (legado) × situacao (pipeline)

🔴 **420 propostas que o legado conta como venda viva (Vendida/Validada/Envio Mega) já estão DISTRATO no CRM** — a planilha manual está defasada (não pega distratos posteriores).

| Status (legado) | situacao (pipeline) | Qtd |
|---|---|--:|
| Vendida | Vendida | 989 |
| Vendida | Distrato | 379 |
| Validada | Vendida | 345 |
| Distrato | Distrato | 48 |
| Validada | Distrato | 34 |
| Envio Mega | Vendida | 32 |
| Venda distratada | Distrato | 28 |
| Validação Comercial | Vendida | 8 |
| Envio Mega | Distrato | 7 |
| Contrato Enviado | Vendida | 6 |
| Validação Comercial | Distrato | 5 |
| Contrato Enviado | Distrato | 5 |
| Contrato Assinado Cliente | Vendida | 2 |
| Vendida | Cancelada | 1 |
| venda distratada | Distrato | 1 |
| Ajustes Contrato | Distrato | 1 |
| Geração de Contrato | Distrato | 1 |

### Leitura
- `valor_contrato` da API reproduz o **VGV (Praticado)** do fechamento manual ao centavo em 1869/1892 propostas — a medida está correta.
- Status como **Validada / Venda distratada / Repassada / Envio Mega** são reclassificação **manual** sem correspondência na API → viram regra de Silver/Gold (de-para de status) ou input operacional, não vêm do CRM.
- As **vendas-defasadas** (Vendida no legado, Distrato no CRM) são o ganho da pipeline: número sempre atual vs. planilha que envelhece entre fechamentos.
