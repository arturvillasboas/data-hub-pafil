# Modelo semântico da camada gold: o núcleo de vendas

Este documento descreve o design do star schema (o modelo de estrela, com uma tabela
fato central cercada de dimensões) usado no projeto. O modelo já está implementado
na camada gold, dentro de `sql/gold/gold.sql`, que define `fato_reservas` e as
dimensões relacionadas como views SQL. O Power BI consome essas views diretamente do
PostgreSQL, sem precisar refazer o cruzamento de dados por conta própria. Este
documento funciona como referência conceitual: o grão de cada tabela, as dimensões
disponíveis, os relacionamentos esperados entre elas e as medidas DAX de partida.

```
PostgreSQL gold  ──►  Power BI Desktop  ──►  relatório
 fato_reservas e        relacionamentos e
 dimensões              medidas (DAX)
```

Para o passo a passo de conectar e montar o relatório, veja
[`powerbi/README.md`](powerbi/README.md).

---

## 1. O grão da tabela fato

As entidades `reservas`, `vendas` e `distratos` têm uma relação de um para um pela
coluna `idreserva`: são estados diferentes da mesma reserva ao longo do tempo, não
tabelas independentes entre si. Por isso, o modelo usa uma única tabela fato.

### `fato_reservas` (o grão é uma linha por reserva)

A view `gold.fato_reservas` já entrega essa tabela pronta, partindo da entidade
`reservas` e enriquecida (por um `LEFT JOIN` pela chave `idreserva`, feito em SQL) com:

- de `distratos`: o motivo do distrato e a data em que ele aconteceu;
- de `vendas`: a área privativa, quando for útil ter essa informação na fato.

**As colunas que valem a pena manter visíveis no modelo do Power BI** são estas
(o restante, que soma cerca de 94 colunas na bronze, pode ficar oculto):

| Tipo | Colunas |
|---|---|
| Chaves (identificadores) | `idreserva` (chave primária), `idcliente`, `idcorretor`, `idimobiliaria`, `idempreendimento`, `idunidade`, `idlead` |
| Datas | `data_cad`, `data_venda`, `data_aprovacao`, `data_cancelamento`, `data_modificacao` |
| Status | `situacao`, `situacao_comercial`, `venda`, `aprovada` |
| Medidas | `valor_contrato`, `valor_liquido_com_juros`, `valor_proposta` |
| Vindas do distrato | `motivo_distrato`, `data_distrato` |

> Identificadores pessoais como `documento_cliente` e `cep_cliente` não entram na
> fato. Eles ou ficam reservados para uma eventual `dim_cliente`, ou são descartados
> do modelo por serem dados pessoais (PII).

**Duas colunas calculadas já vêm prontas na fato**, e ajudam bastante na hora de
montar medidas:

- `eh_venda`: verdadeiro quando o campo `venda` é "Sim" (ou quando `situacao` está
  entre os status que contam como venda);
- `eh_distrato`: verdadeiro quando existe um `motivo_distrato` preenchido (ou quando
  `situacao` é "Distrato").

> Uma alternativa para uma versão futura do modelo seria separar `fato_vendas` e
> `fato_distratos` em duas tabelas distintas, compartilhando as mesmas dimensões.
> Isso só vale a pena se as análises de venda e de distrato divergirem muito uma da
> outra, o que não é o caso hoje.

---

## 2. As dimensões

| Dimensão | Origem na bronze | Chave | Atributos principais |
|---|---|---|---|
| `dim_unidade` | `unidades` | `idunidade` | número da unidade, bloco, etapa, tipologia, área privativa, tipo de empreendimento, andar, valor |
| `dim_empreendimento` | derivada de `unidades` (e também de `reservas`) | `idempreendimento` | nome do empreendimento, região, tipo de empreendimento |
| `dim_corretor` | `corretores` | `idcorretor` | nome, imobiliária, CRECI, se está ativo, categoria, nível |
| `dim_calendario` | gerada dentro do próprio Power BI (DAX ou Power Query) | `Data` | ano, mês, trimestre, nome do mês, ano-mês |
| `dim_perfil_cliente` | `pessoas` ⨝ `pessoas/profissional` (API CVDW); CSV manual só como fallback | `documento_chave` | profissão (macro/micro), renda, faixa etária, faixa de renda MCMV, PPE, grau de instrução, tempo de residência — ver DP-15 em `REGRAS_NEGOCIO.md` |

**`dim_empreendimento`** não tem um objeto próprio na API: ela é derivada da
entidade `unidades`, e já está pronta como `gold.dim_empreendimento`.

