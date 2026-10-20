# Starts the Spug development stack on Windows.
#   powershell -ExecutionPolicy Bypass -File tools\dev-start.ps1
#
# Uses Start-Process rather than a shell background job: a bash `( cmd & )` orphan on
# Windows inherits a broken environment block, which surfaces as unrelated failures
# (MemoryError mid-import, git.exe 0xC0000135 DLL not found).
#
# The web dev server is started through tools\dev-web.cjs, which keeps a stdin pipe
# open for it - react-scripts 3.x calls process.exit() the moment stdin reports EOF.

$ErrorActionPreference = 'Stop'

$Api = Split-Path -Parent $PSScriptRoot
$Logs = Join-Path $Api 'logs'
$Py = Join-Path $Api 'venv\Scripts\python.exe'

New-Item -ItemType Directory -Force -Path $Logs | Out-Null

if (-not (Test-Path $Py)) {
    Write-Error "venv missing at $Py - create it first: python -m venv venv; venv\Scripts\pip install -r requirements-win.txt; venv\Scripts\python tools\install_ldap_stub.py"
}

try {
    $ping = & redis-cli ping 2>$null
    if ($ping -ne 'PONG') { throw 'not answering' }
} catch {
    Write-Error 'Redis is not reachable on 127.0.0.1:6379. Start it: net start Redis'
}

function Start-Svc {
    param($Name, $FilePath, $Arguments, $WorkingDirectory)

    $out = Join-Path $Logs "$Name.log"
    $err = Join-Path $Logs "$Name.err"
    Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory `
        -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err | Out-Null
    Write-Host "  started $Name -> $out"
}

Write-Host 'Starting backend services...'
Start-Svc api       $Py @('manage.py', 'runserver', '0.0.0.0:8000', '--noreload') $Api
Start-Svc worker    $Py @('manage.py', 'runworker') $Api
Start-Svc scheduler $Py @('manage.py', 'runscheduler') $Api
Start-Svc monitor   $Py @('manage.py', 'runmonitor') $Api

Write-Host 'Starting web dev server on :3000 (first compile ~1-2 min)...'
# dev-web.cjs owns logs\web.log / logs\web.err for the dev server itself; these two
# files only capture launcher-level failures.
Start-Svc web-launcher 'node.exe' @((Join-Path $PSScriptRoot 'dev-web.cjs')) $Api

Write-Host ''
Write-Host 'Open http://127.0.0.1:3000/  (admin / admin123)'
