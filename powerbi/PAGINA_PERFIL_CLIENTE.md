# Perfil do Cliente: como montar a página nova (DP-15)

Este documento não é um levantamento visual a visual do legado (como
`PAGINA_PRECO.md` fez para o BI de Preço) — as três páginas de "Perfil do Cliente"
do BI Matriz não foram auditadas visual por visual nesta sessão. Em vez disso,
propõe um desenho novo com base nos cortes já testados e validados no relatório
ad-hoc `relatorios/perfil_cliente_quinta_dos_ventos_2026.sql` (17 seções, rodadas
contra a bronze real). A montagem em si, como o resto do `.pbix`, é manual no
Power BI Desktop.

## 1. Por que 3 páginas legadas viram 1

O legado tinha "Perfil do Cliente", "Perfil do Cliente Reserva" e "Perfil do
Cliente Pré Cadastro" — três páginas quase idênticas, cada uma lendo o mesmo CSV de
148 colunas (`perfil cliente`), cortado por um contexto de fato diferente (cliente
em geral, cliente que reservou, cliente que passou pelo funil de crédito). Na gold
nova, isso é 1 dimensão (`gold.dim_perfil_cliente`) que se relaciona por
`documento_chave` com `fato_reservas` e `fato_precadastros` — o slicer de
empreendimento e o filtro de contexto (reserva vs. pré-cadastro) fazem o mesmo
papel que as 3 páginas faziam com tabelas separadas.

**Recomendação:** montar 1 página só, relacionada a `fato_reservas` (cobre "quem
comprou"), com um segundo grupo de cards/visuais relacionado a `fato_precadastros`
(cobre "quem entrou no funil de crédito", incluindo quem não comprou) — sem
relacionar `dim_perfil_cliente` às duas fatos ao mesmo tempo (forma losango, ver
`MODELO_SEMANTICO.md`). Se o volume de visuais crescer, separar em 2 páginas
("Perfil — Vendas" e "Perfil — Funil de Crédito") é uma opção melhor do que
recriar as 3 do legado.

## 2. Cortes recomendados (seções já validadas no relatório ad-hoc)

| Seção | Medida/coluna | Fonte na gold |
|---|---|---|
| Resumo | `Perfis Cadastrados`, `Renda Mediana`, `Idade Mediana`, `% Com Renda Informada` | `dim_perfil_cliente` |
| Sexo | `% Feminino` por `dim_perfil_cliente[sexo]` | `dim_perfil_cliente` |
| Faixa etária | contagem por `dim_perfil_cliente[faixa_etaria]`, cruzado com `Renda Mediana` | `dim_perfil_cliente` |
| Estado civil | contagem por `dim_perfil_cliente[estado_civil]`, `% Solteiro` | `dim_perfil_cliente` |
| Faixa de renda / MCMV | contagem por `dim_perfil_cliente[faixa_renda_mcmv]` | `dim_perfil_cliente` |
| Profissão | contagem por `dim_perfil_cliente[profissao_macro]` (e drill-down pra `profissao_micro`), com `% Com Profissão Identificada` como nota de cobertura | `dim_perfil_cliente` + DP-07 |
| Origem geográfica | contagem por `dim_perfil_cliente[cidade]`/`[estado]` | `dim_perfil_cliente` |
| Comprometimento de renda | `Comprometimento de Renda` (parcela aprovada ÷ renda) | `fato_precadastros[valor_prestacao]` ÷ `dim_perfil_cliente[renda]` |
| PPE / compliance | `% PPE`, tabela com `pessoa_lista_suspeitos`/`residente_municipio_fronteira` quando `TRUE` | `dim_perfil_cliente` |
| Mídia/origem do lead | reaproveita `dim_origem` (já existe, relacionada a `fato_precadastros`/`fato_leads`) | `dim_origem` |
| Evolução mensal | `Renda Mediana`/`Idade Mediana` por `dim_calendario[ano_mes]` (relacionamento por `fato_reservas[data_venda]`) | `dim_perfil_cliente` + `dim_calendario` |
| Comparativo por empreendimento | mesmos cortes acima, com `dim_empreendimento[empreendimento]` como slicer | `dim_perfil_cliente` + `dim_empreendimento` |

Medidas de partida em [`MEDIDAS_PERFIL_CLIENTE.dax`](MEDIDAS_PERFIL_CLIENTE.dax).

## 3. Ressalvas a levar para o Desktop (herdadas do relatório ad-hoc e da
   investigação desta sessão)

- **Renda vem 0, não NULL, quando não preenchida.** Sempre filtrar
  `tem_renda_informada = TRUE` (ou `renda > 0`) e usar **mediana**, nunca média
  crua — a digitação é livre no CVCRM, sem validação (achado: valores no teto de
  R$ 99.999.999,99 continuam existindo na fonte).
- **A fonte mudou no mesmo dia (24/ago/2026): de CSV manual para a API CVDW**
  (`bronze.pessoas` ⨝ `bronze.pessoas/profissional`, endpoint novo — ver DP-15 em
  `REGRAS_NEGOCIO.md` para o histórico completo da investigação). Isso resolveu o
  problema de cobertura que existia antes: a taxa de match de `documento_chave`
  contra `fato_reservas` subiu de 85,9% pra **96,9%**, e o caso mais crítico do
  CSV (Residencial Quinta dos Ventos, vendas de 2026, que batia só 9,5% porque o
  CSV era um snapshot parado em ago/2025) foi pra **95,2%**. O CSV manual
  continua no repo só como *fallback* silencioso (`fonte_perfil='precadastro'`
  na dimensão) — não precisa mais de reexport manual pra manter a página
  atualizada, a ingestão via `ingestao.py --incremental` já cobre isso.
- **Cobertura de profissão é real, não um problema de join**: `profissao` está
  65,7% preenchida na fonte (medido na carga completa, 8.465 registros). Mostrar
  `% Com Profissão Identificada` perto de qualquer visual de profissão evita que
  alguém leia a lacuna residual (~34%) como bug.
- **PPE e a lista de indivíduos suspeitos têm cobertura baixa por natureza**
  (poucas pessoas se enquadram) — não é falha de dado.
- **Sem banco, sem PJ, sem documento de identidade na gold** — decisão de
  escopo/LGPD (DP-15 em `REGRAS_NEGOCIO.md`). Se a gestão precisar dessas
  colunas para um caso de uso específico (ex.: auditoria de compliance), a
  extensão é trazer mais colunas de `bronze.pessoas`/`bronze.pessoas_profissional`
  na view, não reabrir uma fonte manual.
