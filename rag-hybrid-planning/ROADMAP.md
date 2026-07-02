# ROADMAP.md - Etapas Até o Final do RAG Híbrido

## Resumo

Este arquivo é o documento operacional do projeto. Ele lista as fases do RAG híbrido, com o que implementar, o que testar, checks de red team por etapa e critérios objetivos de aceite.

## 0. Fundação do Projeto

### Fazer

- Criar monorepo com serviços Python, C++, Java, Postgres e pasta `proto`.
- Configurar Docker Compose com Python, C++, Java, Postgres, Ollama, serviço Python de rerank, `.env.example`, scripts de dev e documentação mínima.
- Persistir volume do Ollama e documentar pull do embedding `qwen3-embedding:0.6b`.
- Persistir cache Hugging Face do reranker `Qwen/Qwen3-Reranker-0.6B`.
- Definir convenções de logs, IDs de chunks, paths e versionamento de contratos.

### Testar

- `docker compose up` sobe todos os serviços.
- Health checks respondem.
- Serviço Ollama responde e lista o embedding exigido.
- Serviço de rerank responde health check.
- CI local roda build/test básico de cada linguagem.

### Red team

- Derrubar um serviço e confirmar erro claro.
- Subir serviços fora de ordem.
- Rodar sem `.env` e validar mensagens úteis.
- Rodar com embedding Ollama ausente ou pull incompleto.
- Rodar com cache/modelo de reranker ausente.

### Aceite

- Ambiente reproduzível em máquina limpa.

## 1. Modelo de Dados e Postgres

### Fazer

- Criar tabelas para documentos, chunks, embeddings, runs de ingestão e métricas.
- Ativar `pgvector`.
- Criar migrations versionadas.

### Testar

- Inserção, atualização e remoção de chunks.
- Consulta por metadados.
- Busca vetorial baseline com `pgvector`.

### Red team

- Inserir paths duplicados.
- Inserir chunk vazio.
- Inserir embedding com dimensão errada.
- Reindexar o mesmo repo duas vezes.

### Aceite

- Postgres é fonte da verdade consistente e auditável.

## 2. Contratos gRPC

### Fazer

- Definir Protobufs para indexação, busca densa, busca lexical, health e erros.
- Gerar clients/servers para Python, C++ e Java.
- Versionar contrato com compatibilidade mínima.

### Testar

- Testes de contrato entre Python <-> C++ e Python <-> Java.
- Serialização de resultados com score, rank e metadados.

### Red team

- Enviar `top_k` inválido.
- Enviar embedding vazio.
- Enviar payload grande.
- Simular timeout.

### Aceite

- Serviços conversam via gRPC sem lógica acoplada por linguagem.

## 3. Ingestão de Repositórios

### Fazer

- Scanner de repos locais.
- Ignorar `.git`, `node_modules`, `dist`, `target`, `.venv`, binários e arquivos enormes.
- Detectar linguagem por extensão.
- Criar chunks com path, linguagem, linhas inicial/final e texto.

### Testar

- Fixture com repo pequeno.
- Arquivos grandes.
- Arquivos vazios.
- Reindexação incremental.

### Red team

- Repo com symlink circular.
- Arquivo com encoding estranho.
- Arquivo minificado gigante.
- Path malicioso ou fora da raiz configurada.

### Aceite

- Corpus local vira chunks estáveis e reproduzíveis.

## 4. Embeddings Locais

### Fazer

- Integrar Ollama via Python usando `qwen3-embedding:0.6b`.
- Normalizar vetores.
- Persistir embeddings no Postgres.
- Validar dimensão configurada.

### Testar

- Mesmo texto gera embedding determinístico dentro da tolerância.
- Batch embedding funciona.
- Falha de modelo/Ollama retorna erro claro.
- Dimensão real retornada pelo modelo é validada contra a configuração.

### Red team

- Texto vazio.
- Texto muito longo.
- Modelo ausente no cache.
- Pull interrompido ou modelo parcialmente baixado.
- Endpoint Ollama indisponível.
- Dimensão diferente da esperada.

