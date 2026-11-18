param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$SshHost = 'debian',
    [switch]$ProgressEvents
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.IO.Compression
$limit = 200MB
$entryCount = 0
$inputBytes = 0
$temp = $null
$payload = $null

function Add-ArchiveItem($archive, [string]$path, [string]$name, [int]$depth) {
    if ($depth -gt 32 -or ++$script:entryCount -gt 2000) { throw 'Archive tree exceeds limits.' }
    $attributes = [IO.File]::GetAttributes($path)
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Links and junctions are unsupported.' }
    if ($attributes -band [IO.FileAttributes]::Directory) {
        [void]$archive.CreateEntry($name + '/')
        foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($path)) {
            Add-ArchiveItem $archive $child ($name + '/' + [IO.Path]::GetFileName($child)) ($depth + 1)
        }
        return
    }
    $source = [IO.File]::Open($path, 'Open', 'Read', 'Read')
    try {
        $script:inputBytes += $source.Length
        if ($script:inputBytes -gt $limit) { throw 'Archive input exceeds 200 MiB.' }
        $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Fastest).Open()
        try { $source.CopyTo($entry) } finally { $entry.Dispose() }
    } finally { $source.Dispose() }
}

function Publish-Stage([string]$stage) {
    if ($ProgressEvents) { [Console]::WriteLine('STATUS ' + $stage) }
}

function Invoke-OpenSsh([string]$arguments, $stream, [int]$timeoutMs, [long]$total = 0) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command ssh.exe -CommandType Application).Source
    $start.Arguments = $arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    $encoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = [Text.Encoding]::ASCII
        $process = [Diagnostics.Process]::Start($start)
    } finally { [Console]::InputEncoding = $encoding }
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = [Text.StringBuilder]::new()
        $pending = $process.StandardError.ReadLineAsync()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $stdin = $process.StandardInput.BaseStream
        $write = if ($null -ne $stream) { $stream.CopyToAsync($stdin) } else { $null }
        if ($null -eq $write) { $stdin.Close() }
        $lastReceived = -1L

        while ($null -ne $write -or $null -ne $pending -or !$process.HasExited) {
            if ($timer.ElapsedMilliseconds -ge $timeoutMs) { throw 'SSH timed out. Commit status unknown.' }
            if ($null -ne $write -and $write.IsCompleted) {
                [void]$write.GetAwaiter().GetResult()
                $stdin.Close()
                $write = $null
            }
            if ($null -ne $pending) {
                if (!$pending.Wait(25)) { continue }
                $entry = $pending.Result
                if ($null -eq $entry) { $pending = $null; continue }
                $pending = $process.StandardError.ReadLineAsync()
                if ($ProgressEvents -and $total -gt 0 -and $entry -cmatch '^CLIPBRIDGE_PROGRESS ([0-9]{1,9})$') {
                    $received = [long]$Matches[1]
                    if ($received -gt $lastReceived -and $received -le $total) {
                        $lastReceived = $received
                        [Console]::WriteLine(('PROGRESS {0} {1}' -f $received, $total))
                        if ($received -eq $total) { Publish-Stage 'verifying' }
                    }
                } elseif ($stderr.Length -lt 8192) {
                    [void]$stderr.AppendLine($entry)
                }
            } else {
                Start-Sleep -Milliseconds 25
            }
        }
        if (!$stdout.Wait(1500)) { throw 'SSH output incomplete. Commit status unknown.' }
        if ($process.ExitCode -ne 0) {
            throw ('SSH failed (exit {0}). No usable receipt. {1}' -f $process.ExitCode, $stderr.ToString().Trim())
        }
        return $stdout.Result
    } finally {
        if (!$process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1500) }
        $process.Dispose()
    }
}