**Uma `dim_imobiliaria` separada não existe**, e essa é uma decisão deliberada: o
nome da imobiliária já vem embutido tanto em `fato_reservas[imobiliaria]` quanto em
`dim_corretor[imobiliaria]`, e uma dimensão dedicada só para isso não agregaria
valor à apresentação.

**Uma `dim_cliente` cheia (dump de `pessoas`) continua adiada de propósito.** Os
campos de cliente mais usados já vêm embutidos direto em `reservas` (nome do
cliente, cidade, sexo, idade, estado civil, renda). Trazer o objeto `pessoas`
inteiro, que tem cerca de 98 colunas e concentra muito dado pessoal sensível (CPF,
RG, CNH), não compensa neste momento do projeto.

**`dim_perfil_cliente` (DP-15, agosto de 2026) não é essa `dim_cliente` adiada — é
um recorte deliberadamente menor.** Traz profissão, renda, PPE e demografia,
curados por LGPD — não os ~98 campos crus de `pessoas`. Fonte primária: a própria
API CVDW, `bronze.pessoas` ⨝ `bronze.pessoas_profissional` (endpoint
`pessoas/profissional`, um objeto novo, fora dos 19 originalmente descobertos —
achado só depois de duas rodadas de investigação com amostra pequena terem
concluído erradamente que profissão/renda não existiam na API; ver o histórico
completo em `REGRAS_NEGOCIO.md` DP-15). Um CSV manual do CVCRM continua no repo
como *fallback* (`silver.perfil_cliente_precadastro`/`_reserva`), usado só para
`documento_chave` sem nenhuma linha em `bronze.pessoas`. Ficam de fora as colunas
mais sensíveis (dados bancários, finanças de PJ, documentos como RG/RNE/CNH/PIS,
filiação, e os dados de terceiros no bloco PPE) — ver o detalhe completo em
`REGRAS_NEGOCIO.md` DP-15. Grão: 1 linha por `documento_chave` (CPF hasheado via
`silver.chave_documento()`, nunca exposto em claro). Relaciona com `fato_reservas`
e `fato_precadastros` pela mesma chave (ambas ganharam a coluna `documento_chave`
para isso). `profissao_micro`/
`profissao_macro` vêm de um join vivo com `dpara_profissoes` (DP-07), não de valor
congelado importado do CSV legado.

**`dim_estrutura`, `dim_metas_empreendimentos` e `dim_viabilidade`** entraram no
modelo na task 6.4, em agosto de 2026. Juntas, cobrem a matriz de preço e estoque
por unidade, as metas e o forecast mensal, e os parâmetros de margem por
empreendimento. Nenhuma dessas três vem da API do CVDW: são planejamento e input
manual da gestão (veja a regra R5 em `REGRAS_NEGOCIO.md`). Chegam ao banco por seed,
através dos comandos `popular_seeds.py --estrutura-precos`,
`--metas-empreendimentos` e `--viabilidade`, a partir das planilhas
`base_precos.xlsm`, `Meta.xlsx` e `d_para empreendimentos.xlsx`. Elas se relacionam
com `dim_empreendimento` pelo par de colunas `codigo_cv` e
`codigo_interno_empreendimento`. As medidas correspondentes estão em
`powerbi/MEDIDAS_ESTOQUE_PRECO.dax` (Estoque, VSO, Margem) e em
`powerbi/MEDIDAS_GOLD.dax` (Meta, Forecast, % de Atingimento). O detalhe de colunas,
e um achado interessante sobre a normalização do campo `bloco` em produtos de torre
única, estão descritos na seção 3 e na regra R17 de `REGRAS_NEGOCIO.md`.

**`dim_ivv_padrao` e `d_empreendimento_legado`** entraram em agosto de 2026 e trazem
a curva padrão de IVV (velocidade de vendas), organizada por empreendimento e por
mês desde o lançamento, usando o mesmo arquivo e a mesma lógica das dimensões
anteriores (`d_para empreendimentos.xlsx`). As colunas `meses_desde_lancamento` e
`eh_mes_atual` são calculadas ao vivo, dentro da própria view SQL, não em DAX. Para
pegar o ponto da curva referente a hoje, filtre por `eh_mes_atual = TRUE`. O
realizado (VSO) pode ser comparado com o padrão através da medida
`[Diferença IVV x Padrão]`.

**Para criar a `dim_calendario`**, cole o código abaixo no Power BI Desktop, como
uma Nova Tabela:
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
Depois de criada, marque-a como Tabela de Datas, no menu Ferramentas de Tabela,
opção "Marcar como tabela de datas".

---

## 3. Os relacionamentos (em formato de estrela)

Todos os relacionamentos vão de uma dimensão (lado "um") para a fato (lado
"muitos"), numa única direção:

