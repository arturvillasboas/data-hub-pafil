# Modelo semântico (camada GOLD) — núcleo de vendas

Design do **star schema**. O modelo já está **implementado na camada gold**
(`sql/gold/gold.sql` — `fato_reservas` + dimensões), e o Power BI o consome direto do
PostgreSQL. Este doc é a referência conceitual (grão, dimensões, relacionamentos, DAX).

```
PostgreSQL gold  ──►  Power BI Desktop  ──►  relatório
 fato_reservas +       relacionamentos +
 dimensões             medidas (DAX)
```

Para conectar e montar o relatório, ver [powerbi/README.md](powerbi/README.md).

---

## 1. Grão e a fato

`reservas`, `vendas` e `distratos` são **1:1 por `idreserva`** — são estados da
**mesma** reserva, não tabelas independentes. Então, para a v1, **uma fato só**:

### `fato_reservas` (grão = 1 reserva)

Base: entidade `reservas`. Enriquecer (LEFT JOIN por `idreserva`) com:
- de `distratos`: `motivo_distrato`, `data_sincronizacao` (data do distrato);
- de `vendas`: `area_privativa` (se quiser área na fato).

**Colunas a MANTER** (esconda/remova o resto — são ~94 na bronze):

| Tipo | Colunas |
|---|---|
| Chaves (FK) | `idreserva` (PK), `idcliente`, `idcorretor`, `idimobiliaria`, `idempreendimento`, `idunidade`, `idlead` |
| Datas | `data_cad`, `data_venda`, `data_aprovacao`, `data_cancelamento`, `data_modificacao` |
| Status | `situacao`, `situacao_comercial`, `venda`, `aprovada` |
| Medidas | `valor_contrato`, `valor_liquido_com_juros`, `valor_proposta` |
| Distrato (do merge) | `motivo_distrato`, `data_distrato` |

> Identificadores como `documento_cliente`, `cep_cliente` etc. **não** vão pra
> fato — ou ficam numa `dim_cliente`, ou são descartados do modelo (PII).

**Colunas calculadas úteis na fato** (Power Query ou DAX):
- `eh_venda` = `venda = "Sim"` (ou `situacao` em {"Vendida", ...});
- `eh_distrato` = `motivo_distrato <> null` (ou `situacao` = "Distrato").

> Alternativa (v2): `fato_vendas` e `fato_distratos` separadas, compartilhando as
> mesmas dimensões. Só vale se as análises de venda e distrato divergirem muito.

---

## 2. Dimensões

| Dimensão | Origem (bronze) | Chave | Atributos principais |
|---|---|---|---|
| `dim_unidade` | `unidades` | `idunidade` | `nome` (nº unidade), `bloco`, `etapa`, `tipologia`, `area_privativa`, `tipo_empreendimento`, `andar`, `valor` |
| `dim_empreendimento` | derivada de `unidades` (ou `reservas`) | `idempreendimento` | `nome_empreendimento`, `regiao`, `tipo_empreendimento` |
| `dim_corretor` | `corretores` | `idcorretor` | `nome`, `imobiliaria`, `creci`, `ativo`, `categoria`, `nivel` |
| `dim_calendario` | gerada (DAX/M) | `Data` | ano, mês, trimestre, nome do mês, ano-mês |

**`dim_empreendimento`** não tem objeto próprio na API: é derivada de `unidades`
(já pronta em `gold.dim_empreendimento`).

**`dim_imobiliaria`** — **não é mais uma dimensão própria**. O nome da imobiliária já vem
embutido em `fato_reservas[imobiliaria]` e em `dim_corretor[imobiliaria]`; uma dim dedicada
não agregava valor para a apresentação.

**`dim_cliente`** — **adiada de propósito**. Os campos de cliente já vêm
embutidos em `reservas` (`cliente`, `cidade`, `sexo`, `idade`, `estado_civil`,
`renda`). Puxar o objeto `pessoas` inteiro (≈98 colunas, muito PII: CPF, RG, CNH)
não compensa agora.

