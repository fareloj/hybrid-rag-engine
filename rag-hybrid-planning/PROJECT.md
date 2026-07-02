# PROJECT.md

## Premissa

Construir um **motor de retrieval híbrido do zero** - não importar um vector DB pronto (Chroma, Pinecone), mas *fazer* o meu. O objetivo é entender RAG de verdade, da camada de índice até o reranker, e no fim ter uma peça de infraestrutura reutilizável que o NAVI e o CASPER vão plugar como backend de busca.

## O problema que ele resolve

Recuperar os trechos mais relevantes de uma base grande (meus próprios repositórios de código) dada uma query em linguagem natural - com qualidade alta o suficiente pra alimentar um agente, não só "funcionar no demo".

## Por que híbrido

Retrieval bom tem duas metades complementares:

- **Léxica** (BM25 / casamento de termos) - pega match exato, nomes, símbolos. Reino do Java.
- **Densa** (similaridade vetorial via embeddings) - pega significado, paráfrase. Sensível a latência -> C++.

Sozinha, cada uma falha em casos onde a outra acerta. Fundir as duas (Reciprocal Rank Fusion) + reordenar o top-k com um **reranker** (cross-encoder) é o que separa um RAG decente de um RAG de tutorial.

## Stack e o papel de cada peça

| Peça | Linguagem | Papel |
|------|-----------|-------|
| Índice vetorial denso | **C++** | Busca por vizinhos mais próximos. Onde latência importa e onde aprendo systems. |
| Busca léxica (BM25) | **Java** | Camada onde a linguagem é historicamente forte (Lucene). |
| Embeddings | **Python + Ollama** | Sidecar de ML: transforma texto em vetor usando modelo local no Ollama. |
| Reranker | **Python + Sentence Transformers** | Serviço separado de rerank com cross-encoder local fora do Ollama. |
| Documentos + metadados | **Postgres** | Fonte da verdade. `pgvector` como baseline pra eu benchmarkar meu índice C++. |
| Orquestração | **Docker** | 3 serviços em 3 linguagens conversando -> compose é o cenário natural, não enfeite. |

## Modelos locais

O MVP usa Ollama como runtime local de embeddings e roda o reranker fora dele:

- Embeddings via Ollama: `qwen3-embedding:0.6b`
- Reranker via Sentence Transformers: `Qwen/Qwen3-Reranker-0.6B`

O Docker Compose deve incluir o serviço do Ollama, persistir o volume de modelos e documentar o pull obrigatório do embedding:

```powershell
ollama pull qwen3-embedding:0.6b
```

## Fluxo

```text
query -> [Python/Ollama] embedding
      -> [C++] top-N denso  +  [Java] top-N léxico
      -> fusão (RRF)
      -> [Python/Sentence Transformers] reranker reordena top-k
      -> resposta
```

## Critério de "deu certo"

Não é achismo: meu índice C++ comparado contra `pgvector` no mesmo Postgres, medindo latência e qualidade de recuperação. Se o que eu construí não encosta no baseline, não está pronto.

## Escopo

Projeto grande, polyglot, sistema distribuído de verdade. A dor central - e o aprendizado - está na **integração entre os três serviços** (contratos, comunicação, ordem de subida no compose), não em nenhuma linguagem isolada.
