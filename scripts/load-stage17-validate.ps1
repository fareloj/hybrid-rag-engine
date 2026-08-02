$ErrorActionPreference = "Stop"

$baseUrl = "http://localhost:8090"
$root = (Resolve-Path "$PSScriptRoot\..").Path
$loadTool = Join-Path $PSScriptRoot "load_test.py"
$reportPath = Join-Path $root "reports\stage17-load-test.json"
$temporaryDirectory = Join-Path $env:TEMP "hybrid-rag-stage17-$PID"
$python = if (Test-Path (Join-Path $root ".venv\Scripts\python.exe")) {
    Join-Path $root ".venv\Scripts\python.exe"
} else {
    "python"
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Wait-Healthy {
    for ($attempt = 1; $attempt -le 90; $attempt++) {
        try {
            $health = Invoke-RestMethod "$baseUrl/health" -TimeoutSec 5
            if ($health.status -eq "ok") { return $health }
        } catch {
        }
        Start-Sleep -Seconds 1
    }
    throw "system did not become healthy"
}

function Invoke-LoadScenario {
    param(
        [string]$Name,
        [int]$Concurrency,
        [Nullable[int]]$Requests = $null,
        [Nullable[int]]$DurationSeconds = $null,
        [double]$RerankRatio = 0,
        [double]$MaxErrorRate = 0.01,
        [double]$MaxP95Ms = 60000
    )

    $output = Join-Path $temporaryDirectory "$Name.json"
    $arguments = @(
        $loadTool,
        "--scenario", $Name,
        "--base-url", $baseUrl,
        "--concurrency", $Concurrency,
        "--rerank-ratio", $RerankRatio,
        "--timeout-seconds", 60,
        "--max-error-rate", $MaxErrorRate,
        "--max-partial-rate", 0,
        "--max-p95-ms", $MaxP95Ms,
        "--output", $output
    )
    if ($null -ne $Requests) {
        $arguments += @("--requests", $Requests)
    } else {
        $arguments += @("--duration-seconds", $DurationSeconds)
    }

    Write-Host "Running $Name (concurrency=$Concurrency rerank_ratio=$RerankRatio)..."
    & $python @arguments | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) "$Name exceeded its error, partial-response or latency threshold"
    return Get-Content $output -Raw -Encoding utf8 | ConvertFrom-Json
}

function Remove-TemporaryDirectory {
    if (-not (Test-Path -LiteralPath $temporaryDirectory)) { return }
    $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP)
    $resolvedTarget = [IO.Path]::GetFullPath($temporaryDirectory)
    if (-not $resolvedTarget.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar)) {
        throw "refusing to remove load-test output outside the temporary directory"
    }
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
}

Write-Host "Stage 17 production load validation starting..."
$initialHealth = Wait-Healthy
Assert-True ($initialHealth.dependencies.reranker.body.device -eq "cuda") "reranker is not using CUDA"
$indexed = [int]$initialHealth.dependencies.dense_index.body.indexed
Assert-True ($indexed -gt 0) "dense index is empty"

Remove-TemporaryDirectory
$null = New-Item -ItemType Directory -Path $temporaryDirectory
$scenarios = [Collections.Generic.List[object]]::new()