**`dim_calendario`** (cole no Desktop, *Nova tabela*):
```dax
dim_calendario =
VAR _min = MIN ( fato_reservas[data_cad] )
VAR _max = MAX ( fato_reservas[data_venda] )
RETURN
ADDCOLUMNS (
    CALENDAR ( DATE ( YEAR(_min), 1, 1 ), DATE ( YEAR(_max), 12, 31 ) ),
    "Ano", YEAR ( [Date] ),
    "Mês nº", MONTH ( [Date] ),
    "Mês", FORMAT ( [Date], "mmm" ),
    "Ano-Mês", FORMAT ( [Date], "yyyy-mm" ),
    "Trimestre", "T" & FORMAT ( [Date], "Q" )
)
```
Marque-a como **Tabela de Datas** (*Ferramentas de tabela → Marcar como tabela de datas*).

---

## 3. Relacionamentos (star)

Todos **1 (dimensão) → muitos (fato)**, direção **única**:

```
dim_calendario[Date] ──1:*── fato_reservas[data_venda]   (ativo)
dim_unidade[idunidade] ──1:*── fato_reservas[idunidade]
dim_corretor[idcorretor] ──1:*── fato_reservas[idcorretor]
dim_empreendimento[idempreendimento] ──1:*── fato_reservas[idempreendimento]
```

- A fato tem **várias datas** (`data_cad`, `data_venda`, `data_cancelamento`...).
  Faça **1 relacionamento ativo** (sugiro `data_venda`) e os demais **inativos**,
  ativando sob demanda na medida com `USERELATIONSHIP`.
- `dim_empreendimento` pode se ligar a `dim_unidade` (snowflake) **ou** direto à
  fato. Comece **direto à fato** (mais simples).
- Evite relacionamentos bidirecionais.

---

## 4. Medidas DAX (conjunto inicial)

Crie uma tabela de medidas (ou ponha em `fato_reservas`):

```dax
Reservas = COUNTROWS ( fato_reservas )

Reservas Vendidas =
CALCULATE ( [Reservas], fato_reservas[eh_venda] = TRUE )

VGV =  -- Valor Geral de Vendas (contratado das vendas)
CALCULATE ( SUM ( fato_reservas[valor_contrato] ), fato_reservas[eh_venda] = TRUE )

Ticket Médio = DIVIDE ( [VGV], [Reservas Vendidas] )

Distratos = CALCULATE ( [Reservas], fato_reservas[eh_distrato] = TRUE )

Valor Distratado =
CALCULATE ( SUM ( fato_reservas[valor_contrato] ), fato_reservas[eh_distrato] = TRUE )

Taxa de Distrato = DIVIDE ( [Distratos], [Reservas Vendidas] )

VGV Líquido = [VGV] - [Valor Distratado]
```

Com a `dim_calendario` ligada, dá pra evoluir para *time intelligence*
(VGV YTD, VGV mês a mês, variação % MoM) usando `TOTALYTD`, `SAMEPERIODLASTYEAR`,
etc. — e usar `USERELATIONSHIP(dim_calendario[Date], fato_reservas[data_cad])`
quando a análise for por data de cadastro em vez de data de venda.

---

## 5. Higiene do modelo

- **Esconda** colunas técnicas e FKs (a fato fica só com medidas visíveis).
- Renomeie tabelas/colunas para nomes de negócio (ex.: `valor_contrato` → "Valor do contrato").
- Defina **formato** (R$, %, datas) e **categoria de dados** quando fizer sentido.
- Publique como **modelo semântico compartilhado** no workspace Pro — assim vários
  relatórios reusam o mesmo star sem recriar nada (cobre a "reutilização" que
  seria o motivo de Premium, **de graça**).

---

## Ordem sugerida de execução

1. Conectar nas 6 entidades.
2. Montar `fato_reservas` (trim + merges).
3. Criar as 5 dimensões.
4. Relacionamentos.
5. `dim_calendario` + marcar como tabela de datas.
6. Medidas.
7. Esconder técnicos + formatar + publicar.
