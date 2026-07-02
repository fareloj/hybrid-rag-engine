$ErrorActionPreference = "Stop"

function Invoke-JsonPost($Url, $Body) {
    return Invoke-RestMethod -Method Post -Uri $Url -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 20)
}

function Assert-RrfResponse($Query, $Description) {
    $response = Invoke-JsonPost "http://localhost:8090/search" @{
        query = $Query
        top_k = 5
        top_n_dense = 8
        top_n_lexical = 8
        rrf_k = 60
        use_reranker = $false
    }
    if ($response.status -ne "succeeded") {
        throw "Expected succeeded for $Description, got $($response.status)"
    }
    if ($response.results.Count -lt 1) {
        throw "Expected RRF results for $Description"
    }
    foreach ($result in $response.results) {
        if ($null -eq $result.rrf_score -or $result.rrf_score -le 0) {
            throw "Missing or invalid rrf_score for $Description"
        }
        if ($null -eq $result.rrf_contributions) {
            throw "Missing rrf_contributions for $Description"
        }
        if ($result.sources.Count -lt 1) {
            throw "Missing source list for $Description"
        }
    }
    Write-Host "RRF endpoint ok: $Description query='$Query' results=$($response.results.Count)"
    return $response
}

Write-Host "Stage 9 RRF validation starting..."

$env:PYTHONPATH = "services/orchestrator-python"
$unit = @'
from app.search import fuse_rrf

def ids(items):
    return [item["chunk_id"] for item in items]

duplicate = fuse_rrf(
    [{"chunk_id": "a", "rank": 1, "score": 0.1}, {"chunk_id": "b", "rank": 2, "score": -999999}],
    [{"chunk_id": "b", "rank": 1, "score": 999999}, {"chunk_id": "c", "rank": 2, "score": 0.0}],
    60,
)
assert ids(duplicate) == ["b", "a", "c"], duplicate
assert set(duplicate[0]["source_contributions"]) == {"dense", "lexical"}
assert duplicate[0]["rrf_score"] > duplicate[1]["rrf_score"]

dense_only = fuse_rrf(
    [{"chunk_id": "b", "rank": 2}, {"chunk_id": "a", "rank": 1}],
    [],
    60,
)
assert ids(dense_only) == ["a", "b"], dense_only

tie = fuse_rrf(
    [{"chunk_id": "b", "rank": 1}],
    [{"chunk_id": "a", "rank": 1}],
    60,
)
assert ids(tie) == ["b", "a"], tie

empty = fuse_rrf([], [], 60)
assert empty == [], empty

bad = fuse_rrf(
    [{"rank": 1}, {"chunk_id": "x", "rank": 0}, {"chunk_id": "x", "rank": 1}, {"chunk_id": "y", "rank": "bad"}],
    [{"chunk_id": "z", "rank": -10}],
    60,
)
assert ids(bad) == ["x", "y", "z"], bad
print("RRF unit tests passed.")
'@
$unit | docker compose exec -T orchestrator-python python -
if ($LASTEXITCODE -ne 0) {
    throw "RRF unit tests failed"
}

Invoke-RestMethod "http://localhost:8090/health" | Out-Null
Invoke-JsonPost "http://localhost:8090/dense/reindex" @{} | Out-Null
Invoke-JsonPost "http://localhost:8090/lexical/reindex" @{} | Out-Null

$queries = @(
    @{ q = "POST /ingest"; d = "exact endpoint duplicate candidate" },
    @{ q = "buscar função ingest"; d = "accent plus symbol" },
    @{ q = "chunks start_line end_line"; d = "symbol-heavy metadata" },
    @{ q = "documento órfão"; d = "accent rare phrase" },
    @{ q = "reingestao incremental"; d = "no accent natural" },
    @{ q = "path malicioso symlink circular encoding estranho"; d = "long red-team mixed" }
)

foreach ($item in $queries) {
    Assert-RrfResponse $item.q $item.d | Out-Null
}

$small = Invoke-JsonPost "http://localhost:8090/search" @{
    query = "POST /ingest"
    top_k = 3
    top_n_dense = 1
    top_n_lexical = 1
    rrf_k = 10
    use_reranker = $false
}
if ($small.top_n_dense -ne 1 -or $small.top_n_lexical -ne 1 -or $small.rrf_k -ne 10) {
    throw "RRF parameters were not preserved in response"
}
if ($small.results.Count -gt 2) {
    throw "Unexpected more results than dense+lexical top_n allows"
}
Write-Host "RRF parameterization ok."

try {
    Write-Host "Testing RRF with dense-only fallback..."
    docker compose stop lexical-index-java | Out-Null
    Start-Sleep -Seconds 2
    $partial = Invoke-JsonPost "http://localhost:8090/search" @{
        query = "repository scanner"
        top_k = 5
        top_n_dense = 5
        top_n_lexical = 5
        rrf_k = 60
        use_reranker = $false
    }
    if ($partial.status -ne "partial" -or $partial.results.Count -lt 1) {
        throw "Expected partial dense-only RRF fallback"
    }
    foreach ($result in $partial.results) {
        if ($result.sources -notcontains "dense") {
            throw "Expected dense source in fallback result"
        }
    }
    Write-Host "Dense-only RRF fallback ok."
} finally {
    docker compose up -d --no-build lexical-index-java | Out-Null
    Start-Sleep -Seconds 3
    Invoke-JsonPost "http://localhost:8090/lexical/reindex" @{} | Out-Null
}

$health = Invoke-RestMethod "http://localhost:8090/health"
if ($health.status -ne "ok") {
    throw "Expected final health ok, got $($health.status)"
}

Write-Host "Stage 9 RRF validation passed."
