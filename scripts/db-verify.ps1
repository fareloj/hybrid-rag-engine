$ErrorActionPreference = "Stop"

$postgresContainer = docker compose ps -q postgres
if (-not $postgresContainer) {
    throw "Postgres container is not running. Start it with: docker compose up -d postgres"
}

$sql = @"
SELECT extname
FROM pg_extension
WHERE extname = 'vector';

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'schema_migrations',
    'repositories',
    'documents',
    'chunks',
    'embeddings',
    'ingestion_runs',
    'evaluation_runs'
  )
ORDER BY table_name;

SELECT version
FROM schema_migrations
ORDER BY version;
"@

$sql | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U rag -d rag

Write-Host "Postgres schema verification passed."
