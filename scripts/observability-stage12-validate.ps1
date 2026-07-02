$ErrorActionPreference = "Stop"

function Invoke-JsonPostWithHeaders($Url, $Body, $Headers) {
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "POST"
    $request.ContentType = "application/json"
    foreach ($header in $Headers.GetEnumerator()) {
        $request.Headers[$header.Key] = [string]$header.Value
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20))
    $request.ContentLength = $bytes.Length
    $stream = $request.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $response = $request.GetResponse()
    $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
    $content = $reader.ReadToEnd()
    $reader.Close()
    return [pscustomobject]@{
        Headers = $response.Headers
        Content = $content
    }
}

function Assert-LogsContain($Service, $Pattern) {
    $logs = (docker compose logs --tail=300 $Service) -join "`n"
    if ($logs -notmatch [regex]::Escape($Pattern)) {
        throw "Expected logs for $Service to contain '$Pattern'"
    }
    Write-Host "Log propagation ok: $Service contains $Pattern"
}

function Assert-LogsDoNotContain($Pattern) {
    $logs = (docker compose logs --tail=500 orchestrator-python dense-index-cpp lexical-index-java reranker-python) -join "`n"
    if ($logs -match [regex]::Escape($Pattern)) {
        throw "Sensitive text leaked to logs: $Pattern"
    }
    Write-Host "Sensitive log red team ok: '$Pattern' not present"
}

Write-Host "Stage 12 observability validation starting..."

Invoke-RestMethod "http://localhost:8090/health" | Out-Null
Invoke-RestMethod "http://localhost:8090/dense/reindex" -Method Post | Out-Null
Invoke-RestMethod "http://localhost:8090/lexical/reindex" -Method Post | Out-Null

$requestId = "stage12-" + [guid]::NewGuid().ToString("N")
$headers = @{ "X-Request-ID" = $requestId }
$response = Invoke-JsonPostWithHeaders "http://localhost:8090/search" @{
    query = "POST /ingest"
    top_k = 3
    top_n_dense = 5
    top_n_lexical = 5
    use_reranker = $true
    rerank_top_k = 3
} $headers

if ($response.Headers["X-Request-ID"] -ne $requestId) {
    throw "Response did not preserve X-Request-ID"
}
$payload = $response.Content | ConvertFrom-Json
if ($null -eq $payload.latency_ms.total -or $null -eq $payload.sources.dense.latency_ms -or $null -eq $payload.sources.lexical.latency_ms) {
    throw "Search response missing operational latency metrics"
}
if (-not $payload.reranker_applied -or $null -eq $payload.sources.reranker.latency_ms) {
    throw "Reranker metrics missing"
}

Start-Sleep -Seconds 2
Assert-LogsContain "orchestrator-python" $requestId
Assert-LogsContain "dense-index-cpp" $requestId
Assert-LogsContain "lexical-index-java" $requestId
Assert-LogsContain "reranker-python" $requestId

Write-Host "Testing small high-volume query batch..."
for ($i = 0; $i -lt 5; $i++) {
    $batchId = "$requestId-batch-$i"
    Invoke-JsonPostWithHeaders "http://localhost:8090/search" @{
        query = "repository scanner"
        top_k = 2
        top_n_dense = 4
        top_n_lexical = 4
        use_reranker = $false
    } @{ "X-Request-ID" = $batchId } | Out-Null
}

$secret = "SUPERSECRET_STAGE12_DO_NOT_LOG"
Invoke-JsonPostWithHeaders "http://localhost:8090/search" @{
    query = $secret
    top_k = 2
    top_n_dense = 2
    top_n_lexical = 2
    use_reranker = $false
} @{ "X-Request-ID" = "$requestId-secret" } | Out-Null
Start-Sleep -Seconds 1
Assert-LogsDoNotContain $secret

Write-Host "Testing intermittent lexical failure observability..."
try {
    docker compose stop lexical-index-java | Out-Null
    Start-Sleep -Seconds 2
    $partial = Invoke-JsonPostWithHeaders "http://localhost:8090/search" @{
        query = "POST /ingest"
        top_k = 3
        top_n_dense = 5
        top_n_lexical = 5
        use_reranker = $false
    } @{ "X-Request-ID" = "$requestId-partial" }
    $partialPayload = $partial.Content | ConvertFrom-Json
    if ($partialPayload.status -ne "partial" -or $null -eq $partialPayload.source_errors.lexical) {
        throw "Expected partial response with lexical source error"
    }
    if ($null -eq $partialPayload.latency_ms.total) {
        throw "Partial error response missing latency metrics"
    }
} finally {
    docker compose up -d --no-build lexical-index-java | Out-Null
    Start-Sleep -Seconds 3
    Invoke-RestMethod "http://localhost:8090/lexical/reindex" -Method Post | Out-Null
}

$health = Invoke-RestMethod "http://localhost:8090/health"
if ($health.status -ne "ok") {
    throw "Expected final health ok, got $($health.status)"
}

Write-Host "Stage 12 observability validation passed."
