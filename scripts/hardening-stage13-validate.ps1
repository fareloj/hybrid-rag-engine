$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

$baseUrl = "http://localhost:8090"
$workspace = (Resolve-Path "$PSScriptRoot\..").Path
$hostileFixture = Join-Path $workspace "stage13-hostile-fixture"
$interruptFixture = Join-Path $workspace "stage13-interrupt-fixture"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Search {
    param([string]$Query, [bool]$UseReranker = $false)
    $body = @{
        query = $Query
        top_k = 5
        dense_top_k = 10
        lexical_top_k = 10
        use_reranker = $UseReranker
        rerank_top_k = 5
    } | ConvertTo-Json
    return Invoke-RestMethod "$baseUrl/search" -Method Post -ContentType "application/json" -Body $body
}

function Wait-Healthy {
    param([int]$Attempts = 90)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $health = Invoke-RestMethod "$baseUrl/health" -TimeoutSec 3
            if ($health.status -eq "ok") {
                return $health
            }
        } catch {
        }
        Start-Sleep -Seconds 1
    }
    throw "orchestrator did not become healthy"
}

function Invoke-ConcurrentSearches {
    param([string[]]$Queries)
    $jobs = foreach ($query in $Queries) {
        Start-Job -ScriptBlock {
            param($Url, $Query)
            $body = @{ query = $Query; top_k = 3; use_reranker = $false } | ConvertTo-Json
            Invoke-RestMethod "$Url/search" -Method Post -ContentType "application/json" -Body $body
        } -ArgumentList $baseUrl, $query
    }
    try {
        $null = $jobs | Wait-Job -Timeout 120
        Assert-True (($jobs | Where-Object State -ne "Completed").Count -eq 0) "concurrent search timed out"
        $results = @($jobs | Receive-Job)
        Assert-True ($results.Count -eq $Queries.Count) "concurrent search returned incomplete results"
        Assert-True (@($results | Where-Object { $_.status -notin @("succeeded", "partial") }).Count -eq 0) "concurrent search returned invalid status"
        return $results
    } finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

function Remove-Fixture {
    param([string]$Path)
    $resolvedWorkspace = [IO.Path]::GetFullPath($workspace)
    $resolvedTarget = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedTarget.StartsWith($resolvedWorkspace + [IO.Path]::DirectorySeparatorChar)) {
        throw "refusing to remove fixture outside workspace: $resolvedTarget"
    }
    if (Test-Path -LiteralPath $resolvedTarget) {
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
    }
}

Write-Host "Stage 13 hardening validation starting..."
Wait-Healthy | Out-Null

Write-Host "Testing adversarial oversized query..."
$oversizedStatus = 0
try {
    $null = Invoke-WebRequest "$baseUrl/search" -Method Post -ContentType "application/json" -Body (@{ query = "x" * 8001 } | ConvertTo-Json)
} catch {
    $oversizedStatus = [int]$_.Exception.Response.StatusCode
}
Assert-True ($oversizedStatus -eq 422) "oversized query should return HTTP 422, got $oversizedStatus"

Write-Host "Testing moderate concurrent load..."
$queries = @(
    "musica", "música", "POST /ingest", "repository scanner",
    "reingestão incremental", "documento orfao", "chunks start_line end_line", "buscar função ingest"
)
$concurrent = Invoke-ConcurrentSearches $queries
Assert-True (($concurrent | Where-Object { $_.results.Count -eq 0 }).Count -lt $queries.Count) "all concurrent searches returned empty"

Write-Host "Testing rebuild while searches run..."
$denseJob = Start-Job -ScriptBlock { param($Url) Invoke-RestMethod "$Url/dense/reindex" -Method Post } -ArgumentList $baseUrl
$lexicalJob = Start-Job -ScriptBlock { param($Url) Invoke-RestMethod "$Url/lexical/reindex" -Method Post } -ArgumentList $baseUrl
try {
    $duringRebuild = Invoke-ConcurrentSearches $queries
    $null = @($denseJob, $lexicalJob) | Wait-Job -Timeout 120
    Assert-True ($denseJob.State -eq "Completed") "dense rebuild did not complete"
    Assert-True ($lexicalJob.State -eq "Completed") "lexical rebuild did not complete"
    $null = Receive-Job $denseJob
    $null = Receive-Job $lexicalJob
    Assert-True ($duringRebuild.Count -eq $queries.Count) "searches failed during rebuild"
} finally {
    @($denseJob, $lexicalJob) | Remove-Job -Force -ErrorAction SilentlyContinue
}

