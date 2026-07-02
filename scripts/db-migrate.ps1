$ErrorActionPreference = "Stop"

$postgresContainer = docker compose ps -q postgres
if (-not $postgresContainer) {
    throw "Postgres container is not running. Start it with: docker compose up -d postgres"
}

$migrations = Get-ChildItem -LiteralPath "$PSScriptRoot\..\infra\postgres\migrations" -Filter "*.sql" | Sort-Object Name
if (-not $migrations) {
    throw "No migrations found."
}

foreach ($migration in $migrations) {
    Write-Host "Applying migration $($migration.Name)..."
    Get-Content -Raw -LiteralPath $migration.FullName |
        docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U rag -d rag
}

Write-Host "Migrations applied."
