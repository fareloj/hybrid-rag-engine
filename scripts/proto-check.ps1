$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$root = Resolve-Path "$PSScriptRoot\.."
$toolPath = Join-Path $root ".tools\python"
$descriptor = Join-Path $root "proto\descriptors\rag_v1_retrieval.pb"
$generated = Join-Path $root "services\orchestrator-python\app\generated"

if (-not (Test-Path $toolPath)) {
    & (Join-Path $root "scripts\proto-generate.ps1")
}

if (-not (Test-Path $descriptor)) {
    throw "Missing descriptor: $descriptor. Run scripts\proto-generate.ps1."
}

if (-not (Test-Path (Join-Path $generated "rag\v1\retrieval_pb2.py"))) {
    throw "Missing generated Python protobuf stubs. Run scripts\proto-generate.ps1."
}

$env:PYTHONPATH = "$toolPath;$generated"
$python = "C:\Users\danie\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path $python)) {
    $python = (Get-Command python -ErrorAction Stop).Source
}
& $python -B -c "from rag.v1 import retrieval_pb2, retrieval_pb2_grpc; request = retrieval_pb2.SearchRequest(query='health', top_k=3); assert request.query == 'health'; assert retrieval_pb2.DESCRIPTOR.services_by_name['DenseIndexService'].full_name == 'rag.v1.DenseIndexService'; assert hasattr(retrieval_pb2_grpc, 'HybridSearchServiceServicer')"

Write-Host "Proto contract check passed."
