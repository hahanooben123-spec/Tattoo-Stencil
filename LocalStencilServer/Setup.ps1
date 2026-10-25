param([string]$Python = "py")
$ErrorActionPreference = "Stop"
$project = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $project
try {
    $venvPython = Join-Path $project ".tools/local-stencil/venv/Scripts/python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) {
        if ($Python -eq "py") { & $Python -3.12 -m venv .tools/local-stencil/venv }
        else { & $Python -m venv .tools/local-stencil/venv }
        if ($LASTEXITCODE -ne 0) { throw "Install Python 3.12 or pass -Python C:\path\python.exe." }
    }
    & $venvPython -m pip install torch==2.11.0+cu128 --index-url https://download.pytorch.org/whl/cu128
    if ($LASTEXITCODE -ne 0) { throw "CUDA PyTorch installation failed." }
    & $venvPython -m pip install -r LocalStencilServer/requirements.txt
    if ($LASTEXITCODE -ne 0) { throw "Server dependency installation failed." }
    & $venvPython -m LocalStencilServer.download_model
    if ($LASTEXITCODE -ne 0) { throw "Model download/verification failed." }
    Write-Host "Ready. Run LocalStencilServer/Start.ps1."
} finally { Pop-Location }
