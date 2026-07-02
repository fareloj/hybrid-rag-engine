$ErrorActionPreference = "Stop"

$postgresContainer = docker compose ps -q postgres
if (-not $postgresContainer) {
    throw "Postgres container is not running. Start it with: docker compose up -d postgres"
}

$sql = @"
BEGIN;

INSERT INTO repositories(id, name, root_path)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'fixture',
    '/tmp/fixture'
);

INSERT INTO documents(id, repository_id, path, language, content_hash, size_bytes)
VALUES (
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000001',
    'src/main.py',
    'python',
    'hash-1',
    42
);

INSERT INTO chunks(id, document_id, chunk_index, start_line, end_line, text, metadata)
VALUES
    (
        '00000000-0000-0000-0000-000000000003',
        '00000000-0000-0000-0000-000000000002',
        0,
        1,
        3,
        'def search(query): return query',
        '{"symbol":"search"}'::jsonb
    ),
    (
        '00000000-0000-0000-0000-000000000004',
        '00000000-0000-0000-0000-000000000002',
        1,
        4,
        6,
        'def unrelated(): return None',
        '{"symbol":"unrelated"}'::jsonb
    );

INSERT INTO embeddings(chunk_id, model, dimensions, embedding)
VALUES
    ('00000000-0000-0000-0000-000000000003', 'test-model', 3, '[1,0,0]'::vector),
    ('00000000-0000-0000-0000-000000000004', 'test-model', 3, '[0,1,0]'::vector);

UPDATE chunks
SET metadata = metadata || '{"updated":"true"}'::jsonb
WHERE id = '00000000-0000-0000-0000-000000000003';

DO `$`$
DECLARE
    metadata_count INTEGER;
    nearest_chunk UUID;
    remaining_chunks INTEGER;
BEGIN
    SELECT count(*)
    INTO metadata_count
    FROM chunks
    WHERE metadata @> '{"symbol":"search","updated":"true"}'::jsonb;

    IF metadata_count != 1 THEN
        RAISE EXCEPTION 'metadata query failed, expected 1 row, got %', metadata_count;
    END IF;

    SELECT chunk_id
    INTO nearest_chunk
    FROM embeddings
    WHERE model = 'test-model'
    ORDER BY embedding <=> '[1,0,0]'::vector
    LIMIT 1;

    IF nearest_chunk != '00000000-0000-0000-0000-000000000003'::uuid THEN
        RAISE EXCEPTION 'vector baseline failed, got %', nearest_chunk;
    END IF;

    DELETE FROM documents
    WHERE id = '00000000-0000-0000-0000-000000000002';

    SELECT count(*)
    INTO remaining_chunks
    FROM chunks
    WHERE document_id = '00000000-0000-0000-0000-000000000002';

    IF remaining_chunks != 0 THEN
        RAISE EXCEPTION 'cascade delete failed, remaining chunks %', remaining_chunks;
    END IF;
END
`$`$;

ROLLBACK;
"@

$sql | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U rag -d rag

Write-Host "Postgres smoke test passed."
