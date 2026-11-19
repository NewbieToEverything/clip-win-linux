param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$SshHost = 'linux'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:entries = [System.Collections.Generic.List[object]]::new()
$script:payloads = [System.Collections.Generic.List[byte[]]]::new()
$script:totalBytes = 0L
$script:ssh = $null
$script:sshError = $null
$script:displayName = ''

function Write-AgentLine([string]$value) {
    [Console]::Out.WriteLine($value)
    [Console]::Out.Flush()
}

function Write-Status([string]$stage) { Write-AgentLine "STATUS $stage" }

function Read-Exact($stream, [int]$count) {
    $buffer = [byte[]]::new($count)
    $offset = 0
    while ($offset -lt $count) {
        $read = $stream.Read($buffer, $offset, $count - $offset)
        if ($read -le 0) { throw 'SSH channel closed before a complete response.' }
        $offset += $read
    }
    return ,$buffer
}

function Read-Frame($stream) {
    $lengthBytes = Read-Exact $stream 4
    [Array]::Reverse($lengthBytes)
    $length = [BitConverter]::ToUInt32($lengthBytes, 0)
    if ($length -lt 2 -or $length -gt 1MB) { throw 'Invalid server frame length.' }
    $bytes = Read-Exact $stream ([int]$length)
    return [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
}

function Stop-SshChannel {
    if ($null -ne $script:ssh) {
        try { if (!$script:ssh.HasExited) { $script:ssh.Kill(); [void]$script:ssh.WaitForExit(1000) } } catch {}
        $script:ssh.Dispose()
        $script:ssh = $null
    }
    if ($null -ne $script:sshError) { $script:sshError.Dispose(); $script:sshError = $null }
}

function Start-SshChannel {
    Stop-SshChannel
    $sshExe = (Get-Command ssh.exe -CommandType Application).Source
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $sshExe
    $start.Arguments = "-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 $SshHost ~/.local/bin/clipbridge serve --stdio"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $script:ssh = [Diagnostics.Process]::new()
    $script:ssh.StartInfo = $start
    if (!$script:ssh.Start()) { throw 'Could not start OpenSSH.' }
    $script:sshError = $script:ssh.StandardError.ReadToEndAsync()
    $ready = Read-Frame $script:ssh.StandardOutput.BaseStream
    if ($ready.ok -isnot [bool] -or !$ready.ok -or $ready.version -ne 1 -or
        $ready.status -cne 'ready' -or $ready.workspace -notin @('workspace-a', 'workspace-b')) {
        throw 'Debian receiver did not return a valid ready frame.'
    }
    return $ready.workspace
}

function Add-FileEntry([string]$path, [string]$relative, [int]$rootIndex, [string]$kind, [string]$origin) {
    if ($script:entries.Count -ge 200) { throw 'Selection exceeds 200 files or directory entries.' }
    $attributes = [IO.File]::GetAttributes($path)
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Links and junctions are not supported.' }
    $name = [IO.Path]::GetFileName($relative)
    $source = [IO.File]::OpenRead($path)
    try {
        $size = $source.Length
        if ($size -gt 128MB) { throw 'A file exceeds the 128 MiB limit.' }
        if ($script:totalBytes + $size -gt 256MB) { throw 'The selection exceeds the 256 MiB limit.' }
        [byte[]]$bytes = [byte[]]::new([int]$size)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $source.Read($bytes, $offset, $bytes.Length - $offset)
            if ($count -eq 0) { throw 'A file became shorter while it was being read.' }
            $offset += $count
        }
    } finally {
        $source.Dispose()
    }
    $script:totalBytes += $bytes.LongLength
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $script:entries.Add([pscustomobject]@{
        source_name = $name; source_relpath = $relative.Replace('\', '/');
        source_root_index = $rootIndex; entry_type = 'file'; size = $bytes.LongLength;
        sha256 = $hash; kind = $kind; origin = $origin
    })
    $script:payloads.Add($bytes)
}

function Add-DirectoryEntry([string]$path, [string]$relative, [int]$rootIndex, [int]$depth = 1) {
    if ($depth -gt 32) { throw 'Folder nesting exceeds 32 levels.' }
    if ($script:entries.Count -ge 200) { throw 'Selection exceeds 200 files or directory entries.' }
    $attributes = [IO.File]::GetAttributes($path)
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Links and junctions are not supported.' }
    $script:entries.Add([pscustomobject]@{
        source_name = [IO.Path]::GetFileName($relative.TrimEnd('\'));
        source_relpath = $relative.Replace('\', '/'); source_root_index = $rootIndex;
        entry_type = 'directory'; size = 0; sha256 = $null; kind = 'files'; origin = 'explorer'
    })
    foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($path)) {
        if ($script:entries.Count -ge 200) { throw 'Selection exceeds 200 files or directory entries.' }
        $childName = [IO.Path]::GetFileName($child)
        $childRelative = $relative + '\' + $childName
        $childAttributes = [IO.File]::GetAttributes($child)
        if ($childAttributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Links and junctions are not supported.' }
        if ($childAttributes -band [IO.FileAttributes]::Directory) {
            Add-DirectoryEntry $child $childRelative $rootIndex ($depth + 1)
        } else {
            Add-FileEntry $child $childRelative $rootIndex 'files' 'explorer'
        }
    }
}

function Build-Request {
    $script:entries.Clear()
    $script:payloads.Clear()
    $script:totalBytes = 0L
    $clipboard = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $drop = [Windows.Forms.Clipboard]::GetFileDropList()
            if ($drop.Count -gt 0) { $clipboard = @($drop); break }
            $clipboard = [Windows.Forms.Clipboard]::GetImage()
            break
        } catch [Runtime.InteropServices.ExternalException] {
            if ($attempt -eq 4) { throw }
            Start-Sleep -Milliseconds 60
        }
    }
    if ($null -eq $clipboard) { throw 'Clipboard contains no image or file list.' }
    if ($clipboard -is [Drawing.Image]) {
        Write-Status 'encoding'
        if ([long]$clipboard.Width * $clipboard.Height -gt 25000000) { throw 'Image exceeds 25 megapixels.' }
        $memory = [IO.MemoryStream]::new()
        try { $clipboard.Save($memory, [Drawing.Imaging.ImageFormat]::Png); [byte[]]$bytes = $memory.ToArray() }
        finally { $memory.Dispose(); $clipboard.Dispose() }
        if ($bytes.LongLength -gt 15MB) { throw 'PNG exceeds 15 MiB.' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $requestName = 'screenshot-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.png'
        $script:entries.Add([pscustomobject]@{
            source_name = $requestName; source_relpath = $requestName; source_root_index = 1;
            entry_type = 'file'; size = $bytes.LongLength; sha256 = $hash;
            kind = 'image'; origin = 'clipboard_bitmap'
        })
        $script:payloads.Add($bytes)
        $script:totalBytes = $bytes.LongLength
        $script:displayName = $requestName
        return 'image'
    }
    Write-Status 'packing'
    $rootIndex = 0
    foreach ($selected in $clipboard) {
        $rootIndex++
        $trimmed = $selected.TrimEnd('\')
        $name = [IO.Path]::GetFileName($trimmed)
        if (!$name) { throw 'Drive roots are unsupported.' }
        $attributes = [IO.File]::GetAttributes($selected)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Links and junctions are not supported.' }
        if ($attributes -band [IO.FileAttributes]::Directory) {
            Add-DirectoryEntry $selected $name $rootIndex
        } else {
            Add-FileEntry $selected $name $rootIndex 'files' 'explorer'
        }
    }
    $script:displayName = if ($script:entries.Count -eq 1) {
        [string]$script:entries[0].source_name
    } else {
        '{0} 个项目' -f @($clipboard).Count
    }
    return 'files'
}

function Send-Request {
    Write-Status 'reading-clipboard'
    $kind = Build-Request
    if ($script:entries.Count -eq 0) { throw 'Clipboard contains no uploadable items.' }
    $safeDisplayName = [regex]::Replace($script:displayName, '[\x00-\x1F\x7F\u202A-\u202E\u2066-\u2069]', '')
    if ($safeDisplayName.Length -gt 120) { $safeDisplayName = $safeDisplayName.Substring(0, 117) + '…' }
    Write-AgentLine ('NAME ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($safeDisplayName)))
    Write-Status 'connecting'
    if ($null -eq $script:ssh -or $script:ssh.HasExited) {
        $channelWorkspace = Start-SshChannel
        if ($channelWorkspace -cne $script:workspace) { throw 'SSH receiver workspace does not match the configured alias.' }
    }
    $requestId = [Guid]::NewGuid().ToString('N')
    $header = [pscustomobject]@{
        version = 1; request_id = $requestId; workspace = $script:workspace;
        kind = $kind; file_count = $script:entries.Count; entries = @($script:entries.ToArray())
    }
    $json = ConvertTo-Json -InputObject $header -Depth 12 -Compress
    $headerBytes = [Text.Encoding]::UTF8.GetBytes($json)
    if ($headerBytes.Length -gt 1MB) { throw 'Transfer metadata exceeds 1 MiB.' }
    $receipt = $null
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        if ($null -eq $script:ssh -or $script:ssh.HasExited) {
            Write-Status 'reconnecting'
            $channelWorkspace = Start-SshChannel
            if ($channelWorkspace -cne $script:workspace) { throw 'SSH receiver workspace mismatch.' }
        }
        try {
            $stream = $script:ssh.StandardInput.BaseStream
            $stream.Write([Text.Encoding]::ASCII.GetBytes('CBR5'), 0, 4)
            $lengthBytes = [BitConverter]::GetBytes([uint32]$headerBytes.Length)
            [Array]::Reverse($lengthBytes)
            $stream.Write($lengthBytes, 0, 4)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $sent = 0L
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $lastReported = 0L
            foreach ($bytes in $script:payloads) {
                for ($offset = 0; $offset -lt $bytes.Length; $offset += 65536) {
                    $count = [Math]::Min(65536, $bytes.Length - $offset)
                    $stream.Write($bytes, $offset, $count)
                    $sent += $count
                    if ($clock.ElapsedMilliseconds - $lastReported -ge 250 -or $sent -eq $script:totalBytes) {
                        Write-AgentLine ("PROGRESS {0} {1}" -f $sent, $script:totalBytes)
                        $lastReported = $clock.ElapsedMilliseconds
                    }
                }
            }
            $stream.Flush()
            Write-Status 'verifying'
            $receipt = Read-Frame $script:ssh.StandardOutput.BaseStream
            break
        } catch {
            Stop-SshChannel
            if ($attempt -eq 1) { throw 'SSH channel failed twice. Server may have committed the request; retry safely.' }
            Write-Status 'reconnecting'
        }
    }
    if ($receipt.ok -isnot [bool] -or !$receipt.ok) {
        $message = if ($receipt.error) { [string]$receipt.error } else { 'Debian rejected the transfer.' }
        throw $message
    }
    if ($receipt.version -ne 2 -or $receipt.request_id -cne $requestId -or
        $receipt.workspace -cne $script:workspace -or $receipt.count -lt 1 -or
        @($receipt.paths).Count -ne $receipt.count -or @($receipt.entries).Count -ne $script:entries.Count -or
        $receipt.batch_id -cnotmatch '^\d{8}T\d{6}Z-[a-f0-9]{32}$') {
        throw 'Server receipt does not match the transfer.'
    }
    $batchId = [regex]::Escape($receipt.batch_id)
    $prefix = "^/.+/.local/share/clipbridge/$([regex]::Escape($script:workspace))/batches/$batchId/payload/items/[0-9]{4}/.+\z"
    foreach ($path in $receipt.paths) {
        if ($path -isnot [string] -or $path -cnotmatch $prefix -or $path.Contains('\') -or
            $path -match '/\.\.?(/|$)' -or $path -match '[\r\n\x00-\x1F\x7F]') {
            throw 'Debian returned an invalid path.'
        }
    }
    foreach ($index in 0..($script:entries.Count - 1)) {
        $expected = $script:entries[$index]
        $received = $receipt.entries[$index]
        if ($received.source_relpath -cne $expected.source_relpath -or
            $received.source_name -cne $expected.source_name -or
            $received.sha256 -cne $expected.sha256 -or $received.renamed -ne $false) {
            throw 'Debian receipt does not preserve the submitted source names and hashes.'
        }
    }
    return @($receipt.paths) -join ' '
}

try {
    $sshConfig = (Get-Command ssh.exe -CommandType Application).Source
    $probe = [Diagnostics.ProcessStartInfo]::new()
    $probe.FileName = $sshConfig
    $probe.Arguments = "-G $SshHost"
    $probe.UseShellExecute = $false
    $probe.RedirectStandardOutput = $true
    $probe.RedirectStandardError = $true
    $probeProcess = [Diagnostics.Process]::Start($probe)
    $probeOutput = $probeProcess.StandardOutput.ReadToEnd()
    $probeError = $probeProcess.StandardError.ReadToEnd()
    $probeProcess.WaitForExit()
    if ($probeProcess.ExitCode -ne 0) { throw 'Could not resolve the configured OpenSSH alias.' }
    $mapped = [regex]::Matches($probeOutput, '(?m)^setenv\s+CLIPBRIDGE_WS=(workspace-[ab])\s*$')
    if ($mapped.Count -ne 1) { throw 'SSH alias must declare one valid CLIPBRIDGE_WS.' }
    $script:workspace = $mapped[0].Groups[1].Value
    [void](Start-SshChannel)
    Write-AgentLine 'READY'
    while ($null -ne ($command = [Console]::In.ReadLine())) {
        if ($command -ceq 'STOP') { break }
        if ($command -cne 'UPLOAD') { Write-AgentLine ('ERROR ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('Unknown agent command.'))); continue }
        try {
            $path = Send-Request
            Write-AgentLine ('PATH ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($path)))
        } catch {
            Stop-SshChannel
            $message = [string]$_.Exception.Message
            Write-AgentLine ('ERROR ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message)))
        }
    }
    Stop-SshChannel
} catch {
    Stop-SshChannel
    $message = [string]$_.Exception.Message
    Write-AgentLine ('FATAL ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message)))
    exit 1
}