### Aceite

- Todos os chunks indexáveis têm embeddings válidos.

## 5. Índice Vetorial C++ Linear

### Fazer

- Implementar índice em memória.
- Carregar vetores a partir do orquestrador.
- Buscar top-k por similaridade coseno ou dot product normalizado.
- Retornar IDs, scores e ranks.

### Testar

- Comparar resultados com cálculo Python simples.
- Testar top-k maior que tamanho do índice.
- Testar índice vazio.

### Red team

- Vetor NaN/Inf.
- Dimensão errada.
- Milhares/milhões de vetores para medir degradação.
- Recarregar índice durante busca.

### Aceite

- Busca exata C++ bate com referência matemática.

## 6. Baseline `pgvector`

### Fazer

- Implementar busca densa equivalente no Postgres.
- Usar os mesmos embeddings e chunks do C++.
- Registrar latência e overlap.

### Testar

- Comparar top-k C++ vs `pgvector`.
- Validar ordenação e score.
- Medir latência por tamanho de corpus.

### Red team

- Índice `pgvector` ausente.
- Dados parcialmente indexados.
- Embeddings inconsistentes.

### Aceite

- Existe baseline confiável para julgar o índice próprio.

## 7. Busca Lexical Java com Lucene

### Fazer

- Criar serviço Java gRPC.
- Indexar texto, path, linguagem e metadados.
- Usar BM25 do Lucene.
- Suportar reindexação.

### Testar

- Query por nome exato de símbolo.
- Query por path.
- Query com termos raros.
- Query sem resultados.

### Red team

- Caracteres especiais de query.
- Código com tokens longos.
- Arquivos duplicados.
- Corpus reindexado durante busca.

### Aceite

- BM25 encontra símbolos e matches exatos melhor que busca densa.

## 8. Orquestrador Python

### Fazer

- Expor `/ingest`, `/search` e `/health`.
- Fazer embedding da query.
- Consultar C++ e Java em paralelo.
- Buscar chunks no Postgres.
- Retornar resposta consolidada.

### Testar

- Busca ponta a ponta.
- Timeout parcial de serviço.
- Resultado sem metadados faltantes.
- Health agregado.

### Red team

- C++ fora do ar.
- Java fora do ar.
- Postgres lento.
- Query vazia ou enorme.

### Aceite

- Um endpoint entrega busca híbrida funcional.

## 9. Fusão por RRF

### Fazer

- Implementar Reciprocal Rank Fusion.
- Parametrizar `k`, `top_n_dense`, `top_n_lexical`.
- Preservar origem dos scores.

### Testar

- Casos com duplicatas entre dense e lexical.
- Resultados só de uma fonte.
- Ordenação determinística em empate.

### Red team

- Scores extremos.
- Rankings vazios.
- IDs inconsistentes entre serviços.

### Aceite

- Resultado híbrido combina semantic search e exact match de forma estável.

## 10. Reranker Local

### Fazer

- Integrar reranker local fora do Ollama usando `Qwen/Qwen3-Reranker-0.6B` via Sentence Transformers.
- Rerankear top-k pós-RRF.
- Registrar score original e score reranker.

### Testar

- Query com múltiplos candidatos parecidos.
- Rerank top-k pequeno e grande.
- Latência do reranker.

### Red team

- Texto de chunk muito longo.
- Modelo indisponível.
- Download interrompido ou modelo parcialmente baixado.
- Endpoint do serviço de rerank indisponível.
- Reranker contradizendo todos os sinais anteriores.
- Batch grande demais para memória.

### Aceite

- Reranker melhora métricas sem tornar latência inviável.

## 11. Avaliação Curada

### Fazer

- Criar dataset versionado de queries com arquivos/spans esperados.
- Implementar métricas `recall@k`, `MRR`, `nDCG`, overlap e latência.
- Gerar relatório local.

### Testar

- Métricas em fixture pequena com resultado conhecido.
- Reprodutibilidade entre runs.
- Comparação C++, `pgvector`, BM25, RRF e rerank.

### Red team

