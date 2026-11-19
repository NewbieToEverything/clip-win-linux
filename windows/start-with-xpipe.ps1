$ErrorActionPreference = 'Stop'
$session = (Get-Process -Id $PID).SessionId
$original = Join-Path $PSScriptRoot 'XPipe-original.lnk'
$mutex = [Threading.Mutex]::new($false, "Local\ClipBridge.XPipe.$session")
$ownsMutex = $false
$clip = $null
try {
    Start-Process -FilePath $original
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (!$ownsMutex) { return }

    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $apps = @(Get-Process xpiped -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session)
        if ($apps.Count -eq 1) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($apps.Count -ne 1) { throw 'Cannot identify one XPipe process in this desktop session.' }
    $app = $apps[0]
    $null = $app.Handle
    if ($app.HasExited) { return }

    $action = @( (Get-ScheduledTask -TaskName 'ClipBridge Hotkey').Actions )[0]
    $exe = Join-Path $PSScriptRoot 'ClipBridgeHotkey.exe'
    if ($action.Execute.Trim('"') -ine $exe) { throw 'Unexpected ClipBridge task executable.' }
    if (Get-Process ClipBridgeHotkey -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session) {
        throw 'ClipBridge is already running outside this launcher.'
    }
    $launch = @{FilePath = $exe; WorkingDirectory = $PSScriptRoot; PassThru = $true}
    if ($action.Arguments) { $launch.ArgumentList = $action.Arguments }
    $clip = Start-Process @launch
    $null = $clip.Handle
    $app.WaitForExit()
} finally {
    if ($clip -and !$clip.HasExited) {
        $null = Start-Process -FilePath $clip.Path -ArgumentList '--drain-stop' -Wait -PassThru
        $clip.WaitForExit()
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
