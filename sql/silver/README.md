# Camada Silver

Conformação a partir da **bronze**. Diferente do BI legado (que limpava CSV manual no
Power Query), a bronze já chega **keyed e tipada** da API — então a silver foca em
**conformar nomes**, **tipagem forte** e **flags de regra de negócio**, não em consertar lixo.

Mapeada a partir de [`REGRAS_NEGOCIO.md`](../../REGRAS_NEGOCIO.md) (IDs `ING-*`, `DP-*`, `KPI-*`, `R*`).

## O que tem aqui

| Arquivo | Conteúdo |
|---|---|
| [`silver.sql`](silver.sql) | Schema `silver`, funções de tipagem tolerante e **6 views** de conformação |
| [`seeds.sql`](seeds.sql) | Tabelas **de-para** (DP-01..12) — estrutura + proveniência (dados carregados à parte) |

Aplicar: `python aplicar_silver.py` (na raiz do projeto). Idempotente; valida contando linhas de cada view.

## Views (declarativas sobre a bronze)

| View | Grão | Destaques |
|---|---|---|
| `silver.reservas` | 1 reserva | flags `eh_venda` / `eh_venda_ou_distrato` / `eh_distrato` (expõem **R1**); datas text→timestamptz; chaves de tempo (`ano_mes_venda`) |
| `silver.vendas` | 1 venda (/vendas) | caminho alternativo a reservas-vendidas; `preco_m2` |
| `silver.distratos` | 1 distrato | fonte única (substitui as 3 do legado — **R2**) |
| `silver.unidades` | 1 unidade | `preco_m2`, `eh_vendida` (base de estoque/VSO) |
| `silver.corretores` | 1 corretor | `creci`→TEXT |
| `silver.imobiliarias` | 1 imobiliária | `cnpj`→TEXT (**R8**) |

> **Por que views, não tabelas:** declarativo, reversível, sempre fresco, sem passo de refresh.
> Materializar (`TABLE`/`MATERIALIZED VIEW`) só quando a performance exigir.

## Validação (carga local, 28/jun/2026)

Contra a bronze validada localmente (porta 5433):

- `silver.reservas` 4.756 · `vendas` 2.680 · `distratos` 741 · `unidades` 5.773 · `corretores` 1.087 · `imobiliarias` 633.
- **Consistência cruzada:** `/vendas` (2.680) = reservas `situacao='Vendida'` (2.680); `/distratos` (741) = reservas `situacao='Distrato'` (741). ✔ (resolve R7).
- **KPIs prontos p/ reconciliação:** VGV Bruto R$ 715.397.140,32 · VGV Distrato R$ 173.196.940,07 · **VGV Líquido R$ 542.200.200,25**.

## Decisões / regras aplicadas

- **ING-01..03** (lixo de CSV, extrair Reserva entre aspas): **não portadas** — eram defeitos do export
  manual; a API entrega dados estruturados. Filtro defensivo só se aparecer sujeira.
- **ING-04** ("Ajuste Castro"): vira seed `silver.dpara_responsavel_imobiliaria` (não hard-code).
  Aplicação na view fica para a Gold, quando houver coluna de responsável.
- **R1** (duas definições de "venda"): ambas expostas como colunas. A autoritativa se decide na reconciliação.
- **Tipagem forte:** `creci`/`cnpj` (identificadores) → TEXT; datas-texto → `silver.tentar_timestamptz` (NULL em vez de quebrar).

## Próximos passos

1. **Popular os seeds** `dpara_*` (extrair das planilhas SharePoint / decodificar JSON do `_bi_ref`).
2. **Gold:** star schema (ver [`MODELO_SEMANTICO.md`](../../MODELO_SEMANTICO.md)) — `fato_reservas` = reservas
   ⨝ distratos, dimensões a partir de `unidades`/`corretores`/`imobiliarias` + `dim_calendario`.
3. **Reconciliação:** comparar os KPIs ⭐ (VGV Bruto/Líquido, QTD, Taxa de Distrato) mês × empreendimento
   contra os PBIX legados.
