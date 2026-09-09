"""Ingestão dos dados de atendimento do Blip (tickets, filas, atendentes).

Pacote irmão de `cvdw/`: mesma separação entre cliente HTTP (`api.py`) e
persistência, mas falando o protocolo de comandos do Blip em vez da API REST
paginada do CVDW. O acesso ao Postgres é reaproveitado de `cvdw.db`, que não
tem nada de específico do CVDW.
"""
