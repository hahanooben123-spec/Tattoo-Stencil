# Run as Administrator after starting Stencil PC, on a network you trust.
$ErrorActionPreference = "Stop"
$project = Split-Path $PSScriptRoot -Parent
$runtime = Join-Path $project ".tools/local-stencil/runtime"
$config = Get-Content -LiteralPath (Join-Path $runtime "credentials.json") -Raw | ConvertFrom-Json
$stencilAddress = [string]$config.address
$interface = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq $stencilAddress } | Select-Object -First 1
if (-not $interface) { throw "PC address changed. Restart Stencil PC and pair again." }
$network = Get-NetConnectionProfile -InterfaceIndex $interface.InterfaceIndex
if ($network.NetworkCategory -eq 'DomainAuthenticated') { throw "Ask your network administrator to allow local TCP 8765." }
$listener = Get-NetTCPConnection -LocalPort 8765 -State Listen | Where-Object { $_.LocalAddress -eq $stencilAddress } | Select-Object -First 1
if (-not $listener) { throw "Start Stencil PC on port 8765 first." }
$program = (Get-Process -Id $listener.OwningProcess).Path
if ([IO.Path]::GetFileName($program) -ne 'python.exe') { throw "Port 8765 is not the Python stencil server." }
$process = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
if ($process.CommandLine -notlike '*-m LocalStencilServer.run*') { throw "Port 8765 belongs to a different Python process." }
$network | Set-NetConnectionProfile -NetworkCategory Private
$rule = Get-NetFirewallRule -Name 'StencilStudioLocalPC' -ErrorAction SilentlyContinue
if ($rule) { $rule | Remove-NetFirewallRule }
New-NetFirewallRule -Name 'StencilStudioLocalPC' -DisplayName 'Stencil Studio local PC' -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort 8765 -LocalAddress $stencilAddress -RemoteAddress LocalSubnet `
    -Profile Private -Program $program | Out-Null
@{success=$true;address=$stencilAddress;port=8765;profile='Private';remote='LocalSubnet'} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtime "lan-enabled.json") -Encoding UTF8
