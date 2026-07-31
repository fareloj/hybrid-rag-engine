# Etapa 13 - Hardening do Sistema

Data: 2026-07-14

## 1. Etapa concluida

Etapa 13 concluida. O sistema falha de forma controlada e recupera dependencias e indices apos falhas intencionais.

## 2. O que foi implementado

- Timeouts configuraveis por dependencia.
- Retry limitado para falhas de transporte e HTTP 5xx.
- Circuit breaker por servico com estados aberto, meio aberto e fechado.
- Limites validados para query, arquivo, chunk e candidatos do reranker.
- Erros HTTP 503 claros para dependencia indisponivel.
- Busca concorrente no indice C++ e pool fixo no servico Java.
- Rebuild atomico preservando o indice anterior ate o novo estar pronto.

## 3. Arquivos principais alterados

- `services/orchestrator-python/app/config.py`
- `services/orchestrator-python/app/resilience.py`
- `services/orchestrator-python/app/main.py`
- `services/dense-index-cpp/src/main.cpp`
- `services/lexical-index-java/src/main/java/dev/rag/lexical/Main.java`
- `services/orchestrator-python/tests/test_hardening.py`
- `scripts/hardening-stage13-validate.ps1`

## 4. Validacao executada

- Build Docker do orchestrator, C++ e Java: passou.
- Testes Python: 17 passaram.
- Carga concorrente com 8 queries variadas: passou.
- Rebuild denso e lexical durante buscas concorrentes: passou.
- Restart dos indices seguido de reindexacao e busca: passou.
- Regressao completa da Etapa 12: passou.

## 5. Red teams executados

- Query adversarial com 8001 caracteres rejeitada com HTTP 422.
- Corpus com arquivo acima de 1 MB e arquivo binario: somente arquivo seguro indexado.
- Servico lexical indisponivel repetidamente: busca parcial e circuit breaker aberto.
- Ingestao interrompida com `docker compose kill`: nenhuma run ficou em estado `running`.
- Configuracao `MAX_QUERY_CHARS=0`: startup rejeitado.

## 6. Resultados observados

- Circuit breaker abriu apos 3 falhas e recuperou apos a janela configurada.
- Logs registraram `circuit_opened`, `circuit_half_open` e `circuit_closed` com request ID.
- Dense e lexical voltaram com 111 chunks; vetores densos mantiveram dimensao 1024.
- Reranker permaneceu em CUDA na RTX 3060.

## 7. Problemas encontrados e correcoes

- O indice C++ processava uma conexao por vez; foi alterado para atender conexoes concorrentes com protecao por mutex.
- Erros HTTP 4xx alimentavam o circuit breaker; agora somente transporte e HTTP 5xx contam como falha da dependencia.
- Alguns endpoints poderiam retornar 500 cru em falha de transporte; agora retornam HTTP 503 com mensagem clara.
- A `.venv` local nao era ignorada; foi adicionada ao `.gitignore`.

## 8. Evidencia final de aceite

`scripts/hardening-stage13-validate.ps1` terminou com `Stage 13 hardening validation passed.` e a regressao `scripts/observability-stage12-validate.ps1` tambem passou.

## 9. Proxima etapa recomendada

Etapa 14: adicionar ANN no C++ mantendo o modo linear para comparacao objetiva de recall e latencia.
