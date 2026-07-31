$ErrorActionPreference = "Stop"

Write-Host "Checking Python orchestrator imports..."
Push-Location "$PSScriptRoot\..\services\orchestrator-python"
try {
    python -c "from pathlib import Path; [compile(path.read_text(encoding='utf-8'), str(path), 'exec') for path in [*Path('app').glob('*.py'), *Path('tests').glob('test_*.py')]]"
} finally {
    Pop-Location
}

Write-Host "Checking Python reranker imports..."
Push-Location "$PSScriptRoot\..\services\reranker-python"
try {
    python -c "from pathlib import Path; [compile(path.read_text(encoding='utf-8'), str(path), 'exec') for path in [Path('app/__init__.py'), Path('app/main.py')]]"
} finally {
    Pop-Location
}

Write-Host "Checking proto contract..."
& "$PSScriptRoot\proto-check.ps1"

Write-Host "Checking C++ configure/build..."
if (Get-Command cmake -ErrorAction SilentlyContinue) {
    Push-Location "$PSScriptRoot\..\services\dense-index-cpp"
    try {
        cmake -S . -B build
        cmake --build build
    } finally {
        Pop-Location
    }
} else {
    Write-Warning "Skipping C++ local build: cmake is not installed or not on PATH. Docker build still validates this service."
}

Write-Host "Checking Java compile..."
if (Get-Command mvn -ErrorAction SilentlyContinue) {
    Push-Location "$PSScriptRoot\..\services\lexical-index-java"
    try {
        mvn -q -DskipTests compile
    } finally {
        Pop-Location
    }
} else {
    Write-Warning "Skipping Java local compile: mvn is not installed or not on PATH. Docker build still validates this service."
}

Write-Host "All local checks passed."