Write-Host "Testing circuit breaker during repeated lexical failures..."
docker compose stop lexical-index-java | Out-Host
$lastPartial = $null
for ($attempt = 1; $attempt -le 4; $attempt++) {
    $lastPartial = Invoke-Search "POST /ingest"
    Assert-True ($lastPartial.status -eq "partial") "search should degrade to partial while lexical is down"
    Assert-True ($null -ne $lastPartial.source_errors.lexical) "lexical failure was not reported"
}
Assert-True ($lastPartial.source_errors.lexical.type -eq "CircuitOpenError") "circuit breaker did not open"
docker compose start lexical-index-java | Out-Host
Start-Sleep -Seconds 16
Wait-Healthy | Out-Null
$null = Invoke-RestMethod "$baseUrl/lexical/reindex" -Method Post
$recovered = Invoke-Search "POST /ingest"
Assert-True ($null -eq $recovered.source_errors.lexical) "lexical source did not recover after circuit reset"

Write-Host "Testing recovery after index service restart..."
docker compose restart dense-index-cpp lexical-index-java | Out-Host
Wait-Healthy | Out-Null
$null = Invoke-RestMethod "$baseUrl/dense/reindex" -Method Post
$null = Invoke-RestMethod "$baseUrl/lexical/reindex" -Method Post
$afterRestart = Invoke-Search "reingestão incremental"
Assert-True ($afterRestart.results.Count -gt 0) "search did not recover after index restart"

Write-Host "Testing hostile corpus limits..."
Remove-Fixture $hostileFixture
$null = New-Item -ItemType Directory -Path $hostileFixture
Set-Content -LiteralPath (Join-Path $hostileFixture "valid.py") -Value "def safe_fixture(): return 1" -Encoding utf8
[IO.File]::WriteAllText((Join-Path $hostileFixture "oversized.py"), "x" * 1000001)
[IO.File]::WriteAllBytes((Join-Path $hostileFixture "binary.py"), [byte[]](65, 0, 66))
$hostileResult = Invoke-RestMethod "$baseUrl/ingest" -Method Post -ContentType "application/json" -Body '{"root_path":"/workspace/stage13-hostile-fixture"}'
Assert-True ($hostileResult.files_seen -eq 1) "hostile fixture should index only one safe file"

Write-Host "Testing interrupted ingestion rollback..."
Remove-Fixture $interruptFixture
$null = New-Item -ItemType Directory -Path $interruptFixture
for ($index = 0; $index -lt 600; $index++) {
    $fileBody = (("value = '{0}'`n" -f $index) * 30) -join ""
    [IO.File]::WriteAllText((Join-Path $interruptFixture ("file-{0:D4}.py" -f $index)), $fileBody)
}
$client = [Net.Http.HttpClient]::new()
$content = [Net.Http.StringContent]::new('{"root_path":"/workspace/stage13-interrupt-fixture"}', [Text.Encoding]::UTF8, "application/json")
$ingestTask = $client.PostAsync("$baseUrl/ingest", $content)
Start-Sleep -Milliseconds 150
docker compose kill orchestrator-python | Out-Host
$interrupted = $false
try {
    $response = $ingestTask.GetAwaiter().GetResult()
    $interrupted = -not $response.IsSuccessStatusCode
} catch {
    $interrupted = $true
} finally {
    $client.Dispose()
}
Assert-True $interrupted "ingestion completed before interruption; rollback was not exercised"
docker compose up -d --no-build orchestrator-python | Out-Host
Wait-Healthy | Out-Null
$runningCount = docker compose exec -T postgres psql -U rag -d rag -tAc "SELECT count(*) FROM ingestion_runs ir JOIN repositories r ON r.id = ir.repository_id WHERE r.root_path = '/workspace/stage13-interrupt-fixture' AND ir.status = 'running'"
Assert-True ([int]$runningCount.Trim() -eq 0) "interrupted ingestion left a running transaction record"

Write-Host "Testing invalid startup configuration..."
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
docker compose run --rm --no-deps -e MAX_QUERY_CHARS=0 orchestrator-python python -c "from app.config import settings" *> $null
$invalidConfigExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
Assert-True ($invalidConfigExitCode -ne 0) "invalid configuration unexpectedly started"

docker compose exec -T postgres psql -U rag -d rag -c "DELETE FROM repositories WHERE root_path IN ('/workspace/stage13-hostile-fixture', '/workspace/stage13-interrupt-fixture')" | Out-Host
Remove-Fixture $hostileFixture
Remove-Fixture $interruptFixture

$finalHealth = Wait-Healthy
Assert-True ($finalHealth.status -eq "ok") "final health is not ok"
Write-Host "Stage 13 hardening validation passed."
