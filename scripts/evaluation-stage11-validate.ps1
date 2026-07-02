$ErrorActionPreference = "Stop"

function Invoke-JsonPost($Url, $Body) {
    return Invoke-RestMethod -Method Post -Uri $Url -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 30)
}

function Assert-Modes($Evaluation) {
    $required = @("dense_cpp", "pgvector", "bm25", "rrf", "rerank")
    foreach ($mode in $required) {
        if ($Evaluation.modes -notcontains $mode) {
            throw "Missing evaluation mode: $mode"
        }
        $metrics = $Evaluation.aggregate.$mode
        foreach ($metric in @("recall_at_k", "mrr", "ndcg_at_k", "latency_ms")) {
            if ($null -eq $metrics.$metric) {
                throw "Missing aggregate metric $metric for $mode"
            }
        }
    }
}

function Assert-PerQuery($Evaluation) {
    foreach ($query in $Evaluation.per_query) {
        if (-not $query.expected -or $query.expected.Count -lt 1) {
            throw "Query $($query.id) has no expected labels"
        }
        foreach ($mode in $Evaluation.modes) {
            $modeMetrics = $query.modes.$mode
            if ($null -eq $modeMetrics) {
                throw "Query $($query.id) missing metrics for $mode"
            }
            if ($modeMetrics.top_paths.Count -lt 1) {
                throw "Query $($query.id) mode $mode returned no paths"
            }
        }
    }
}

function Write-Report($Evaluation, $JsonPath, $MarkdownPath) {
    New-Item -ItemType Directory -Force -Path (Split-Path $JsonPath) | Out-Null
    $Evaluation | ConvertTo-Json -Depth 40 | Set-Content -Encoding UTF8 $JsonPath

    $lines = @()
    $lines += "# Stage 11 Curated Evaluation"
    $lines += ""
    $lines += "- top_k: $($Evaluation.top_k)"
    $lines += "- query_count: $($Evaluation.query_count)"
    $lines += "- modes: $($Evaluation.modes -join ', ')"
    $lines += ""
    $lines += "| Mode | recall@$($Evaluation.top_k) | MRR | nDCG@$($Evaluation.top_k) | Avg latency ms |"
    $lines += "|---|---:|---:|---:|---:|"
    foreach ($mode in $Evaluation.modes) {
        $metrics = $Evaluation.aggregate.$mode
        $lines += "| $mode | $([math]::Round($metrics.recall_at_k, 4)) | $([math]::Round($metrics.mrr, 4)) | $([math]::Round($metrics.ndcg_at_k, 4)) | $([math]::Round($metrics.latency_ms, 2)) |"
    }
    $lines += ""
    $lines += "## Queries"
    foreach ($query in $Evaluation.per_query) {
        $lines += ""
        $lines += "### $($query.id)"
        $lines += "- query: ``$($query.query)``"
        $lines += "- expected: $((@($query.expected) | ForEach-Object { $_.path }) -join ', ')"
        foreach ($mode in $Evaluation.modes) {
            $metrics = $query.modes.$mode
            $lines += "- ${mode}: recall=$([math]::Round($metrics.recall_at_k, 4)), mrr=$([math]::Round($metrics.mrr, 4)), ndcg=$([math]::Round($metrics.ndcg_at_k, 4)), latency_ms=$([math]::Round($metrics.latency_ms, 2))"
        }
    }
    $lines | Set-Content -Encoding UTF8 $MarkdownPath
}

Write-Host "Stage 11 curated evaluation validation starting..."

$unit = @'
from app.evaluation import mrr, ndcg_at_k, overlap, recall_at_k

expected = [{"path": "a.py"}, {"path": "b.py"}]
results = [{"path": "x.py", "chunk_id": "x"}, {"path": "a.py", "chunk_id": "a"}, {"path": "b.py", "chunk_id": "b"}]
assert recall_at_k(results, expected, 3) == 1.0
assert recall_at_k(results, expected, 1) == 0.0
assert mrr(results, expected) == 0.5
assert 0.0 < ndcg_at_k(results, expected, 3) < 1.0
assert ndcg_at_k([{"path": "a.py"}, {"path": "a.py"}], [{"path": "a.py"}], 2) == 1.0
assert overlap([{"chunk_id": "a"}, {"chunk_id": "b"}], [{"chunk_id": "b"}, {"chunk_id": "c"}], 2) == 1 / 3
assert recall_at_k([], expected, 5) == 0.0
assert mrr([], expected) == 0.0
assert ndcg_at_k([], expected, 5) == 0.0
assert overlap([], [], 5) == 0.0
print("Evaluation unit tests passed.")
'@
$unit | docker compose exec -T orchestrator-python python -
if ($LASTEXITCODE -ne 0) {
    throw "Evaluation unit tests failed"
}

Invoke-JsonPost "http://localhost:8090/ingest" @{
    root_path = "/workspace"
    name = "gpt"
} | Out-Null
Invoke-JsonPost "http://localhost:8090/embed" @{
    limit = 10000
} | Out-Null
Invoke-JsonPost "http://localhost:8090/dense/reindex" @{} | Out-Null
Invoke-JsonPost "http://localhost:8090/lexical/reindex" @{} | Out-Null

$first = Invoke-JsonPost "http://localhost:8090/evaluate" @{
    top_k = 5
    include_reranker = $true
}
if ($first.status -ne "succeeded") {
    throw "Evaluation did not succeed"
}
Assert-Modes $first
Assert-PerQuery $first

$second = Invoke-JsonPost "http://localhost:8090/evaluate" @{
    top_k = 5
    include_reranker = $true
}
Assert-Modes $second
if ($first.query_count -ne $second.query_count -or ($first.modes -join ",") -ne ($second.modes -join ",")) {
    throw "Evaluation is not structurally reproducible"
}

$denseOverlapValues = @($first.per_query | ForEach-Object { $_.overlap.dense_cpp_vs_pgvector })
if (($denseOverlapValues | Measure-Object -Minimum).Minimum -lt 0) {
    throw "Invalid overlap metric"
}

$reportJson = "reports/stage11-curated-evaluation.json"
$reportMarkdown = "reports/stage11-curated-evaluation.md"
Write-Report $first $reportJson $reportMarkdown

$savedRuns = docker compose exec -T postgres psql -U rag -d rag -t -A -c "SELECT count(*) FROM evaluation_runs WHERE name = 'curated-stage11';"
if ([int]$savedRuns.Trim() -lt 2) {
    throw "Expected persisted evaluation_runs rows"
}

Write-Host "Stage 11 curated evaluation validation passed. Reports: $reportJson, $reportMarkdown"
