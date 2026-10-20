#!/bin/bash
# Wrapper for Git Bash users. The real launcher is dev-start.ps1 - detaching services
# from bash leaves orphaned children with a corrupted environment block on Windows.
exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(dirname "${BASH_SOURCE[0]}")/dev-start.ps1"
