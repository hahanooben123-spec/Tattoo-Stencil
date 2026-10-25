$pairing = Join-Path (Split-Path $PSScriptRoot -Parent) ".tools/local-stencil/runtime/pairing.html"
if (-not (Test-Path -LiteralPath $pairing)) { throw "Start Stencil PC first." }
Start-Process -FilePath $pairing
