// ============================================================================
// fato_leads — Power Query do Esteira de reservas.pbix
//
// DECISÃO (16/jul/2026): os nomes de coluna legados (iguais à f_leads do BI
// Matriz) nascem na PRÓPRIA VIEW gold.fato_leads (aliases SQL com aspas duplas —
// ver sql/gold/gold.sql). O Power Query NÃO renomeia nada: consome como está.
// Ponto único de verdade dos nomes = a view.
//
// O M da consulta fato_leads deve ficar EXATAMENTE assim (o passo RemoveColumns
// tira a ativo_receptivo_20 da fonte porque "atv/recept 2" é coluna calculada
// DAX no modelo — fórmula idêntica à do BI Matriz):
// ============================================================================
let
    Fonte = PostgreSQL.Database("localhost:5433", "pafil_dw"),
    gold_fato_leads = Fonte{[Schema="gold",Item="fato_leads"]}[Data],
    #"Colunas Removidas" = Table.RemoveColumns(gold_fato_leads,{"ativo_receptivo_20"})
in
    #"Colunas Removidas"