try {
    $snapshot = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $paths = [Windows.Forms.Clipboard]::GetFileDropList()
            if ($paths.Count) { $snapshot = @($paths); break }
            $snapshot = [Windows.Forms.Clipboard]::GetImage()
            break
        } catch [Runtime.InteropServices.ExternalException] {
            if ($attempt -eq 4) { throw }
            Start-Sleep -Milliseconds 60
        }
    }
    if ($null -eq $snapshot) { throw 'Clipboard contains no image or file list.' }
    if ($snapshot -is [Drawing.Image]) {
        Publish-Stage 'encoding'
        $format = 'png'
        $count = 1
        $payload = [IO.MemoryStream]::new()
        try {
            if ([long]$snapshot.Width * $snapshot.Height -gt 25000000) { throw 'Image exceeds 25 megapixels.' }
            $snapshot.Save($payload, [Drawing.Imaging.ImageFormat]::Png)
        } finally { $snapshot.Dispose() }
        if ($payload.Length -gt 15MB) { throw 'PNG exceeds 15 MiB.' }
    } else {
        Publish-Stage 'packing'
        $format = 'archive'
        $count = $snapshot.Count
        $temp = [IO.Path]::Combine([IO.Path]::GetTempPath(), [IO.Path]::GetRandomFileName())
        $payload = [IO.FileStream]::new(
            $temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None, [int]65536, [IO.FileOptions]::DeleteOnClose)
        $archive = [IO.Compression.ZipArchive]::new($payload, 'Create', $true)
        try {
            $sourceRootIndex = 0
            foreach ($item in $snapshot) {
                $sourceRootIndex++
                $name = [IO.Path]::GetFileName($item.TrimEnd('\'))
                if (!$name) { throw 'Drive roots are unsupported.' }
                $indexedName = ('{0:D4}/{1}' -f $sourceRootIndex, $name)
                Add-ArchiveItem $archive $item $indexedName 1
            }
        } finally { $archive.Dispose() }
        if ($payload.Length -gt $limit) { throw 'ZIP exceeds 200 MiB.' }
    }
    Publish-Stage 'preparing-ssh'
    $effective = Invoke-OpenSsh "-G $SshHost" $null 8000
    $mapped = [regex]::Matches($effective, '(?m)^setenv\s+CLIPBRIDGE_WS=(workspace-[ab])\s*$')
    if ($mapped.Count -ne 1) { throw 'SSH alias must declare one valid CLIPBRIDGE_WS.' }
    $workspace = $mapped[0].Groups[1].Value
    $payload.Position = 0
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash($payload)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $payload.Position = 0
    $progressFlag = if ($ProgressEvents) { ' --progress' } else { '' }
    Publish-Stage 'connecting'
    $result = (Invoke-OpenSsh "-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 $SshHost ~/.local/bin/clipbridge receive --format=$format$progressFlag" $payload 120000 $payload.Length).TrimEnd([char]13,[char]10)
    if ($result -match '[\r\n]' -or $result -notmatch '^\{.*\}$') { throw 'Invalid server receipt.' }
    $receipt = ConvertFrom-Json $result
    $kind = if ($format -eq 'png') { 'image' } else { 'archive' }
    if ($receipt.ok -isnot [bool] -or !$receipt.ok -or $receipt.version -ne 2 -or
        $receipt.workspace -cne $workspace -or $receipt.kind -cne $kind -or
        $receipt.count -ne $count -or @($receipt.paths).Count -ne $count -or
        $receipt.archive_sha256 -cne $digest -or
        $receipt.bytes -ne $payload.Length -or $receipt.batch_id -cnotmatch '^\d{8}T\d{6}Z-[a-f0-9]{32}$') {
        throw 'Server receipt does not match the upload.'
    }
    $batchId = [regex]::Escape($receipt.batch_id)
    $pattern = "^/.+/.local/share/clipbridge/$workspace/batches/$batchId/payload/items/[0-9]{4}/.+\z"
    foreach ($path in $receipt.paths) {
        if ($path -isnot [string] -or $path -cnotmatch $pattern -or $path.Contains('\') -or
            $path -match '/\.\.?(/|$)' -or $path -match '[\r\n\x00-\x1F\x7F]') {
            throw 'Invalid server path.'
        }
    }
    $line = $receipt.paths -join ' '
    [Console]::WriteLine($line)
} finally {
    if ($null -ne $payload) { $payload.Dispose() }
}
