# Power BI sobre a camada gold: passo a passo de importação

**Atenção:** o arquivo `de_para_classificacao.xlsx`, guardado nesta mesma pasta,
contém dado real (nomes e classificações de proposta). O repositório é privado;
não redistribua esse arquivo fora dele.

Este é o guia para montar o `.pbix` da apresentação mensal, consumindo o star
schema da camada gold, substituindo a cadeia manual de CVCRM até Vendas
Consolidadas até PBIX. A gold já entrega os fatos e as dimensões reconciliados (o
VGV bate com os slides atuais); rankings, mídia e a esteira são montados
diretamente no Power BI.

---

## 0. Pré-requisitos

1. **O banco precisa estar de pé:**
   `& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start`
2. **O warehouse precisa estar aplicado:** `python aplicar_tudo.py` (que roda
   silver, gold e seeds em sequência). Para ter os nomes conformados e o House
   completos, rode também `python aplicar_tudo.py --xlsm "<Vendas Consolidadas.xlsm>"`
   e `python popular_seeds.py --gerentes "<depara_gerentes.xlsx>"`.
3. **O provedor Npgsql:** na primeira conexão com o PostgreSQL, o Power BI
   Desktop vai pedir para instalar o Npgsql. Aceite a instalação (ou, se preferir,
   baixe direto do GitHub do Npgsql e reinicie o Desktop depois).

---

## 1. Conectar ao banco

**Opção A, mais rápida:** dê um duplo clique em `conectar_gold.pbids`. Isso já
abre o Power BI Desktop conectado ao banco.

**Opção B, manual:** vá em Página Inicial → Obter dados → Banco de dados → Banco
de dados PostgreSQL:
- **Servidor:** `localhost:5433`
- **Banco de dados:** `pafil_dw`
- **Modo:** Importar
- Nas credenciais, na aba Banco de dados: usuário `postgres`, senha
  `PafilLocalDev2026`.
- Se o Power BI reclamar de SSL ou criptografia, lembre que o banco local roda
  sem SSL: desmarque a opção "Criptografar conexão" (ou responda que quer
  conectar sem criptografia quando for perguntado).

---

## 2. Selecionar as tabelas, na tela do Navegador

Marque, dentro do schema `gold`:

| Objeto | Para que serve |
|---|---|
| `fato_reservas` | a tabela fato, base de todas as análises de venda |
| `dim_calendario` | o eixo de tempo, usado em análises por mês e no acumulado do ano (YTD) |
| `dim_empreendimento` | usada em Vendas por Empreendimento |
| `dim_corretor` | traz os atributos de cada corretor |
| `fato_leads` | o funil de marketing, cruzando leads com mídia e origem |
| `fato_precadastros` | o funil de crédito, com os pré-cadastros |

> A gold entrega apenas fatos e dimensões. Rankings, Vendas por Mídia, a esteira e
> os demais agregados são montados diretamente no Power BI, como medidas e
> visuais sobre `fato_reservas`, usando a classificação oficial (origem, canal,
> mídia, House ou Parcerias) que vem da Vendas Consolidadas, mesclada por
> proposta. Use "Transformar Dados" só se quiser revisar algo antes; caso
> contrário, clique direto em Carregar.

---

## 3. Configurar os relacionamentos (modo Modelo)

As dimensões se ligam à fato sempre na direção de um para muitos:

```
dim_calendario[data]              1─* fato_reservas[data_venda]      (ativo)
dim_empreendimento[id_empreendimento] 1─* fato_reservas[id_empreendimento]
dim_corretor[id_corretor]         1─* fato_reservas[id_corretor]
```

- Marque `dim_calendario` como Tabela de Datas, usando a coluna `data`: vá em
  Ferramentas de Tabela → Marcar como tabela de datas.
- `fato_leads` e `fato_precadastros` se ligam a `dim_calendario` pela coluna
  `data_cad` (e, quando fizer sentido, também a `dim_empreendimento` e
  `dim_corretor`), para alimentar os funis de marketing e de crédito.
- Opcionalmente, crie um relacionamento inativo entre `dim_calendario[data]` e
  `fato_reservas[data_distrato]`, para analisar distratos pelo mês em que o
  distrato aconteceu (ativando esse relacionamento com `USERELATIONSHIP` dentro
  da medida específica).

---

## 4. Criar as medidas

Cole o conteúdo de `MEDIDAS_GOLD.dax` em uma tabela de medidas. Ele já traz VGV
Bruto, VGV Distrato, VGV Líquido, QTD, Ticket Médio, Taxa de Distrato, YTD e
variação mês a mês (MoM), todos mapeados aos KPIs correspondentes em
`REGRAS_NEGOCIO.md`.

---

## 5. Montar os visuais da apresentação

