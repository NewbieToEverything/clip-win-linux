# clip-win-linux

<p align="center"><strong>English</strong> | <a href="README.zh.md">简体中文</a></p>

clip-win-linux builds a bridge called **ClipBridge** between the Windows clipboard and a Linux terminal. It sends images, files, and folders over SSH, then pastes the returned absolute Linux paths into the current terminal.

> **Deploying with an agent?** Ask it to read [AGENTS.md](AGENTS.md) and [the deployment dependencies](DEPENDENCIES.md) first, then use an installation directory and SSH alias that fit your setup.

![Demo: start with a Windows image and press Alt+Shift+V, then watch a real SSH upload and an image attachment appear in remote OpenCode.](docs/clipbridge-windows-demo.gif)

## Architecture

### ClipBridge components

```mermaid
flowchart LR
    W["Windows<br/>ClipBridge hotkey app and upload agent"]
    L["Linux<br/>OpenSSH server and ClipBridge receiver"]
    W <-->|"Dedicated persistent SSH connection"| L
```

The Windows upload agent starts the Linux receiver (`clipbridge serve --stdio`) through OpenSSH. The open terminal uses its own SSH session.

Open XPipe from the integration shortcut and ClipBridge connects in the background. When XPipe exits completely, ClipBridge finishes any active upload before disconnecting. Closing an SSH tab, or closing the window while XPipe stays in the background, leaves the connection open.

### How does an image reach the input box after Alt+Shift+V?

```mermaid
flowchart LR
    H["① Press Alt+Shift+V"] --> W["Windows · ClipBridge<br/>Reads the clipboard"]
    W -->|"②"| L["Linux receiver<br/>Verifies and stores uploads"]
    L -->|"③"| W
    W -->|"④"| A["Active input<br/>Path or image attachment"]
```

- **① → ②** **Read and upload.** When you press `Alt+Shift+V`, ClipBridge reads the Windows clipboard and uploads the image to Linux over its dedicated persistent SSH connection.
- **③** **Save and return the path.** The Linux receiver verifies and stores the image, then sends its absolute path back to Windows.
- **④** **Paste into the current input.** If automatic paste is enabled and the checks pass, ClipBridge writes the path to the Windows clipboard and triggers `Ctrl+Shift+V` in the terminal. An agent that recognizes image paths, such as Codex CLI, displays the image as an attachment. The path stays out of `Win+V` history.

Regular files and folders follow the same flow. Their absolute Linux paths appear in the input box.

## Quick start

Check [Deployment dependencies](DEPENDENCIES.md) first. The default SSH alias is `linux`. You can specify a different alias. Choose a Windows installation directory, such as `%LOCALAPPDATA%\ClipBridge`, and keep the EXE and its scripts together there.

1. On Debian, install Python 3 and Pillow, then run `bash debian/install.sh` from the repository. This installs the receiver and enables hourly cache cleanup.
2. Configure Debian's SSH server to accept `CLIPBRIDGE_WS`. See the [deployment guide](AGENTS.md#debian-端) for how to check and reload sshd. Keep your existing SSH session open until the new connection works.
3. In the Windows OpenSSH configuration, add `SetEnv CLIPBRIDGE_WS=workspace-a` to the `Host linux` entry. Use `workspace-b` on a second device. Verify the connection:

   ```powershell
   ssh -nT -o BatchMode=yes -o StrictHostKeyChecking=yes linux '~/.local/bin/clipbridge doctor'
   ```

4. Run `windows/build-hotkey.ps1` in a supported Windows build environment. Place the resulting `ClipBridgeHotkey.exe` alongside `clipbridge-agent.ps1` and `clipbridge-notify.ps1`.
5. Run `./ClipBridgeHotkey.exe --ssh-host linux` from the installation directory, copy an image, file, or folder, and press `Alt+Shift+V`. The Direct2D and DirectWrite progress card appears after about 300 ms to avoid flashing for quick uploads. The receiver preserves existing names and directory structure and returns absolute Linux paths for all items.

### Enable automatic paste (optional)

Run the following command from the directory containing the EXE. If ClipBridge is already running, first run `.\ClipBridgeHotkey.exe --stop`, then start it with the new arguments.

