#!/bin/bash
# Stop the Spug development stack started by dev-start.ps1.
# Matches only processes whose command line belongs to this project, so unrelated Python
# and Node processes are left alone.

powershell.exe -NoProfile -Command "
  Get-CimInstance Win32_Process | Where-Object {
    \$_.CommandLine -match 'manage\.py (runserver|runworker|runscheduler|runmonitor)' -or
    \$_.CommandLine -match 'dev-web\.cjs|react-app-rewired'
  } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue; \"stopped \$(\$_.ProcessId)\" }
" 2>/dev/null | grep stopped || echo 'nothing running'
