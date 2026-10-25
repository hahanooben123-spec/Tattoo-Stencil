param([string]$Address = "", [int]$Port = 8765)
$ErrorActionPreference = "Stop"
$project = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $project
try {
    $venvPython = Join-Path $project ".tools/local-stencil/venv/Scripts/python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) { throw "Run LocalStencilServer/Setup.ps1 first." }
    $env:HF_HUB_OFFLINE = "1"
    $env:TRANSFORMERS_OFFLINE = "1"
    $env:PYTHONUTF8 = "1"
    $arguments = @("-m", "LocalStencilServer.run", "--port", "$Port")
    if ($Address) { $arguments += @("--address", $Address) }
    & $venvPython @arguments
    if ($LASTEXITCODE -ne 0) { throw "Stencil PC stopped with an error." }
} finally { Pop-Location }
