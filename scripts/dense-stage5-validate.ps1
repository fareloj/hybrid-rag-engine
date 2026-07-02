$ErrorActionPreference = "Stop"

function Invoke-JsonPost {
    param(
        [string] $Uri,
        [string] $Body
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

Write-Host "Stage 5 dense index validation starting..."

$health = Invoke-RestMethod http://localhost:8081/health
if ($health.service -ne "dense-index-cpp") {
    throw "Dense index health check returned unexpected service: $($health | ConvertTo-Json -Depth 4)"
}

Write-Host "Testing empty index search..."
Invoke-JsonPost "http://localhost:8081/index" '{"vectors":[]}' | Out-Null
$emptySearch = Invoke-JsonPost "http://localhost:8081/search" '{"embedding":[1,0],"top_k":5}'
if ($emptySearch.results.Count -ne 0) {
    throw "Expected empty search results, got $($emptySearch | ConvertTo-Json -Depth 5)"
}

Write-Host "Testing deterministic exact linear search..."
Invoke-JsonPost "http://localhost:8081/index" '{"vectors":[{"chunk_id":"a","values":[1,0]},{"chunk_id":"b","values":[0,1]},{"chunk_id":"c","values":[0.70710678,0.70710678]}]}' | Out-Null
$search = Invoke-JsonPost "http://localhost:8081/search" '{"embedding":[1,0],"top_k":10}'
if ($search.results.Count -ne 3) {
    throw "Expected 3 results for top_k > size, got $($search.results.Count)"
}
if ($search.results[0].chunk_id -ne "a") {
    throw "Expected top result 'a', got $($search.results[0].chunk_id)"
}

Write-Host "Testing invalid dimensions..."
Expect-Failure "dimension mismatch during index" {
    Invoke-JsonPost "http://localhost:8081/index" '{"vectors":[{"chunk_id":"a","values":[1,0]},{"chunk_id":"bad","values":[1,0,0]}]}'
}
Expect-Failure "dimension mismatch during search" {
    Invoke-JsonPost "http://localhost:8081/search" '{"embedding":[1,0,0],"top_k":5}'
}

Write-Host "Testing NaN/invalid JSON red team..."
Expect-Failure "NaN vector" {
    Invoke-JsonPost "http://localhost:8081/index" '{"vectors":[{"chunk_id":"nan","values":[NaN]}]}'
}

Write-Host "Testing thousands of vectors for basic degradation signal..."
$vectors = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt 2000; $i++) {
    $x = [math]::Cos($i)
    $y = [math]::Sin($i)
    $vectors.Add("{`"chunk_id`":`"v$i`",`"values`":[$x,$y]}")
}
$payload = "{`"vectors`":[" + ($vectors -join ",") + "]}"
$timer = [System.Diagnostics.Stopwatch]::StartNew()
Invoke-JsonPost "http://localhost:8081/index" $payload | Out-Null
$searchMany = Invoke-JsonPost "http://localhost:8081/search" '{"embedding":[1,0],"top_k":5}'
$timer.Stop()
if ($searchMany.results.Count -ne 5) {
    throw "Expected 5 results from large-vector search, got $($searchMany.results.Count)"
}
Write-Host "Large-vector index+search elapsed_ms=$($timer.ElapsedMilliseconds)"

Write-Host "Restoring real index from orchestrator/Postgres..."
$reindex = Invoke-RestMethod -Uri "http://localhost:8090/dense/reindex" -Method Post
if ($reindex.status -ne "succeeded" -or $reindex.indexed -le 0) {
    throw "Real dense reindex failed: $($reindex | ConvertTo-Json -Depth 5)"
}

$chunkId = docker compose exec -T postgres psql -U rag -d rag -t -A -c "SELECT chunk_id FROM embeddings WHERE model = 'qwen3-embedding:0.6b' ORDER BY chunk_id LIMIT 1;"
$compareBody = "{`"chunk_id`":`"$chunkId`",`"top_k`":5}"
$compare = Invoke-JsonPost "http://localhost:8090/dense/compare" $compareBody
if ($compare.overlap -lt 5) {
    throw "Expected full top-5 overlap between C++ and pgvector for self-query, got $($compare.overlap)"
}

Write-Host "Stage 5 dense index validation passed."
