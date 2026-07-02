$ErrorActionPreference = "Stop"

function Invoke-JsonPost($Url, $Body) {
    return Invoke-RestMethod -Method Post -Uri $Url -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 20)
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

function Assert-SearchOk($Query, $Description, [int]$MinResults = 1) {
    $response = Invoke-JsonPost "http://localhost:8090/search" @{
        query = $Query
        top_k = 5
        dense_top_k = 8
        lexical_top_k = 8
        use_reranker = $false
    }
    if ($response.status -ne "succeeded") {
        throw "Search '$Description' did not succeed. Status=$($response.status)"
    }
    if ($response.results.Count -lt $MinResults) {
        throw "Search '$Description' returned $($response.results.Count), expected at least $MinResults"
    }
    if ($response.missing_metadata.Count -ne 0) {
        throw "Search '$Description' returned missing metadata: $($response.missing_metadata -join ',')"
    }
    foreach ($result in $response.results) {
        if (-not $result.path -or -not $result.chunk_id -or -not $result.text) {
            throw "Search '$Description' returned result without required metadata"
        }
    }
    Write-Host "Search '$Description' ok: query='$Query' results=$($response.results.Count)"
    return $response
}

function Assert-Partial($Query, $StoppedSource) {
    $response = Invoke-JsonPost "http://localhost:8090/search" @{
        query = $Query
        top_k = 5
        dense_top_k = 5
        lexical_top_k = 5
        use_reranker = $false
    }
    if ($response.status -ne "partial") {
        throw "Expected partial search with $StoppedSource down, got $($response.status)"
    }
    $sourceError = $response.source_errors.psobject.Properties[$StoppedSource].Value
    if (-not $sourceError) {
        throw "Expected source error for $StoppedSource"
    }
    if ($response.results.Count -lt 1) {
        throw "Partial search with $StoppedSource down returned no fallback results"
    }
    Write-Host "Partial search ok with $StoppedSource down: results=$($response.results.Count)"
}

try {
    Write-Host "Stage 8 orchestrator validation starting..."
    Invoke-RestMethod "http://localhost:8090/health" | Out-Null
    Invoke-JsonPost "http://localhost:8090/dense/reindex" @{} | Out-Null
    Invoke-JsonPost "http://localhost:8090/lexical/reindex" @{} | Out-Null

    $queries = @(
        @{ q = "musica"; d = "short no accent"; min = 0 },
        @{ q = "música"; d = "short accent"; min = 0 },
        @{ q = "musica 11/01"; d = "date no accent"; min = 0 },
        @{ q = "música 11/01"; d = "date accent"; min = 0 },
        @{ q = "buscar funcao ingest"; d = "natural plus symbol no accent"; min = 1 },
        @{ q = "buscar função ingest"; d = "natural plus symbol accent"; min = 1 },
        @{ q = "endpoint ingest"; d = "endpoint natural"; min = 1 },
        @{ q = "POST /ingest"; d = "endpoint exact"; min = 1 },
        @{ q = "repository scanner"; d = "english terms"; min = 1 },
        @{ q = "scanner de repo"; d = "portuguese terms"; min = 1 },
        @{ q = "chunks start_line end_line"; d = "metadata symbols"; min = 1 },
        @{ q = "reingestao incremental"; d = "reingestion no accent"; min = 0 },
        @{ q = "reingestão incremental"; d = "reingestion accent"; min = 0 },
        @{ q = "documento orfao"; d = "orphan no accent"; min = 0 },
        @{ q = "documento órfão"; d = "orphan accent"; min = 0 },
        @{ q = "funcao que remove documentos orfaos"; d = "long natural typo-ish"; min = 0 },
        @{ q = "função que remove documentos órfãos"; d = "long natural accent"; min = 0 },
        @{ q = "path malicioso symlink circular encoding estranho chunk vazio arquivo gigante"; d = "long red-team mixed"; min = 1 }
    )

    foreach ($item in $queries) {
        Assert-SearchOk $item.q $item.d $item.min | Out-Null
    }

    Invoke-ExpectedFailure "blank query" "http://localhost:8090/search" @{ query = "   " } @(400)
    Invoke-ExpectedFailure "huge query rejected" "http://localhost:8090/search" @{ query = ("x" * 9000) } @(422)

    Write-Host "Testing dense service outage..."
    docker compose stop dense-index-cpp | Out-Null
    Start-Sleep -Seconds 2
    Assert-Partial "POST /ingest" "dense"
    docker compose up -d --no-build dense-index-cpp | Out-Null
    Start-Sleep -Seconds 3
    Invoke-JsonPost "http://localhost:8090/dense/reindex" @{} | Out-Null

    Write-Host "Testing lexical service outage..."
    docker compose stop lexical-index-java | Out-Null
    Start-Sleep -Seconds 2
    Assert-Partial "repository scanner" "lexical"
    docker compose up -d --no-build lexical-index-java | Out-Null
    Start-Sleep -Seconds 3
    Invoke-JsonPost "http://localhost:8090/lexical/reindex" @{} | Out-Null

    $health = Invoke-RestMethod "http://localhost:8090/health"
    if ($health.status -ne "ok") {
        throw "Expected final health ok, got $($health.status)"
    }

    Write-Host "Stage 8 orchestrator validation passed."
} finally {
    docker compose up -d --no-build dense-index-cpp lexical-index-java orchestrator-python | Out-Null
}
