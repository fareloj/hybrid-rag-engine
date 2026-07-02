$ErrorActionPreference = "Stop"

function Invoke-JsonPost($Url, $Body) {
    return Invoke-RestMethod -Method Post -Uri $Url -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 30)
}

function Invoke-ExpectedFailure($Description, $Url, $Body, [int[]]$ExpectedStatusCodes) {
    try {
        Invoke-JsonPost $Url $Body | Out-Null
        throw "Expected failure did not happen: $Description"
    } catch {
        $response = $_.Exception.Response
        if ($null -eq $response) {
            throw
        }
        $statusCode = [int]$response.StatusCode
        if ($ExpectedStatusCodes -notcontains $statusCode) {
            throw "Unexpected status for $Description`: $statusCode"
        }
        Write-Host "Expected failure passed: $Description -> HTTP $statusCode"
    }
}

function Assert-RerankedSearch($Query, $Description, [int]$RerankTopK = 3) {
    $response = Invoke-JsonPost "http://localhost:8090/search" @{
        query = $Query
        top_k = 5
        top_n_dense = 10
        top_n_lexical = 10
        rrf_k = 60
        use_reranker = $true
        rerank_top_k = $RerankTopK
    }
    if ($response.status -ne "succeeded") {
        throw "Expected reranked search succeeded for $Description, got $($response.status)"
    }
    if (-not $response.reranker_applied) {
        throw "Reranker was not applied for $Description"
    }
    if ($response.results.Count -lt 1) {
        throw "No results for $Description"
    }
    $reranked = @($response.results | Where-Object { $null -ne $_.reranker_score })
    if ($reranked.Count -lt 1) {
        throw "No reranker_score in top results for $Description"
    }
    foreach ($result in $reranked) {
        if ($null -eq $result.original_rank -or $null -eq $result.original_rrf_score) {
            throw "Original RRF rank/score not preserved for $Description"
        }
    }
    if ($null -eq $response.sources.reranker.latency_ms -or $response.sources.reranker.latency_ms -le 0) {
        throw "Missing reranker latency for $Description"
    }
    Write-Host "Reranked search ok: $Description query='$Query' reranked=$($reranked.Count) latency_ms=$([math]::Round($response.sources.reranker.latency_ms, 2))"
    return $response
}

try {
    Write-Host "Stage 10 reranker validation starting..."
    $health = Invoke-RestMethod "http://localhost:8090/health"
    if ($health.dependencies.reranker.body.device -ne "cuda") {
        throw "Expected reranker device cuda, got '$($health.dependencies.reranker.body.device)'"
    }
    Write-Host "Reranker device ok: cuda"
    Invoke-JsonPost "http://localhost:8090/dense/reindex" @{} | Out-Null
    Invoke-JsonPost "http://localhost:8090/lexical/reindex" @{} | Out-Null

    $unit = @'
from app.reranker import apply_rerank

candidates = [
    {"chunk_id": "a", "rank": 1, "rrf_score": 0.3, "text": "A", "metadata_found": True},
    {"chunk_id": "b", "rank": 2, "rrf_score": 0.2, "text": "B", "metadata_found": True},
    {"chunk_id": "c", "rank": 3, "rrf_score": 0.1, "text": "C", "metadata_found": True},
]
reranked = apply_rerank(
    candidates,
    [{"id": "c", "score": 9.0, "rank": 1}, {"id": "a", "score": -5.0, "rank": 2}],
    3,
)
assert [item["chunk_id"] for item in reranked] == ["c", "a", "b"], reranked
assert reranked[0]["original_rank"] == 3
assert reranked[0]["original_rrf_score"] == 0.1
assert reranked[0]["reranker_score"] == 9.0
print("Reranker application unit tests passed.")
'@
    $unit | docker compose exec -T orchestrator-python python -
    if ($LASTEXITCODE -ne 0) {
        throw "Reranker application unit tests failed"
    }

    Invoke-ExpectedFailure "blank reranker document text" "http://localhost:8083/rerank" @{
        query = "ingest"
        documents = @(@{ id = "blank"; text = "" })
    } @(422)

    $tooMany = @()
    for ($i = 0; $i -lt 65; $i++) {
        $tooMany += @{ id = "doc-$i"; text = "document $i" }
    }
    Invoke-ExpectedFailure "batch too large" "http://localhost:8083/rerank" @{
        query = "ingest"
        documents = $tooMany
    } @(422, 413)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    docker compose exec -T `
        -e RERANKER_MODEL="missing/local-reranker" `
        -e HF_HUB_OFFLINE="1" `
        -e HF_HOME="/tmp/missing-hf-cache" `
        reranker-python python -c "from app.main import model; model()" *> $null
    $modelFailureExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($modelFailureExitCode -eq 0) {
        throw "Expected unavailable model check to fail"
    }
    Write-Host "Expected failure passed: unavailable/offline model"

    Assert-RerankedSearch "POST /ingest" "endpoint exact small top-k" 2 | Out-Null
    Assert-RerankedSearch "buscar função ingest" "accent plus symbol larger top-k" 4 | Out-Null
    Assert-RerankedSearch "musica 11/01" "date no accent" 2 | Out-Null
    Assert-RerankedSearch "documento órfão" "orphan accent" 2 | Out-Null

    $longChunk = "texto longo " * 700
    $longResponse = Invoke-JsonPost "http://localhost:8083/rerank" @{
        query = "texto longo"
        documents = @(
            @{ id = "long"; text = $longChunk },
            @{ id = "short"; text = "outro assunto" }
        )
    }
    if ($longResponse.results.Count -ne 2) {
        throw "Long chunk rerank did not return two results"
    }
    if ($longResponse.device -ne "cuda") {
        throw "Expected long chunk rerank to use cuda, got '$($longResponse.device)'"
    }
    Write-Host "Long chunk rerank ok."

    Write-Host "Testing reranker outage fallback..."
    docker compose stop reranker-python | Out-Null
    Start-Sleep -Seconds 2
    $partial = Invoke-JsonPost "http://localhost:8090/search" @{
        query = "POST /ingest"
        top_k = 5
        top_n_dense = 8
        top_n_lexical = 8
        use_reranker = $true
        rerank_top_k = 3
    }
    if ($partial.status -ne "partial" -or -not $partial.source_errors.reranker) {
        throw "Expected partial search with reranker unavailable"
    }
    if ($partial.results.Count -lt 1) {
        throw "RRF fallback returned no results when reranker was down"
    }
    Write-Host "Reranker outage fallback ok."
} finally {
    docker compose up -d --no-build reranker-python dense-index-cpp lexical-index-java orchestrator-python | Out-Null
    Start-Sleep -Seconds 5
    try {
        Invoke-JsonPost "http://localhost:8090/dense/reindex" @{} | Out-Null
        Invoke-JsonPost "http://localhost:8090/lexical/reindex" @{} | Out-Null
    } catch {
        Write-Host "Restore reindex warning: $($_.Exception.Message)"
    }
}

$health = Invoke-RestMethod "http://localhost:8090/health"
if ($health.status -ne "ok") {
    throw "Expected final health ok, got $($health.status)"
}

Write-Host "Stage 10 reranker validation passed."
