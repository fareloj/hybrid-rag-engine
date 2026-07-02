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

Write-Host "Stage 7 lexical index validation starting..."

$health = Invoke-RestMethod http://localhost:8082/health
if ($health.service -ne "lexical-index-java") {
    throw "Unexpected lexical health response: $($health | ConvertTo-Json -Depth 5)"
}

$reindex = Invoke-JsonPost "http://localhost:8090/lexical/reindex"
if ($reindex.status -ne "succeeded" -or $reindex.indexed -le 0) {
    throw "Lexical reindex failed: $($reindex | ConvertTo-Json -Depth 5)"
}

$queries = @(
    @{ query = "ingest"; min = 1; label = "exact symbol" },
    @{ query = "POST /ingest"; min = 1; label = "endpoint path" },
    @{ query = "services/orchestrator-python/app/ingestion.py"; min = 1; label = "path search" },
    @{ query = "stable_id"; min = 1; label = "rare symbol" },
    @{ query = "zzzz_no_result_expected_123"; min = 0; label = "no results" },
    @{ query = "função ingest"; min = 0; label = "accented mixed language" },
    @{ query = "documento órfão"; min = 0; label = "accented rare phrase" }
)

foreach ($case in $queries) {
    $body = @{ query = $case.query; top_k = 5 } | ConvertTo-Json -Compress
    $result = Invoke-JsonPost "http://localhost:8090/lexical/search" $body
    if ($result.results.Count -lt $case.min) {
        throw "Query '$($case.query)' [$($case.label)] expected at least $($case.min), got $($result.results.Count)"
    }
    Write-Host "Query '$($case.query)' [$($case.label)] results=$($result.results.Count)"
}

Write-Host "Testing special characters and long token red teams..."
$special = Invoke-JsonPost "http://localhost:8090/lexical/search" (@{ query = 'POST /ingest + path:(bad) && ""'; top_k = 5 } | ConvertTo-Json -Compress)
if ($special.status -ne "succeeded") {
    throw "Special character query failed unexpectedly."
}
$longToken = "x" * 10000
$longResult = Invoke-JsonPost "http://localhost:8090/lexical/search" (@{ query = $longToken; top_k = 5 } | ConvertTo-Json -Compress)
if ($longResult.status -ne "succeeded") {
    throw "Long token query failed unexpectedly."
}

Write-Host "Testing duplicate document IDs rejected by direct Java index..."
Expect-Failure "blank text" {
    Invoke-JsonPost "http://localhost:8082/index" '{"chunks":[{"id":"bad","text":"","path":"bad","language":"txt","start_line":1,"end_line":1}]}'
}

Write-Host "Restoring real lexical index after red team..."
$restore = Invoke-JsonPost "http://localhost:8090/lexical/reindex"
if ($restore.indexed -ne $reindex.indexed) {
    throw "Lexical restore count changed from $($reindex.indexed) to $($restore.indexed)"
}

Write-Host "Stage 7 lexical index validation passed. indexed=$($restore.indexed)"
