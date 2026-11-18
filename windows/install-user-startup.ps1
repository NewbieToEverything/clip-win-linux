param(
    [ValidatePattern('^[A-Za-z0-9_.-]+\.exe$')][string]$AutoPasteTerminal,
    [ValidateRange(1,60)][int]$PasteTimeoutSeconds = 8
)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'ClipBridgeHotkey.exe'
if (!(Test-Path -LiteralPath $exe)) { throw 'Build ClipBridgeHotkey.exe first.' }
$parameters = @{ Execute = $exe; WorkingDirectory = $PSScriptRoot }
if ($AutoPasteTerminal) { $parameters.Argument = "--auto-paste $AutoPasteTerminal --paste-timeout $PasteTimeoutSeconds" }
$action = New-ScheduledTaskAction @parameters
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'ClipBridge Hotkey' -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
