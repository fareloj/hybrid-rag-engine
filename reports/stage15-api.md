# Etapa 15 - API Reutilizavel

1. **Etapa concluida:** contrato versionado de retrieval pronto para clientes externos.
2. **O que foi implementado:** `POST /v1/search`, alias compativel `POST /search`, filtros por corpus, prefixo de path e linguagem, metadados completos de origem e cliente Python sem dependencias externas.
3. **Arquivos principais alterados:** `services/orchestrator-python/app/main.py`, `services/orchestrator-python/app/search.py`, `examples/hybrid_rag_client.py`, `README.md` e `scripts/api-stage15-validate.ps1`.
4. **Validacao executada:** contrato v1, filtros, resposta legada, cliente externo e metadados de arquivo/linhas/scores.
5. **Red teams executados:** dois corpora com o mesmo path, cliente antigo contra endpoint novo e busca sem metadados suficientes.
6. **Resultados observados:** todos os filtros restringiram corretamente os resultados; IDs permaneceram distintos entre corpora e o cliente externo consumiu a API.
7. **Problemas encontrados e correcao:** a identidade baseada apenas no path colidia entre corpora; o contrato passou a manter corpus e IDs persistentes separados.
8. **Evidencia final de aceite:** `scripts/api-stage15-validate.ps1` passou com os seis containers saudaveis.
9. **Proxima etapa recomendada:** executar a bateria adversarial final.

