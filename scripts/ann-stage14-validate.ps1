$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Wait-DenseHealthy {
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $health = Invoke-RestMethod http://localhost:8081/health -TimeoutSec 3
            if ($health.status -eq "ok") { return $health }
        } catch {
        }
        Start-Sleep -Seconds 1
    }
    throw "dense index did not become healthy"
}

function Invoke-DenseSearch {
    param([double[]]$Vector, [string]$Mode)
    $body = @{ embedding = $Vector; top_k = 10; mode = $Mode } | ConvertTo-Json -Compress
    return Invoke-RestMethod http://localhost:8081/search -Method Post -ContentType "application/json" -Body $body
}

Write-Host "Stage 14 ANN validation starting..."
$realReindex = Invoke-RestMethod http://localhost:8090/dense/reindex -Method Post
Assert-True ($realReindex.indexed -gt 0) "real dense reindex failed"

$realBenchmark = Invoke-RestMethod http://localhost:8090/dense/ann/benchmark -Method Post -ContentType "application/json" -Body '{"sample_size":50,"top_k":10}'
Assert-True ($realBenchmark.avg_recall_at_k -ge 0.95) "real-corpus ANN recall below 0.95"

Write-Host "Building 10000-vector synthetic corpus..."
$culture = [Globalization.CultureInfo]::InvariantCulture
$dimension = 32
$count = 10000
$vectors = [Collections.Generic.List[string]]::new($count)
$queryVectors = @{}
for ($index = 0; $index -lt $count; $index++) {
    $raw = [double[]]::new($dimension)
    $normSquared = 0.0
    for ($column = 0; $column -lt $dimension; $column++) {
        $value = [Math]::Sin(($index + 1) * ($column + 1) * 0.017) + [Math]::Cos(($index + 3) * ($column + 2) * 0.011)
        $raw[$column] = $value
        $normSquared += $value * $value
    }
    $norm = [Math]::Sqrt($normSquared)
    $formatted = [Collections.Generic.List[string]]::new($dimension)
    $normalized = [double[]]::new($dimension)
    for ($column = 0; $column -lt $dimension; $column++) {
        $normalized[$column] = $raw[$column] / $norm
        $formatted.Add($normalized[$column].ToString("R", $culture))
    }
    if ($index % 500 -eq 0) { $queryVectors[$index] = $normalized }
    $vectors.Add("{`"chunk_id`":`"synthetic-$index`",`"values`":[$([string]::Join(',', $formatted))]}")
}
$indexPayload = "{`"vectors`":[$([string]::Join(',', $vectors))]}"
$syntheticIndex = Invoke-RestMethod http://localhost:8081/index -Method Post -ContentType "application/json" -Body $indexPayload -TimeoutSec 180
Assert-True ($syntheticIndex.indexed -eq $count) "synthetic HNSW index count mismatch"

Write-Host "Comparing exact linear and HNSW search..."
$recalls = [Collections.Generic.List[double]]::new()
$linearLatencies = [Collections.Generic.List[double]]::new()
$hnswLatencies = [Collections.Generic.List[double]]::new()
foreach ($queryVector in $queryVectors.Values) {
    $linear = Invoke-DenseSearch $queryVector "linear"
    $hnsw = Invoke-DenseSearch $queryVector "hnsw"
    $linearIds = @($linear.results | ForEach-Object chunk_id)
    $hnswIds = @($hnsw.results | ForEach-Object chunk_id)
    $overlap = @($linearIds | Where-Object { $_ -in $hnswIds }).Count
    $recalls.Add($overlap / 10.0)
    $linearLatencies.Add([double]$linear.latency_ms)
    $hnswLatencies.Add([double]$hnsw.latency_ms)
}
$avgRecall = ($recalls | Measure-Object -Average).Average
$avgLinear = ($linearLatencies | Measure-Object -Average).Average
$avgHnsw = ($hnswLatencies | Measure-Object -Average).Average
Assert-True ($avgRecall -ge 0.95) "synthetic ANN recall below 0.95: $avgRecall"
Assert-True ($avgHnsw -lt $avgLinear) "HNSW did not improve internal latency: linear=$avgLinear hnsw=$avgHnsw"

Write-Host "Testing persisted index reload..."
docker compose restart dense-index-cpp | Out-Host
$loadedHealth = Wait-DenseHealthy
Assert-True ($loadedHealth.indexed -eq $count) "persisted HNSW index did not restore all vectors"
Assert-True ($loadedHealth.hnsw.loaded) "persisted HNSW index was not loaded"
$restoredSearch = Invoke-DenseSearch $queryVectors[0] "linear"
Assert-True ($restoredSearch.results.Count -eq 10) "linear baseline was not restored from persisted HNSW data"

Write-Host "Testing corrupted persisted index..."
docker compose exec -T dense-index-cpp sh -c "printf corrupt > /data/hnsw.bin"
docker compose restart dense-index-cpp | Out-Host
$corruptHealth = Wait-DenseHealthy
Assert-True ($corruptHealth.indexed -eq 0) "corrupted index should load as empty"
$loadFailure = docker compose logs --tail=100 dense-index-cpp | Select-String "dense_index_load_failed"
Assert-True ($null -ne $loadFailure) "corrupted index failure was not logged"

Write-Host "Testing aggressive invalid ANN configuration..."
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$denseImage = docker compose images -q dense-index-cpp
Assert-True (-not [string]::IsNullOrWhiteSpace($denseImage)) "dense index image not found"
docker run --rm -e HNSW_M=101 $denseImage *> $null
$invalidConfigExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
Assert-True ($invalidConfigExit -ne 0) "invalid HNSW_M unexpectedly started"

Write-Host "Restoring real index and validating rare queries..."
$restore = Invoke-RestMethod http://localhost:8090/dense/reindex -Method Post
Assert-True ($restore.indexed -eq $realReindex.indexed) "real index restore failed"
foreach ($query in @("documento órfão", "reingestao incremental", "POST /ingest", "chunks start_line end_line")) {
    $body = @{ query = $query; top_k = 5; use_reranker = $false } | ConvertTo-Json
    $result = Invoke-RestMethod http://localhost:8090/search -Method Post -ContentType "application/json" -Body $body
    Assert-True ($result.results.Count -gt 0) "rare query returned no results: $query"
}

$report = [ordered]@{
    real_corpus = [ordered]@{
        vectors = $realReindex.indexed
        recall_at_10 = $realBenchmark.avg_recall_at_k
        linear_service_latency_ms = $realBenchmark.avg_linear_service_latency_ms
        hnsw_service_latency_ms = $realBenchmark.avg_hnsw_service_latency_ms
    }
    synthetic_corpus = [ordered]@{
        vectors = $count
        dimensions = $dimension
        queries = $queryVectors.Count
        recall_at_10 = $avgRecall
        linear_service_latency_ms = $avgLinear
        hnsw_service_latency_ms = $avgHnsw
    }
}
$report | ConvertTo-Json -Depth 5 | Set-Content "$PSScriptRoot\..\reports\stage14-ann-benchmark.json" -Encoding utf8
Write-Host "Stage 14 ANN validation passed. synthetic_recall=$avgRecall linear_ms=$avgLinear hnsw_ms=$avgHnsw"