| Slide | Como montar |
|---|---|
| Vendas por Mês | Gráfico de colunas: eixo `dim_calendario[mes_abrev]`, valor `[VGV Bruto]`, com filtro de Ano |
| Vendas Acumuladas (YTD) | Gráfico de linha: eixo `dim_calendario[data]`, valor `[VGV Bruto YTD]` |
| Vendas por Empreendimento | Gráfico de barras: eixo `fato_reservas[empreendimento_conformado]`, valor `[VGV Bruto]` |
| Vendas por Mídia | Gráfico de barras sobre a fato: eixo `fato_reservas[midia]`, valor `[VGV Bruto]`, com slicer de `ano_mes_venda` |
| Ranking de Corretores | Tabela sobre a fato: eixo `fato_reservas[corretor]`, valores `[VGV Bruto]` e `[QTD]`, filtrando House RPO pela classificação oficial, ordenado por VGV decrescente |
| Ranking de Gerentes | Tabela sobre a fato: eixo `fato_reservas[gerente_responsavel]`, valor `[VGV Bruto]`, filtrando House pela classificação oficial, ordenado por VGV decrescente |
| House RPO (slides 6 a 11) | Os mesmos visuais construídos sobre a fato, com o filtro de House/RPO vindo da classificação oficial |

> A regra de House/Parcerias, assim como a de origem, canal e mídia, vem sempre
> da classificação oficial (a Vendas Consolidadas), mesclada por proposta dentro
> do Power BI, nunca de uma coluna direta da fato. Alguns campos extras já vêm
> prontos na fato: `cf_tipo_venda`, `cf_modalidade_financiamento`,
> `cf_motivo_distrato` e `gerente_responsavel`. A exclusão de corretores de
> coordenação (que antes ficava na tabela `ranking_corretores`) agora vira um
> filtro no próprio visual, aplicado através da seed
> `silver.dpara_corretor_fora_ranking`.

### A página "Esteira de vendas" (o funil de reservas)

Monte esse funil diretamente sobre `fato_reservas`, usando as colunas
`situacao_tratada` e `situacao_ordem`, que já vêm prontas na fato:

1. **Ordene a situação corretamente:** selecione a coluna `situacao_tratada`, vá
   em Ferramentas de Coluna → Classificar por coluna → escolha
   `situacao_ordem`. Isso garante que o funil apareça na ordem certa do
   processo, e não em ordem alfabética.
2. **Funil de etapas** (usando o visual Funil, ou um gráfico de colunas):
   categoria `situacao_tratada`, valor `Contagem de id_reserva` (ou, se
   preferir, `[VGV Bruto]`).
3. **Tabela de esteira por gerente** (usando o visual Matriz): linhas
   `gerente_responsavel`, colunas `situacao_tratada`, valores como contagem de
   reservas. É a versão nova da "esteira por gerente" que já existia no BI
   legado.
4. **Segmentações (slicers):** `regional`, `empreendimento_conformado` e
   `ano_mes_venda` (o House/Parcerias e o share continuam vindo da classificação
   oficial).
5. **Para ver só o pipeline em aberto**, filtre por `situacao_ordem <= 13`
   (excluindo Vendida, Cancelada e Distrato). Uma observação: a situação
   "Vencida" (código 12) representa uma reserva expirada; use
   `situacao_ordem <= 11` se quiser enxergar só o funil realmente ativo.

### A página "Pré Cadastro" (o funil de crédito)

É a reimplementação da página "Pré Cadastro" do BI Matriz legado, que tinha 35
visuais, todos decifrados a partir de `_bi_ref/matriz_report.json` e
`matriz_model.bim`. A fonte é `fato_precadastros` (esse schema foi montado em 24
de julho de 2026; veja `MEDIDAS_PRECADASTROS.dax` para as medidas e as notas
sobre a regra DP-05, a esteira e a equipe).

**Antes de montar os visuais**, clique em Atualizar dentro do Desktop: a
`fato_precadastros` ganhou colunas novas (`etapa_bi`, `etapa_bi_detalhada`,
`situacao_anterior`, `situacao_reserva`, `id_reserva`, `eh_venda_reserva`,
`eh_distrato_reserva`, `aprovacao_credito`, `encaminhado_cca`), e o Desktop só
popula essas colunas quando reprocessa o mashup pelo botão Atualizar, não em um
refresh comum via API ou TOM. Depois disso, cole as medidas de
`MEDIDAS_PRECADASTROS.dax` na tabela `Medidas` (dentro da pasta "Pré-Cadastro")
antes de começar a montar os visuais.

