# Etapa 14 - Indice Vetorial Avancado

1. **Etapa concluida:** HNSW no servico C++, mantendo busca linear como baseline exata.
2. **O que foi implementado:** indice HNSW configuravel, persistencia atomica de indice e manifesto, carga no startup, fallback controlado para indice corrompido e benchmark linear/HNSW.
3. **Arquivos principais alterados:** `services/dense-index-cpp/src/main.cpp`, `services/dense-index-cpp/CMakeLists.txt`, `docker-compose.yml` e `scripts/ann-stage14-validate.ps1`.
4. **Validacao executada:** build Docker C++, comparacao com busca linear, corpus sintetico de 10.000 vetores, restart e restauracao do indice.
5. **Red teams executados:** indice persistido corrompido, parametros ANN invalidos/agressivos, queries raras e restart durante operacao.
6. **Resultados observados:** recall@10 de 1,0 no corpus real e sintetico. No sintetico, latencia interna media de 1,73 ms no linear e 0,13 ms no HNSW.
7. **Problemas encontrados e correcao:** configuracao invalida encerrava o processo como esperado; o script foi estruturado para confirmar a falha, restaurar a configuracao e recarregar o indice real.
8. **Evidencia final de aceite:** `scripts/ann-stage14-validate.ps1` passou e `reports/stage14-ann-benchmark.json` contem as medicoes reproduziveis.
9. **Proxima etapa recomendada:** estabilizar a API reutilizavel.

