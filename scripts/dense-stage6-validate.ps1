$ErrorActionPreference = "Stop"

function Invoke-JsonPost {
    param(
        [string] $Uri,
        [string] $Body = "{}"
    )
    Invoke-RestMethod -Uri $Uri -Method Post -ContentType "application/json" -Body $Body
}

function Expect-Failure {
    param(
        [string] $Name,
        [scriptblock] $Action
    )
    try {
        & $Action | Out-Null
    } catch {
        Write-Host "Expected failure passed: $Name -> $($_.Exception.Message)"
        return
    }
    throw "Expected failure did not fail: $Name"
}

Write-Host "Stage 6 pgvector baseline validation starting..."

$extension = docker compose exec -T postgres psql -U rag -d rag -t -A -c "SELECT extname FROM pg_extension WHERE extname = 'vector';"
if ($extension.Trim() -ne "vector") {
    throw "pgvector extension is absent."
}

$embeddingCount = [int](docker compose exec -T postgres psql -U rag -d rag -t -A -c "SELECT count(*) FROM embeddings WHERE model = 'qwen3-embedding:0.6b';")
if ($embeddingCount -le 0) {
    throw "No embeddings available for pgvector baseline."
}

Write-Host "Restoring full C++ index from Postgres embeddings..."
$reindex = Invoke-JsonPost "http://localhost:8090/dense/reindex"
if ($reindex.indexed -ne $embeddingCount) {
    throw "C++ index count $($reindex.indexed) does not match Postgres embedding count $embeddingCount"
}

Write-Host "Running C++ vs pgvector benchmark..."
$benchmark = Invoke-JsonPost "http://localhost:8090/dense/benchmark" '{"sample_size":5,"top_k":5}'
if ($benchmark.sample_size -ne 5) {
    throw "Expected benchmark sample_size 5, got $($benchmark.sample_size)"
}
if ($benchmark.avg_overlap -lt 5) {
    throw "Expected avg top-5 overlap 5, got $($benchmark.avg_overlap)"
}
if ($benchmark.avg_cpp_latency_ms -lt 0 -or $benchmark.avg_pgvector_latency_ms -lt 0) {
    throw "Latency values must be non-negative."
}

Write-Host "Testing missing/absent baseline inputs..."
Expect-Failure "missing chunk embedding" {
    Invoke-JsonPost "http://localhost:8090/dense/compare" '{"chunk_id":"00000000-0000-0000-0000-000000000000","top_k":5}'
}

Write-Host "Testing partially indexed C++ data against pgvector baseline..."
Invoke-JsonPost "http://localhost:8081/index" '{"vectors":[{"chunk_id":"partial-only","values":[1,0]}]}' | Out-Null
$chunkId = docker compose exec -T postgres psql -U rag -d rag -t -A -c "SELECT chunk_id FROM embeddings WHERE model = 'qwen3-embedding:0.6b' ORDER BY chunk_id LIMIT 1;"
Expect-Failure "dimension mismatch from partially indexed data" {
    Invoke-JsonPost "http://localhost:8090/dense/compare" "{`"chunk_id`":`"$chunkId`",`"top_k`":5}"
}

Write-Host "Restoring real index after red team..."
$restore = Invoke-JsonPost "http://localhost:8090/dense/reindex"
if ($restore.indexed -ne $embeddingCount) {
    throw "Restore failed: indexed $($restore.indexed), expected $embeddingCount"
}

Write-Host "Stage 6 pgvector baseline validation passed. avg_overlap=$($benchmark.avg_overlap), avg_cpp_latency_ms=$($benchmark.avg_cpp_latency_ms), avg_pgvector_latency_ms=$($benchmark.avg_pgvector_latency_ms)"
