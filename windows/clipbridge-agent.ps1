param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$SshHost = 'linux',
    [ValidateSet('en', 'zh')][string]$UiLanguage = 'en'
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

function Get-DisplayError([string]$message) {
    $zh = $UiLanguage -eq 'zh'
    switch -Exact ($message) {
        'SHA256_MISMATCH' { if ($zh) { return 'Linux 校验失败，文件内容不匹配。' }; return 'Linux checksum verification failed.' }
        'QUOTA_EXCEEDED' { if ($zh) { return 'Linux 接收目录的配额已满。' }; return 'The Linux upload quota was exceeded.' }
        'LOW_DISK_SPACE' { if ($zh) { return 'Linux 磁盘可用空间不足。' }; return 'Linux does not have enough free disk space.' }
        'BATCH_LIMIT_EXCEEDED' { if ($zh) { return 'Linux 拒绝了超过大小限制的内容。' }; return 'Linux rejected the transfer because it exceeds the size limit.' }
        'EXPIRED' { if ($zh) { return '原发送请求已过期，请重新发送。' }; return 'The previous transfer request expired. Send it again.' }
        'REQUEST_ID_CONFLICT' { if ($zh) { return '发送请求 ID 冲突。' }; return 'The transfer request ID conflicts with an earlier request.' }
    }
    switch -Exact ($message) {
        'DOWNLOAD_WRAP_LIMIT' { if ($zh) { return '断行太多，请复制完整的单行路径。' }; return 'Too many line breaks. Copy the complete path on one line.' }
        'DOWNLOAD_WRAP_AMBIGUOUS' { if ($zh) { return '断行可拼成多个有效路径，请重新复制完整路径。' }; return 'The wrapped text matches multiple paths. Copy one complete path.' }
        'DOWNLOAD_WRAP_NOT_FOUND' { if ($zh) { return '未找到断行前的路径，请重新复制完整路径。' }; return 'Could not find the wrapped path. Copy one complete path.' }
        'DOWNLOAD_PATH' { if ($zh) { return '请复制一个 Linux 绝对路径后重试。' }; return 'Copy one absolute Linux path, then try again.' }
        'DOWNLOAD_CLIPBOARD_CHANGED' { if ($zh) { return '剪贴板内容已变化。' }; return 'Clipboard content changed.' }
        'DOWNLOAD_UNSUPPORTED' { if ($zh) { return '请先更新 Linux 接收端。' }; return 'Update the Linux ClipBridge receiver first.' }
        'DOWNLOAD_RESPONSE' { if ($zh) { return 'Linux 回传响应不完整或无效。' }; return 'The Linux transfer-back response was incomplete or invalid.' }
        'DOWNLOAD_CHECKSUM' { if ($zh) { return '回传校验失败。' }; return 'Transfer-back checksum verification failed.' }
        'DOWNLOAD_CHANGED' { if ($zh) { return 'Linux 文件在传输时发生了变化。' }; return 'The Linux file changed during transfer.' }
        'DOWNLOAD_LIMIT' { if ($zh) { return '回传超过文件、目录或大小限制。' }; return 'The transfer back exceeds the file, folder, or size limits.' }
        'DOWNLOAD_TYPE' { if ($zh) { return '只支持普通文件和文件夹。' }; return 'Only regular files and folders are supported.' }
        'DOWNLOAD_NAME_COLLISION' { if ($zh) { return '有两个 Linux 名称在 Windows 上冲突。' }; return 'Two Linux names conflict on Windows.' }
        'DOWNLOAD_NAME' { if ($zh) { return '文件名无法在 Windows 上使用。' }; return 'The name cannot be used on Windows.' }
        'Unsafe source path component' { if ($zh) { return '文件名无法在 Windows 上使用。' }; return 'The name cannot be used on Windows.' }
        'Source path exceeds limits' { if ($zh) { return '回传路径超过限制。' }; return 'The transfer-back path exceeds the limits.' }
        'DOWNLOAD_CACHE' { if ($zh) { return 'Windows 回传缓存目录不可用。' }; return 'The Windows transfer-back cache directory is unavailable.' }
        'FileNotFoundError' { if ($zh) { return 'Linux 路径不存在。' }; return 'The Linux path does not exist.' }
        'NotADirectoryError' { if ($zh) { return 'Linux 路径包含无效目录或符号链接。' }; return 'A Linux path component is not a directory or is a link.' }
        'PermissionError' { if ($zh) { return 'Linux 路径不可读取。' }; return 'The Linux path is not readable.' }
    }
    if (!$zh) { return $message }
    switch -Exact ($message) {
        'Clipboard contains no image or file list.' { return '剪贴板里没有图片或文件。' }
        'Clipboard contains no uploadable items.' { return '剪贴板里没有可发送的项目。' }
        'Selection exceeds 200 files or directory entries.' { return '所选文件和目录总数超过 200 项。' }
        'A file exceeds the 128 MiB limit.' { return '单个文件超过 128 MiB。' }
        'The selection exceeds the 256 MiB limit.' { return '本次发送总大小超过 256 MiB。' }
        'Links and junctions are not supported.' { return '无法发送符号链接或目录联接。' }
        'Drive roots are unsupported.' { return '无法发送整个盘符的根目录。' }
        'Folder nesting exceeds 32 levels.' { return '文件夹嵌套超过 32 层。' }
        'Image exceeds 25 megapixels.' { return '图片超过 2500 万像素。' }
        'PNG exceeds 15 MiB.' { return 'PNG 图片超过 15 MiB。' }
        'A file became shorter while it was being read.' { return '文件在读取时发生了变化。' }
        'No complete receipt from Linux. The remote save status is unknown.' { return '未收到完整的 Linux 回执，无法确认远端是否已保存。' }
        'The Linux receipt could not be read.' { return '无法解析 Linux 回执。' }
        'The SSH connection broke while sending.' { return '发送时 SSH 连接中断。' }
        'Server receipt does not match the transfer.' { return 'Linux 回执与本次发送不匹配。' }
        'Debian returned an invalid path.' { return 'Linux 回执中的路径无效。' }
        'Debian receipt does not preserve the submitted source names and hashes.' { return 'Linux 回执中的文件名或校验值不匹配。' }
        'Debian rejected the transfer.' { return 'Linux 拒绝接收。' }
        'OSError' { return 'Linux 文件读写失败。' }
        default { return $message }
    }
}

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
    $script:downloadSupported = $ready.download -eq $true
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