```
dim_calendario[Date] ──1:*── fato_reservas[data_venda]   (ativo)
dim_unidade[idunidade] ──1:*── fato_reservas[idunidade]
dim_corretor[idcorretor] ──1:*── fato_reservas[idcorretor]
dim_empreendimento[idempreendimento] ──1:*── fato_reservas[idempreendimento]
dim_perfil_cliente[documento_chave] ──1:*── fato_reservas[documento_chave]      (opcional)
```

- `dim_perfil_cliente` também relaciona com `fato_precadastros` pela mesma
  `documento_chave` (não desenhado no diagrama acima por já ter cliente
  fato_reservas/fato_precadastros ligados entre si por `id_precadastro`; evite
  relacionar `dim_perfil_cliente` às duas fatos ao mesmo tempo, para não formar um
  losango de filtro — prefira relacionar só à fato que a página realmente usa).

- A fato tem várias colunas de data (`data_cad`, `data_venda`, `data_cancelamento`,
  entre outras). A recomendação é deixar apenas um relacionamento ativo com
  `dim_calendario` (o sugerido é `data_venda`) e manter os demais inativos,
  ativando-os sob demanda dentro de uma medida específica, com a função
  `USERELATIONSHIP`.
- `dim_empreendimento` pode se relacionar com `dim_unidade` (formando uma estrutura
  em floco de neve, ou "snowflake") ou diretamente com a fato. O recomendado é
  começar ligando direto à fato, por ser mais simples de manter.
- Evite relacionamentos bidirecionais: eles tendem a gerar ambiguidade de filtro
  difícil de depurar depois.

---

## 4. Medidas DAX de partida

Crie uma tabela dedicada só para medidas (ou, se preferir, coloque-as dentro de
`fato_reservas`):

```dax
Reservas = COUNTROWS ( fato_reservas )

Reservas Vendidas =
CALCULATE ( [Reservas], fato_reservas[eh_venda] = TRUE )

VGV =  -- Valor Geral de Vendas (o valor contratado das vendas)
CALCULATE ( SUM ( fato_reservas[valor_contrato] ), fato_reservas[eh_venda] = TRUE )

Ticket Médio = DIVIDE ( [VGV], [Reservas Vendidas] )

Distratos = CALCULATE ( [Reservas], fato_reservas[eh_distrato] = TRUE )

Valor Distratado =
CALCULATE ( SUM ( fato_reservas[valor_contrato] ), fato_reservas[eh_distrato] = TRUE )

Taxa de Distrato = DIVIDE ( [Distratos], [Reservas Vendidas] )

VGV Líquido = [VGV] - [Valor Distratado]
```

Com a `dim_calendario` já relacionada, dá para evoluir essas medidas para o
chamado "time intelligence" (VGV acumulado no ano, VGV mês a mês, variação
percentual mês contra mês), usando funções como `TOTALYTD` e
`SAMEPERIODLASTYEAR`. Quando a análise precisar ser por data de cadastro em vez de
data de venda, use `USERELATIONSHIP(dim_calendario[Date], fato_reservas[data_cad])`
para ativar o relacionamento alternativo só naquela medida.

---

## 5. Boas práticas de organização do modelo

- Esconda as colunas técnicas e as chaves estrangeiras, deixando a fato visível
  apenas com as medidas que interessam ao usuário final.
- Renomeie tabelas e colunas para nomes de negócio (por exemplo, `valor_contrato`
  vira "Valor do contrato").
- Defina o formato de cada medida (moeda, porcentagem, data) e a categoria de dados,
  quando fizer sentido.
- Publique o modelo como um modelo semântico compartilhado no workspace Pro. Assim,
  vários relatórios podem reaproveitar o mesmo star schema sem precisar recriar nada
  do zero, o que cobre boa parte do motivo que levaria a contratar o Premium, sem
  custo adicional.

---

## Ordem sugerida para montar o relatório no Power BI Desktop

1. Conecte às views da camada gold (`fato_reservas` e as dimensões), como descrito
   em `powerbi/README.md`. O cruzamento entre reserva, venda e distrato já vem
   pronto do banco, então não é preciso refazer merges em Power Query.
2. Confira as colunas de `fato_reservas` e esconda as que não interessam ao
   relatório.
3. Traga as dimensões: `dim_unidade`, `dim_empreendimento`, `dim_corretor` e,
   quando aplicável, `dim_estrutura`, `dim_metas_empreendimentos`,
   `dim_viabilidade` e `dim_ivv_padrao`.
4. Configure os relacionamentos, seguindo a seção 3 acima.
5. Crie a `dim_calendario` e marque-a como tabela de datas.
6. Escreva as medidas DAX, começando pelo conjunto de partida da seção 4.
7. Esconda as colunas técnicas, formate as medidas e publique o modelo.
