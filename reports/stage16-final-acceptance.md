# Etapa 16 - Red Team Final

1. **Etapa concluida:** bateria final de seguranca, robustez, qualidade, latencia e operacao aprovada.
2. **O que foi implementado:** deteccao de prompt injection em corpus, redacao de segredos, avaliacao por chunk/intervalo de linhas e fusao adaptativa entre RRF e reranker.
3. **Arquivos principais alterados:** `services/orchestrator-python/app/ingestion.py`, `services/orchestrator-python/app/evaluation.py`, `services/orchestrator-python/app/evaluation_dataset.py`, `services/orchestrator-python/app/reranker.py` e `scripts/final-redteam-stage16.ps1`.
4. **Validacao executada:** 27 testes Python, checks de imports/protobuf, regressao das Etapas 12 a 15, 30 queries variadas e avaliacao curada dos cinco modos de retrieval.
5. **Red teams executados:** prompt injection, segredo acidental, duplicatas, contradicoes, payload grande, corpus hostil, falha simultanea dos indices, configuracao ANN invalida, indice corrompido e restart.
6. **Resultados observados:** busca p95 de 309,65 ms; reranker CUDA medio de 724,90 ms; HNSW recall@10 de 1,0; overlap linear/pgvector top-5 de 5; MRR RRF 0,4861 para rerank 0,5208; nDCG@5 RRF 0,5301 para rerank 0,5577.
7. **Problemas encontrados e correcao:** a metrica aceitava qualquer chunk do arquivo e contava relevancia duplicada; passou a exigir sobreposicao de linhas e uma correspondencia por expectativa. A fusao de linguagem natural foi calibrada para 30% RRF e 70% reranker, mantendo 95% RRF para queries exatas/curtas.
8. **Evidencia final de aceite:** `scripts/final-redteam-stage16.ps1` passou; resultados estruturados em `reports/stage16-final-redteam.json`; todos os containers terminaram saudaveis e o reranker reportou CUDA.
9. **Proxima etapa recomendada:** integrar NAVI/CASPER e acompanhar metricas com corpus de producao, sem novas mudancas arquiteturais antes de dados reais.

## Riscos conhecidos

- O tag `sam860/qwen3-embedding:0.6b-F16` existe no Ollama, mas o servidor oficial testado nao oferece embeddings para ele. O sistema usa `qwen3-embedding:0.6b`, com 1024 dimensoes, e mantem o tag solicitado instalado para rastreabilidade.
- O primeiro carregamento do reranker depende do cache Hugging Face; uma instalacao nova requer download do modelo.
- Os limiares de qualidade foram calibrados no corpus atual. Um corpus de producao deve ganhar seu proprio dataset curado antes de alterar pesos.
- CMake e Maven nao estao instalados no host; os builds C++ e Java sao validados nas respectivas imagens Docker.