- Query ambígua.
- Relevância parcial.
- Resultado certo em arquivo errado.
- Mudança no corpus invalidando labels.

### Aceite

- Qualidade deixa de ser achismo.

## 12. Observabilidade e Operação

### Fazer

- Logs estruturados por request ID.
- Métricas por etapa.
- Traces simples entre serviços.
- Relatórios de ingestão e busca.

### Testar

- Request ID atravessa Python, C++ e Java.
- Logs ajudam a explicar resultado ruim.
- Métricas mostram gargalos.

### Red team

- Alto volume de queries.
- Falhas intermitentes.
- Logs com texto sensível demais.
- Métricas ausentes em erro.

### Aceite

- Dá para debugar latência, qualidade e falhas sem adivinhar.

## 13. Hardening do Sistema

### Fazer

- Timeouts, retries limitados e circuit breakers simples.
- Limites de tamanho para query, arquivo e chunk.
- Validação forte de configs.
- Modo rebuild seguro dos índices.

### Testar

- Carga moderada concorrente.
- Rebuild enquanto busca roda.
- Recuperação após restart.
- Configuração inválida.

### Red team

- Query adversarial gigante.
- Corpus com arquivos hostis.
- Serviço reiniciando em loop.
- Ingestão interrompida no meio.

### Aceite

- Sistema falha de forma controlada.

## 14. Índice Vetorial Avançado

### Fazer

- Implementar HNSW ou outro ANN no C++ após MVP estável.
- Manter modo linear para validação.
- Comparar recall/latência contra linear e `pgvector`.

### Testar

- Recall@k vs busca exata.
- Latência por tamanho de corpus.
- Persistência/carregamento do índice.
- Parâmetros ANN.

### Red team

- Recall ruim em queries raras.
- Índice corrompido.
- Inserções incrementalmente degradando qualidade.
- Configuração ANN agressiva demais.

### Aceite

- ANN melhora latência mantendo qualidade aceitável.

## 15. API Reutilizável para NAVI/CASPER

### Fazer

- Estabilizar endpoint de busca.
- Documentar contrato de resposta.
- Adicionar exemplos de integração.
- Separar configuração por projeto/corpus.

### Testar

- Cliente externo simples.
- Busca com filtros por repo/path/linguagem.
- Compatibilidade de resposta entre versões.

### Red team

- Cliente antigo contra serviço novo.
- Corpus múltiplo com IDs conflitantes.
- Query que retorna metadados insuficientes para agente.

### Aceite

- NAVI e CASPER conseguem usar o retrieval como backend.

## 16. Red Team Final

### Fazer

- Rodar bateria adversarial completa antes de chamar o projeto de pronto.
- Testar segurança, robustez, qualidade, latência e operação.

### Testar

- Queries vagas, enganosas, longas e com símbolos raros.
- Repos grandes e heterogêneos.
- Falha simultânea parcial de serviços.
- Reindexação completa.
- Comparação contra baseline `pgvector`.

### Red team

- Prompt/query injection dentro de arquivos indexados.
- Arquivos tentando manipular resposta do agente.
- Dados duplicados ou contraditórios.
- Corpus com segredos acidentais.
- Ataques por payload grande.
- Queda de serviço durante busca.
- Resultados semanticamente plausíveis mas errados.

### Aceite

- Falhas conhecidas estão documentadas.
- Métricas finais batem o mínimo definido.
- Sistema é reproduzível, debuggável e plugável.

## Critério Final de Conclusão

O projeto está pronto quando:

- Ingestão, busca híbrida, RRF, reranker e avaliação rodam por Docker Compose.
- Ollama roda no Compose com `qwen3-embedding:0.6b` disponível.
- Reranker Python roda no Compose com `Qwen/Qwen3-Reranker-0.6B` configurado.
- O índice C++ é comparado objetivamente contra `pgvector`.
- BM25 melhora recuperação de símbolos e nomes exatos.
- Reranker melhora ranking final em queries curadas.
- Red teams por etapa e final foram executados.
- NAVI/CASPER conseguem consumir a API sem conhecer detalhes internos.