function Write-DisplayName([string]$name) {
    $safeDisplayName = [regex]::Replace($name, '[\x00-\x1F\x7F\u202A-\u202E\u2066-\u2069]', '')
    if ($safeDisplayName.Length -gt 120) { $safeDisplayName = $safeDisplayName.Substring(0, 117) + '…' }
    Write-AgentLine ('NAME ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($safeDisplayName)))
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
        $requestName = 'screenshot-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.png'
        Write-DisplayName $requestName
        Write-Status 'encoding'
        if ([long]$clipboard.Width * $clipboard.Height -gt 25000000) { throw 'Image exceeds 25 megapixels.' }
        $memory = [IO.MemoryStream]::new()
        try { $clipboard.Save($memory, [Drawing.Imaging.ImageFormat]::Png); [byte[]]$bytes = $memory.ToArray() }
        finally { $memory.Dispose(); $clipboard.Dispose() }
        if ($bytes.LongLength -gt 15MB) { throw 'PNG exceeds 15 MiB.' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $script:entries.Add([pscustomobject]@{
            source_name = $requestName; source_relpath = $requestName; source_root_index = 1;
            entry_type = 'file'; size = $bytes.LongLength; sha256 = $hash;
            kind = 'image'; origin = 'clipboard_bitmap'
        })
        $script:payloads.Add($bytes)
        $script:totalBytes = $bytes.LongLength
        return 'image'
    }
    if (@($clipboard).Count -eq 1) {
        Write-DisplayName ([IO.Path]::GetFileName($clipboard[0].TrimEnd('\')))
    } else {
        $format = if ($UiLanguage -eq 'zh') { '{0} 个项目' } else { '{0} items' }
        Write-DisplayName ($format -f @($clipboard).Count)
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
    return 'files'
}

function Send-Request {
    Write-Status 'reading-clipboard'
    $kind = Build-Request
    if ($script:entries.Count -eq 0) { throw 'Clipboard contains no uploadable items.' }
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
        $awaitingReceipt = $false
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
            if ($script:totalBytes -gt 0) { Write-AgentLine ("PROGRESS 0 {0}" -f $script:totalBytes) }
            foreach ($bytes in $script:payloads) {
                for ($offset = 0; $offset -lt $bytes.Length; $offset += 65536) {
                    $count = [Math]::Min(65536, $bytes.Length - $offset)
                    $stream.Write($bytes, $offset, $count)
                    $sent += $count
                    if ($clock.ElapsedMilliseconds - $lastReported -ge 100 -or $sent -eq $script:totalBytes) {
                        Write-AgentLine ("PROGRESS {0} {1}" -f $sent, $script:totalBytes)
                        $lastReported = $clock.ElapsedMilliseconds
                    }
                }
            }
            $stream.Flush()
            Write-Status 'verifying'
            $awaitingReceipt = $true
            $receipt = Read-Frame $script:ssh.StandardOutput.BaseStream
            break
        } catch {
            Stop-SshChannel
            if ($attempt -eq 1) {
                if (!$awaitingReceipt) { throw 'The SSH connection broke while sending.' }
                if ($_.Exception.Message -eq 'Invalid server frame length.' -or
                    $_.FullyQualifiedErrorId -like '*ConvertFromJson*') {
                    throw 'The Linux receipt could not be read.'
                }
                throw 'No complete receipt from Linux. The remote save status is unknown.'
            }
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

function Receive-Download([uint32]$sequence) {
    if (!('ClipBridgeClipboard' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class ClipBridgeClipboard {
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
}
'@
    }
    if ([ClipBridgeClipboard]::GetClipboardSequenceNumber() -ne $sequence) { throw 'DOWNLOAD_CLIPBOARD_CHANGED' }
    $source = [Windows.Forms.Clipboard]::GetText().Trim()
    if ([ClipBridgeClipboard]::GetClipboardSequenceNumber() -ne $sequence) { throw 'DOWNLOAD_CLIPBOARD_CHANGED' }
    if ($source -cnotmatch '^/[^/]' -or $source -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]' -or
        [Text.Encoding]::UTF8.GetByteCount($source) -gt 4096) { throw 'DOWNLOAD_PATH' }

    Write-Status 'connecting'
    if ($null -eq $script:ssh -or $script:ssh.HasExited) {
        if ((Start-SshChannel) -cne $script:workspace) { throw 'SSH receiver workspace mismatch.' }
    }
    if (!$script:downloadSupported) { throw 'DOWNLOAD_UNSUPPORTED' }
    $request = @{version=1; workspace=$script:workspace; kind='download'; path=$source}
    $body = [Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Compress))
    $length = [BitConverter]::GetBytes([uint32]$body.Length)
    [Array]::Reverse($length)
    $inputStream = $script:ssh.StandardInput.BaseStream
    $outputStream = $script:ssh.StandardOutput.BaseStream
    $magic = [Text.Encoding]::ASCII.GetBytes('CBR5')
    $inputStream.Write($magic, 0, $magic.Length)
    $inputStream.Write($length, 0, $length.Length)
    $inputStream.Write($body, 0, $body.Length)
    $inputStream.Flush()
    $manifest = Read-Frame $outputStream
    if ($manifest.ok -eq $false -and $manifest.error -cmatch '^(DOWNLOAD_[A-Z_]+|Unsafe source path component|Source path exceeds limits|FileNotFoundError|PermissionError|NotADirectoryError|OSError)$') {
        throw ([string]$manifest.error)
    }
    $entries = @($manifest.entries)
    if ($manifest.ok -ne $true -or $manifest.status -cne 'download' -or $entries.Count -lt 1 -or $entries.Count -gt 200) {
        throw 'DOWNLOAD_RESPONSE'
    }

    $paths = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $root = [string]$entries[0].path
    $total = 0L
    foreach ($entry in $entries) {
        $relative = [string]$entry.path
        $parts = $relative.Split('/')
        if ($parts.Count -gt 32 -or $parts[0] -cne $root -or
            $entry.type -cnotin @('file','directory') -or
            ($entry.size -isnot [int] -and $entry.size -isnot [long]) -or
            $entry.size -lt 0 -or $entry.size -gt 128MB -or ($entry.type -ceq 'directory' -and $entry.size -ne 0)) {
            throw 'DOWNLOAD_RESPONSE'
        }
        foreach ($part in $parts) {
            if (!$part -or $part.Length -gt 255 -or $part -match '[<>:"|?*\\\x00-\x1f\x7f]|[. ]$' -or
                $part -match '^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') {
                throw 'DOWNLOAD_NAME'
            }
        }
        if ($paths.ContainsKey($relative)) { throw 'DOWNLOAD_NAME_COLLISION' }
        if ($parts.Count -gt 1) {
            $parent = $relative.Substring(0, $relative.LastIndexOf('/'))
            if (!$paths.ContainsKey($parent) -or $paths[$parent] -cne 'directory') { throw 'DOWNLOAD_RESPONSE' }
        }
        $paths.Add($relative, $entry.type)
        $total += $entry.size
    }
    if ($total -gt 256MB -or $manifest.bytes -ne $total) { throw 'DOWNLOAD_LIMIT' }

    Write-DisplayName $root
    $cache = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ClipBridge\Downloads'
    $null = [IO.Directory]::CreateDirectory($cache)
    foreach ($folder in @($cache, (Split-Path -Parent $cache))) {
        if ([IO.File]::GetAttributes($folder) -band [IO.FileAttributes]::ReparsePoint) { throw 'DOWNLOAD_CACHE' }
    }
    $id = [Guid]::NewGuid().ToString('N')
    $stage = Join-Path $cache ($id + '.partial')
    $destination = Join-Path $cache $id
    $hashes = [Collections.Generic.List[string]]::new()
    $null = [IO.Directory]::CreateDirectory($stage)
    try {
        $done = 0L
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if ($total -gt 0) { Write-AgentLine "PROGRESS 0 $total" }
        foreach ($entry in $entries) {
            $target = Join-Path $stage ($entry.path.Replace('/', '\'))
            if ($entry.type -ceq 'directory') {
                $null = [IO.Directory]::CreateDirectory($target)
                continue
            }
            $hash = [Security.Cryptography.SHA256]::Create()
            try {
                $file = [IO.File]::Open($target, [IO.FileMode]::CreateNew)
                try {
                    $remaining = [long]$entry.size
                    while ($remaining -gt 0) {
                        $block = Read-Exact $outputStream ([int][Math]::Min(65536L, $remaining))
                        $file.Write($block, 0, $block.Length)
                        [void]$hash.TransformBlock($block, 0, $block.Length, $block, 0)
                        $remaining -= $block.Length
                        $done += $block.Length
                        if ($clock.ElapsedMilliseconds -ge 120 -or $done -eq $total) {
                            Write-AgentLine "PROGRESS $done $total"
                            $clock.Restart()
                        }
                    }
                    [void]$hash.TransformFinalBlock([byte[]]::new(0), 0, 0)
                    $hashes.Add([BitConverter]::ToString($hash.Hash).Replace('-', '').ToLowerInvariant())
                } finally { $file.Dispose() }
            } finally { $hash.Dispose() }
        }
        $receipt = Read-Frame $outputStream
        if ($receipt.ok -ne $true -or $receipt.status -cne 'download-complete' -or @($receipt.sha256).Count -ne $hashes.Count) {
            throw 'DOWNLOAD_RESPONSE'
        }
        for ($i = 0; $i -lt $hashes.Count; $i++) {
            if ($receipt.sha256[$i] -cne $hashes[$i]) { throw 'DOWNLOAD_CHECKSUM' }
        }
        [IO.Directory]::SetLastWriteTimeUtc($stage, [DateTime]::UtcNow)
        [IO.Directory]::Move($stage, $destination)
        return (Join-Path $destination $root)
    } finally {
        if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) }
    }
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
        $download = $command -cmatch '^DOWNLOAD ([0-9]{1,10})$'
        if (!$download -and $command -cne 'UPLOAD') { Write-AgentLine ('ERROR ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('Unknown agent command.'))); continue }
        try {
            $path = if ($download) { Receive-Download ([uint32]$Matches[1]) } else { Send-Request }
            Write-AgentLine ('PATH ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($path)))
        } catch {
            Stop-SshChannel
            $message = Get-DisplayError ([string]$_.Exception.Message)
            Write-AgentLine ('ERROR ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message)))
        }
    }
    Stop-SshChannel
} catch {
    Stop-SshChannel
    $message = Get-DisplayError ([string]$_.Exception.Message)
    Write-AgentLine ('FATAL ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message)))
    exit 1
}
