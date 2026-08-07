// =============================================================================
// DE-PARA DE CLASSIFICACAO DE VENDA  (Power Query / M)
//
// Objetivo: trazer para o modelo do Power BI as colunas de classificacao que
// NAO vem do CVDW e sao preenchidas manualmente no fechamento (planilha
// "Vendas Consolidadas.xlsm"), chaveadas por Proposta (= idreserva).
//
// Colunas oficiais (fonte: fechamento manual):
//   Origem, Canal, Midia, E Lead?, Diretoria / House-Parcerias, on/off,
//   Pago ou Organico, Qtd Corretores, Reciclagem?, Qtd Reciclagem,
//   Ativacao?, Qtd Ativacao, Perdeu Roleta?, Qtd perdeu roleta
//
// IMPORTANTE (manutencao / bus-factor):
//   A fonte ideal e UMA aba/tabela canonica unica com Proposta + as 14 colunas,
//   preenchida a cada fechamento. Hoje elas estao espalhadas (master so ate 2024
//   e sem 6 colunas; recentes em Consolidado/Vendas Novas; set completo nas abas
//   anuais). Recomendacao: criar no .xlsm uma TABELA NOMEADA "de_para_classificacao"
//   e apontar este M para ela. Enquanto isso nao existe, ajuste o passo "Aba".
// =============================================================================

// ---- Query 1: de_para_classificacao ----------------------------------------
// Le o de_para_classificacao.xlsx JA LIMPO (gerado por gerar_depara_classificacao.py e
// versionado em BI V3 CVDW/depara/depara_classificacao/arquivo/). NAO le a Vendas
// Consolidadas baguncada direto — o script ja consolidou as abas numa unica.
let
    Caminho = "C:\Users\Artur Filho\Pafil Construtora e Empreendimentos Imobiliarios\COMERCIAL - Documentos\GESTÃO COMERCIAL\Backoffice Comercial\BI - Comercial\Relatórios Comercial\BI V3 CVDW\depara\depara_classificacao\arquivo\de_para_classificacao.xlsx",
    Fonte    = Excel.Workbook(File.Contents(Caminho), null, true),
    Aba       = Fonte{[Item="de_para_classificacao", Kind="Sheet"]}[Data],
    Cabecalho = Table.PromoteHeaders(Aba, [PromoteAllScalars=true]),

    Tipos = Table.TransformColumnTypes(Cabecalho, {
        {"Proposta", Int64.Type},
        {"Origem", type text}, {"Canal", type text}, {"Mídia", type text},
        {"É Lead?", type text}, {"Diretoria / House-Parcerias", type text}, {"on/off", type text},
        {"Pago ou Orgânico", type text}, {"Região", type text}, {"Share", type text},
        {"Qtd Corretores", Int64.Type},
        {"Reciclagem?", type text}, {"Qtd Reciclagem", Int64.Type},
        {"Ativação?", type text}, {"Qtd Ativação", Int64.Type},
        {"Perdeu Roleta?", type text}, {"Qtd perdeu roleta", Int64.Type}
    }),

    // limpa linhas de total/junk e garante 1 linha por Proposta
    SemVazios = Table.SelectRows(Tipos, each [Proposta] <> null and [Proposta] <> 0),
    Unica     = Table.Distinct(SemVazios, {"Proposta"})
in
    Unica


// ---- Passos a acrescentar NA QUERY DA FATO (reservas) -----------------------
// Suponha que sua query da fato se chame "fato_reservas" e tenha a coluna
// "id_reserva" (Int64, = Proposta). Cole estes 2 passos no final do let dela:
//
//     JoinClf = Table.NestedJoin(
//         PASSO_ANTERIOR, {"id_reserva"},
//         de_para_classificacao, {"Proposta"},
//         "clf", JoinKind.LeftOuter ),
//     Classificacao = Table.ExpandTableColumn( JoinClf, "clf",
//         {"Origem","Canal","Mídia","É Lead?","Diretoria / House-Parcerias","on/off",
//          "Pago ou Orgânico","Região","Share","Qtd Corretores","Reciclagem?","Qtd Reciclagem",
//          "Ativação?","Qtd Ativação","Perdeu Roleta?","Qtd perdeu roleta"} )
// in
//     Classificacao
//
// Resultado: as 14 colunas passam a existir na fato, vindas 100% do fechamento
// oficial. Vendas ainda nao classificadas (mes corrente) ficam em branco ate o
// proximo fechamento — comportamento esperado da opcao "substituir 100%".