try {
    $null = Invoke-LoadScenario -Name "warmup" -Concurrency 2 -Requests 24 -MaxErrorRate 0 -MaxP95Ms 10000

    foreach ($concurrency in @(1, 5, 10, 20, 40)) {
        $requestCount = [Math]::Max(100, $concurrency * 10)
        $scenario = Invoke-LoadScenario -Name "search-c$concurrency" -Concurrency $concurrency -Requests $requestCount
        $scenarios.Add($scenario)
    }

    foreach ($concurrency in @(1, 2, 4, 8)) {
        $scenario = Invoke-LoadScenario -Name "rerank-c$concurrency" -Concurrency $concurrency -Requests 40 -RerankRatio 1
        $scenarios.Add($scenario)
    }

    $mixed = Invoke-LoadScenario -Name "mixed-c12" -Concurrency 12 -Requests 240 -RerankRatio 0.2 -MaxP95Ms 15000
    $scenarios.Add($mixed)

    Write-Host "Running search load while both indexes rebuild..."
    $denseJob = Start-Job -ScriptBlock { param($Url) Invoke-RestMethod "$Url/dense/reindex" -Method Post } -ArgumentList $baseUrl
    $lexicalJob = Start-Job -ScriptBlock { param($Url) Invoke-RestMethod "$Url/lexical/reindex" -Method Post } -ArgumentList $baseUrl
    try {
        $reindex = Invoke-LoadScenario -Name "reindex-c10" -Concurrency 10 -Requests 160 -MaxP95Ms 15000
        $scenarios.Add($reindex)
        $null = @($denseJob, $lexicalJob) | Wait-Job -Timeout 180
        Assert-True ($denseJob.State -eq "Completed") "dense reindex did not finish during load test"
        Assert-True ($lexicalJob.State -eq "Completed") "lexical reindex did not finish during load test"
        $null = Receive-Job $denseJob
        $null = Receive-Job $lexicalJob
    } finally {
        @($denseJob, $lexicalJob) | Remove-Job -Force -ErrorAction SilentlyContinue
    }

    $soak = Invoke-LoadScenario -Name "soak-c10" -Concurrency 10 -DurationSeconds 180 -RerankRatio 0.1 -MaxP95Ms 15000
    $scenarios.Add($soak)

    $searchCapacity = @(
        $scenarios | Where-Object {
            $_.scenario -like "search-c*" -and
            $_.results.error_rate -le 0.01 -and
            $_.results.partial_rate -eq 0 -and
            $_.results.latency_ms.p95 -le 5000
        } | ForEach-Object { [int]$_.configuration.concurrency }
    ) | Measure-Object -Maximum
    $rerankCapacity = @(
        $scenarios | Where-Object {
            $_.scenario -like "rerank-c*" -and
            $_.results.error_rate -le 0.01 -and
            $_.results.partial_rate -eq 0 -and
            $_.results.latency_ms.p95 -le 5000
        } | ForEach-Object { [int]$_.configuration.concurrency }
    ) | Measure-Object -Maximum

    $totalRequests = ($scenarios | ForEach-Object { [int]$_.results.requests } | Measure-Object -Sum).Sum
    $totalErrors = ($scenarios | ForEach-Object { [int]$_.results.errors } | Measure-Object -Sum).Sum
    $finalHealth = Wait-Healthy
    $report = [ordered]@{
        status = "passed"
        timestamp = (Get-Date).ToString("o")
        corpus = @{ indexed_chunks = $indexed }
        acceptance = @{
            search_concurrency_at_p95_5s = [int]$searchCapacity.Maximum
            rerank_concurrency_at_p95_5s = [int]$rerankCapacity.Maximum
            total_requests = [int]$totalRequests
            total_errors = [int]$totalErrors
            soak_duration_seconds = 180
            final_health = $finalHealth.status
        }
        scenarios = @($scenarios)
    }
    $report | ConvertTo-Json -Depth 12 | Set-Content $reportPath -Encoding utf8
    Assert-True ($report.acceptance.search_concurrency_at_p95_5s -ge 1) "no non-reranked concurrency level met the 5-second p95 objective"
    Assert-True ($report.acceptance.rerank_concurrency_at_p95_5s -ge 1) "no reranked concurrency level met the 5-second p95 objective"
    Assert-True ($totalErrors -eq 0) "load validation observed $totalErrors request errors"
    Assert-True ($finalHealth.status -eq "ok") "system was not healthy after load validation"
    Write-Host "Stage 17 passed. requests=$totalRequests search_capacity=$($searchCapacity.Maximum) rerank_capacity=$($rerankCapacity.Maximum)"
} finally {
    Remove-TemporaryDirectory
}