```powershell
.\ClipBridgeHotkey.exe --ssh-host linux --auto-paste WindowsTerminal.exe
```

### Start and stop with XPipe

When XPipe exits, the launcher waits for any active upload before closing ClipBridge.

1. Run `install-user-startup.ps1 -SshHost linux -AutoPasteTerminal WindowsTerminal.exe` to configure the `ClipBridge Hotkey` scheduled task. The launcher reads its startup arguments from this task.
2. Place `start-with-xpipe.ps1` and `start-with-xpipe.vbs` alongside the EXE. Copy your original XPipe shortcut into that directory as `XPipe-original.lnk`.
3. Create a Windows shortcut with the target `wscript.exe //B //Nologo "<Windows install directory>\start-with-xpipe.vbs"`. Adjust the path for your installation and pin the shortcut to the taskbar.
4. Run `Stop-ScheduledTask -TaskName 'ClipBridge Hotkey'` and `Disable-ScheduledTask -TaskName 'ClipBridge Hotkey'` in Windows PowerShell. Keep the task so the launcher can read its arguments. Use the new shortcut to open XPipe.

You can use the same lifecycle mechanism with a different terminal application. In the [launcher script](windows/start-with-xpipe.ps1), change the startup shortcut and the main process name it tracks (currently `xpiped`). The launcher uses that process exiting as the signal to shut down ClipBridge.

## Configuration

| Setting | Default | Purpose |
|---|---|---|
| `--ssh-host alias` | `linux` | Dedicated Windows upload connection. Uses the alias's existing credentials and host key settings. |
| SSH `SetEnv CLIPBRIDGE_WS` | Required | Use `workspace-a` or `workspace-b` to keep uploads from different devices in separate directories. |
| `--auto-paste terminal.exe` | Off | Automatically paste into the specified foreground terminal, such as `WindowsTerminal.exe`. |
| `--paste-timeout seconds` | 8 seconds | Maximum wait for automatic paste, from 1 to 60 seconds. |
| PNG limit | 15 MiB | Maximum size after encoding a clipboard bitmap as PNG. |
| File limit | 128 MiB | Maximum size per regular file. |
| Batch limit | 256 MiB | Maximum batch size, with up to 200 file and directory entries. |
| Cache lifetime | 24 hours | Default retention. Quotas and recent-upload protection also govern cleanup. |

## Usage

- Press `Alt+Shift+V` to upload from the Windows clipboard. ClipBridge reuses its dedicated SSH connection. Automatic paste requires a matching foreground window, an unexpired timeout, and an unchanged clipboard. If automatic paste is skipped, retrieve the paths with `clipbridge latest` in the corresponding workspace. It writes the returned paths to the current clipboard and marks them for exclusion from `Win+V` history.
- Automatic paste uses the terminal's `Ctrl+Shift+V` shortcut. Image paths have been verified to become attachments in remote Codex CLI on Debian. For OpenCode, Pi, and Hermes, the display depends on the version and input interface. See the [desktop checklist](tests/manual-test-matrix.md). Regular files and folders still return paths.
- The progress card appears in the lower-right corner of the original window's monitor without taking focus. It shows a percentage when the total byte count is known. Check display quality at 100%, 125%, 150%, and 200% scaling on Windows.
- `windows/clipbridge-send.ps1` accepts the same alias via `-SshHost`, performs a one-off PNG or archive upload and prints the returned absolute Linux paths.
- `clipbridge doctor` checks workspace routing and storage.
- `clipbridge latest` shows the latest successful receipt for the workspace.
- `clipbridge stats --all` reports cache usage.
- `clipbridge prune --all [--dry-run]` runs or previews cache cleanup.
- `clipbridge serve --stdio` is the framed protocol endpoint for the persistent SSH connection.

Files are stored under `~/.local/share/clipbridge/<workspace>/batches/`. Hourly cleanup applies the 24-hour lifetime, disk quotas, and recent-upload protection. Keep a separate copy of any files you need long term.

Run receiver tests with `/usr/bin/python3 -B -m unittest discover -s tests -v`. See the [desktop checklist](tests/manual-test-matrix.md) for Windows PowerShell and terminal verification.
