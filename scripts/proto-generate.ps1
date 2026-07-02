$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

function Resolve-PythonWithPip {
    $candidates = @()
    if ($env:PYTHON_WITH_PIP) {
        $candidates += $env:PYTHON_WITH_PIP
    }
    $candidates += "C:\Users\danie\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCommand) {
        $candidates += $pythonCommand.Source
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) {
            continue
        }
        if (-not (Test-Path $candidate)) {
            continue
        }
        & $candidate -m pip --version *> $null
        if ($LASTEXITCODE -eq 0) {
            return $candidate
        }
    }

    throw "Could not find a Python executable with pip. Set PYTHON_WITH_PIP to a valid python.exe."
}

$root = Resolve-Path "$PSScriptRoot\.."
$toolPath = Join-Path $root ".tools\python"
$pythonOut = Join-Path $root "services\orchestrator-python\app\generated"
$descriptorOut = Join-Path $root "proto\descriptors"
$python = Resolve-PythonWithPip

if (-not (Test-Path $toolPath)) {
    New-Item -ItemType Directory -Force $toolPath | Out-Null
    & $python -m pip install --target $toolPath -r (Join-Path $root "tools\proto-requirements.txt")
}

New-Item -ItemType Directory -Force $pythonOut | Out-Null
New-Item -ItemType Directory -Force $descriptorOut | Out-Null

$protoFile = Join-Path $root "proto\rag\v1\retrieval.proto"
$protoRoot = Join-Path $root "proto"
$descriptorFile = Join-Path $descriptorOut "rag_v1_retrieval.pb"

$env:PYTHONPATH = $toolPath
& $python -m grpc_tools.protoc `
    "-I$protoRoot" `
    --python_out=$pythonOut `
    --grpc_python_out=$pythonOut `
    --descriptor_set_out=$descriptorFile `
    --include_imports `
    $protoFile

if ($LASTEXITCODE -ne 0) {
    throw "grpc_tools.protoc failed with exit code $LASTEXITCODE"
}

$packageDirs = @(
    $pythonOut,
    (Join-Path $pythonOut "rag"),
    (Join-Path $pythonOut "rag\v1")
)

foreach ($directory in $packageDirs) {
    New-Item -ItemType Directory -Force $directory | Out-Null
    $initFile = Join-Path $directory "__init__.py"
    if (-not (Test-Path $initFile)) {
        New-Item -ItemType File -Force $initFile | Out-Null
    }
}

Write-Host "Proto stubs generated in $pythonOut"
Write-Host "Descriptor generated in $descriptorOut"
