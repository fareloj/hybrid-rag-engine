# Protobuf Contracts

The public wire contracts live under `proto/rag/v1`.

## Versioning Rules

- Add fields with new field numbers only.
- Do not reuse or renumber existing fields.
- Keep removed fields reserved in the same message.
- Add new RPCs instead of changing request/response semantics in place.
- Breaking changes require a new package version, for example `rag.v2`.

## Generation

```powershell
.\scripts\proto-generate.ps1
.\scripts\proto-check.ps1
```

Generated Python stubs are committed under:

```text
services/orchestrator-python/app/generated
```

The descriptor set is committed under:

```text
proto/descriptors/rag_v1_retrieval.pb
```

The descriptor gives future Java/C++ build tooling a stable contract artifact even before those services switch from HTTP scaffolding to gRPC servers.
