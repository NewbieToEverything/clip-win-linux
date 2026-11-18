$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) {
        cl.exe /nologo /std:c++17 /EHsc /W4 /O2 /MT ClipBridgeHotkey.cpp user32.lib shell32.lib /link /SUBSYSTEM:WINDOWS
    } elseif (Get-Command g++.exe -ErrorAction SilentlyContinue) {
        g++.exe -std=c++17 -Wall -Wextra -O2 -municode -mwindows -static ClipBridgeHotkey.cpp -lshell32 -luser32 -o ClipBridgeHotkey.exe
    } else { throw 'Run from a Visual Studio developer prompt or an existing MinGW environment.' }
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
} finally { Pop-Location }
