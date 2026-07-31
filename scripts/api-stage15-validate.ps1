$ErrorActionPreference = "Stop"

$baseUrl = "http://localhost:8090"
$workspace = (Resolve-Path "$PSScriptRoot\..").Path
$alphaPath = Join-Path $workspace "stage15-alpha-fixture"
$betaPath = Join-Path $workspace "stage15-beta-fixture"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Remove-Fixture {
    param([string]$Path)
    $root = [IO.Path]::GetFullPath($workspace)
    $target = [IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($root + [IO.Path]::DirectorySeparatorChar)) {
        throw "refusing to remove fixture outside workspace"
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}

function Invoke-Search {
    param([string]$Endpoint, [hashtable]$Payload)
    Invoke-RestMethod "$baseUrl/$Endpoint" -Method Post -ContentType "application/json" -Body ($Payload | ConvertTo-Json -Depth 6)
}

Write-Host "Stage 15 reusable API validation starting..."
Remove-Fixture $alphaPath
Remove-Fixture $betaPath
$null = New-Item -ItemType Directory -Path (Join-Path $alphaPath "src") -Force
$null = New-Item -ItemType Directory -Path (Join-Path $betaPath "src") -Force
Set-Content -LiteralPath (Join-Path $alphaPath "src/shared.py") -Encoding utf8 -Value "def alpha_unique_symbol():`n    return 'alpha corpus'"
Set-Content -LiteralPath (Join-Path $betaPath "src/shared.py") -Encoding utf8 -Value "def beta_unique_symbol():`n    return 'beta corpus'"

$alphaIngest = Invoke-RestMethod "$baseUrl/ingest" -Method Post -ContentType "application/json" -Body '{"root_path":"/workspace/stage15-alpha-fixture","name":"stage15-alpha"}'
$betaIngest = Invoke-RestMethod "$baseUrl/ingest" -Method Post -ContentType "application/json" -Body '{"root_path":"/workspace/stage15-beta-fixture","name":"stage15-beta"}'
Assert-True ($alphaIngest.chunks_inserted -eq 1 -and $betaIngest.chunks_inserted -eq 1) "multi-corpus ingestion failed"
$embedded = Invoke-RestMethod "$baseUrl/embed" -Method Post -ContentType "application/json" -Body '{}'
Assert-True ($embedded.embedded -ge 2) "fixture embeddings were not created"
$null = Invoke-RestMethod "$baseUrl/dense/reindex" -Method Post
$null = Invoke-RestMethod "$baseUrl/lexical/reindex" -Method Post

Write-Host "Testing v1 corpus filters..."
$alpha = Invoke-Search "v1/search" @{ query = "alpha_unique_symbol"; top_k = 5; use_reranker = $false; filters = @{ corpus = "stage15-alpha" } }
$beta = Invoke-Search "v1/search" @{ query = "beta_unique_symbol"; top_k = 5; use_reranker = $false; filters = @{ corpus = "stage15-beta" } }
Assert-True ($alpha.api_version -eq "v1" -and $beta.api_version -eq "v1") "v1 response version missing"
Assert-True ($alpha.results.Count -gt 0 -and @($alpha.results | Where-Object corpus -ne "stage15-alpha").Count -eq 0) "alpha corpus isolation failed"
Assert-True ($beta.results.Count -gt 0 -and @($beta.results | Where-Object corpus -ne "stage15-beta").Count -eq 0) "beta corpus isolation failed"

Write-Host "Testing path and language filters..."
$filtered = Invoke-Search "v1/search" @{ query = "unique symbol"; top_k = 10; use_reranker = $false; filters = @{ path_prefix = "src/"; language = "python" } }
Assert-True ($filtered.results.Count -gt 0) "path/language filter returned no results"
Assert-True (@($filtered.results | Where-Object { $_.path -notlike "src/*" -or $_.language -ne "python" }).Count -eq 0) "path/language filter leaked results"

Write-Host "Testing legacy client compatibility..."
$legacy = Invoke-Search "search" @{ query = "POST /ingest"; top_k = 5; use_reranker = $false }
Assert-True ($legacy.api_version -eq "v1") "legacy endpoint did not return compatible v1 envelope"
foreach ($field in @("chunk_id", "corpus", "path", "language", "start_line", "end_line", "text", "scores", "source_ranks")) {
    Assert-True ($legacy.results[0].PSObject.Properties.Name -contains $field) "agent metadata field missing: $field"
}

Write-Host "Testing external Python client..."
$clientOutput = & "$workspace\.venv\Scripts\python.exe" -c "from examples.hybrid_rag_client import search; r=search('alpha_unique_symbol', corpus='stage15-alpha'); print(r['api_version'], len(r['results']))"
Assert-True ($LASTEXITCODE -eq 0 -and $clientOutput -match '^v1\s+[1-9]') "external Python client failed: $clientOutput"

Write-Host "Testing same-path IDs across corpora..."
$idCount = docker compose exec -T postgres psql -U rag -d rag -tAc "SELECT count(DISTINCT c.id) FROM chunks c JOIN documents d ON d.id=c.document_id JOIN repositories r ON r.id=d.repository_id WHERE r.name IN ('stage15-alpha','stage15-beta') AND d.path='src/shared.py'"
Assert-True ([int]$idCount.Trim() -eq 2) "same-path chunks collided across corpora"

docker compose exec -T postgres psql -U rag -d rag -c "DELETE FROM repositories WHERE name IN ('stage15-alpha','stage15-beta')" | Out-Host
Remove-Fixture $alphaPath
Remove-Fixture $betaPath
$null = Invoke-RestMethod "$baseUrl/dense/reindex" -Method Post
$null = Invoke-RestMethod "$baseUrl/lexical/reindex" -Method Post
Write-Host "Stage 15 reusable API validation passed."
