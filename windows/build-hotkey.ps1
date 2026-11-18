param([string]$OutputPath = 'ClipBridgeHotkey.exe')
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if (![IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $PSScriptRoot $OutputPath }
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) {
        cl.exe /nologo /std:c++17 /EHsc /W4 /O2 /MT ClipBridgeHotkey.cpp "/Fe:$OutputPath" user32.lib shell32.lib ole32.lib uuid.lib gdi32.lib d2d1.lib dwrite.lib dwmapi.lib /link /SUBSYSTEM:WINDOWS
    } elseif (Get-Command g++.exe -ErrorAction SilentlyContinue) {
        g++.exe -std=c++17 -finput-charset=UTF-8 -Wall -Wextra -O2 -municode -mwindows -static ClipBridgeHotkey.cpp -lshell32 -luser32 -lole32 -luuid -lgdi32 -ld2d1 -ldwrite -ldwmapi -o "$OutputPath"
    } else { throw 'Run from a Visual Studio developer prompt or an existing MinGW environment.' }
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
} finally { Pop-Location }
