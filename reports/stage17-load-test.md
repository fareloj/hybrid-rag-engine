# Etapa 17 - Carga e Capacidade

1. **Etapa concluida:** carga concorrente, pico, reranking, reindexacao simultanea e soak test aprovados no hardware de referencia.
2. **O que foi implementado:** gerador HTTP concorrente com conexoes persistentes, percentis, throughput, classificacao de erros/respostas parciais e amostragem de CPU, RAM e GPU; runner reproduzivel com escadas de concorrencia e criterios de aceite.
3. **Arquivos principais alterados:** `scripts/load_test.py`, `scripts/load_test_test.py`, `scripts/load-stage17-validate.ps1`, `README.md` e `reports/stage17-load-test.json`.
4. **Validacao executada:** 3.106 requisicoes medidas, concorrencia de 1 a 40 para busca comum, 1 a 8 para reranking completo, trafego misto, busca durante rebuild dos dois indices e soak de 180 segundos.
5. **Red teams executados:** saturacao progressiva, fila no embedding, GPU em 99%, rebuild dense/BM25 durante carga e operacao sustentada com 10% das buscas rerankeadas.
6. **Resultados observados:** zero erros e zero respostas parciais. O SLO de p95 ate 5 segundos foi atendido ate concorrencia 10 sem reranking e 8 com reranking. O soak processou 1.646 requisicoes a 9,03 req/s, p95 de 1,68 s. O pico de VRAM foi 4.619 MiB.
7. **Problemas encontrados e como foram corrigidos:** o teste anterior usava somente oito buscas concorrentes e nao media percentis. A nova ferramenta revelou fila acima da capacidade util: concorrencia 20 chegou a p95 de 15,44 s e concorrencia 40 a 17,53 s. Esses niveis foram documentados como sobrecarga, apesar de nao produzirem erros.
8. **Evidencia final de aceite:** `scripts/load-stage17-validate.ps1` terminou com status aprovado, todos os servicos saudaveis e os dados completos persistidos em `reports/stage17-load-test.json`.
9. **Proxima etapa recomendada:** repetir a bateria no corpus e hardware de producao, adicionando monitoramento continuo de p95/p99 e fila antes de aumentar os limites declarados.

## Limites medidos

| Cenario | Concorrencia | Throughput | p95 | Erros |
| --- | ---: | ---: | ---: | ---: |
| Busca comum | 1 | 3,79 req/s | 283 ms | 0 |
| Busca comum | 5 | 9,58 req/s | 566 ms | 0 |
| Busca comum | 10 | 9,58 req/s | 1.185 ms | 0 |
| Busca comum | 20 | 5,98 req/s | 15.440 ms | 0 |
| Busca comum | 40 | 7,69 req/s | 17.525 ms | 0 |
| Reranking completo | 8 | 1,75 req/s | 4.975 ms | 0 |
| Trafego misto | 12 | 6,07 req/s | 2.449 ms | 0 |
| Rebuild simultaneo | 10 | 8,76 req/s | 1.794 ms | 0 |
| Soak de 180 s | 10 | 9,03 req/s | 1.677 ms | 0 |

Os numeros valem para a RTX 3060 12 GB, 800 chunks indexados e configuracao registrada no JSON. Eles nao sao uma garantia para outro ambiente.