| Visual (nome usado no legado) | Tipo | Como montar aqui |
|---|---|---|
| Pastas Imobiliária | Barras | eixo `fato_precadastros[imobiliaria]`, valor `[Qtd Pastas]` |
| Pastas House/Parcerias | Rosca | eixo `depara_corretor_headcount[house_parcerias]`, valor `[Qtd Pastas]` |
| Cadastro por Etapa | Colunas | eixo `fato_precadastros[etapa_bi_detalhada]` (ordenar por texto, já vem numerado de "0." a "6."), valor `[Qtd Pastas]` |
| Pastas Gerentes House | Barras | eixo `depara_corretor_headcount[supervisor]`, valor `[Qtd Pastas]`, com filtro `house_parcerias="House"` |
| Pastas Corretor | Barras | eixo `fato_precadastros[corretor_tratado]`, valor `[Qtd Pastas]` |
| Cadastro por Produto | Colunas agrupadas | eixo `fato_precadastros[empreendimento_conformado]`, valor `[Qtd Pastas]` |
| Analítico dos Leads, Pastas e Reservas | Tabela | colunas `data_cad`, `corretor_tratado`, `id_lead`, `situacao`, `etapa_bi_detalhada`, `empreendimento_conformado`, `imobiliaria`, `id_reserva` |
| Cards do topo | HTML Content | medida `[KPIs Pré-Cadastro HTML]`, com 6 cards (Pastas, Avaliado, Tx Avaliação, Aprovado, Tx Aprovação, Vendas), no mesmo padrão visual do `KPIs Leads HTML` |
| Funil Pastas → Crédito Analisado → Crédito Aprovado → Venda | HTML Content | medida `[Funil Pré-Cadastro HTML]`, no mesmo padrão visual do `Funil Comercial HTML`, só que com 4 estágios em vez de 3 (não é um visual nativo do legado; foi adaptado a pedido do desenvolvedor) |
| Slicers | Segmentação | `fato_precadastros[imobiliaria]`, `fato_precadastros[empreendimento_conformado]`, `depara_corretor_headcount[supervisor]` (rotulado como Equipe Corretor), `depara_corretor_headcount[regional]`, e `dim_calendario` (Ano, Mês, Dia, marcando a hierarquia) |
| Aprovação de Crédito | Rosca | eixo `fato_precadastros[aprovacao_credito]`, valor `[Qtd Pastas]` (ou `COUNTROWS`). Uma cobertura baixa é esperada aqui, cerca de 9%, já que só cobre as pastas efetivamente tocadas pelo time de crédito |
| Encaminhado ao CCA | Rosca | eixo `fato_precadastros[encaminhado_cca]`, valor `[Qtd Pastas]` (ou `COUNTROWS`). A mesma ressalva de cobertura baixa se aplica aqui |

> Os dois gráficos de rosca acima vêm de `silver.precadastros_credito_manual`
> (uma tabela nova, criada em 24 de julho de 2026), carregada a partir do export
> "Relatório Web" do CVCRM (`relatorios_precadastro.xlsx`), através do comando
> `popular_seeds.py --credito-manual`. A API do CVDW não traz essas duas colunas.

**Ficou de fora do escopo, por falta de uma fonte de dados** (as notas completas
estão no próprio arquivo `.dax`):
- "Pastas por Corretor (House)" comparando com o headcount mensal (uma linha
  comparando `Qtd Pastas` com o headcount daquele mês). Falta a série mensal do
  de-para de headcount (data, regional, headcount); esse de-para já está listado
  em `config/deparas.yml`, mas ainda não tem um loader nem uma tabela silver
  correspondente.

---

## 6. Validação: como confiar nos números

Antes de apresentar, confira os visuais contra os relatórios já reconciliados em
`reconciliacao/`:
- Ranking de corretores da House RP (maio de 2026): deve trazer Alessandra,
  Rafael e Wallace, na mesma ordem que aparece no visual montado sobre a fato.
- Ranking de gerentes (maio de 2026): Matheus Santamaria deve aparecer com 6
  unidades e R$ 1,75 milhão, batendo com o slide "Liga das vendas".
- Distratos e VGV já estão reconciliados: ao centavo, no caso dos distratos, e em
  98,8% dos casos, no caso do VGV.

> **Atenção:** o bronze local hoje é parcial. Para o relatório de produção de
> verdade, use o banco de produção, não o local: a máquina Windows física/local
> descrita em `infra/RUNBOOK_WINDOWS.md` (o plano de instância EC2 foi
> descartado em 20/ago/2026 — a TI não provisionou, e passou uma máquina Windows
> já existente no lugar). Troque o servidor da conexão para `localhost:5432`
> (não `localhost:5433`, que é só do banco de dev) e o usuário para `pafil_bi`
> (não `postgres`/`PafilLocalDev2026`) — a senha do `pafil_bi` fica em
> `C:\pafil\pafil_credenciais.txt`, dentro da própria máquina de produção. O
> modelo e as medidas em si não mudam nesse processo.

## 7. Como atualizar mês a mês

Depois de rodar a carga incremental (`ingestao.py --incremental`) seguida de
`aplicar_tudo.py`, basta clicar em Atualizar dentro do Power BI Desktop. Em
produção, isso já roda sozinho: a máquina Windows física/local
(`infra/RUNBOOK_WINDOWS.md`) tem uma tarefa agendada rodando a ingestão
incremental de hora em hora, e o Power BI Service atualiza automaticamente
através do On-premises Data Gateway instalado na mesma máquina do banco.
