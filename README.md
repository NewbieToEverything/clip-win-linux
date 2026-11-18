# ClipBridge

ClipBridge 把 Windows 剪贴板中的截图、文件和文件夹上传到 Debian，并把绝对路径复制回 Windows 剪贴板。

请让负责部署的 Agent 先读 [AGENTS.md](AGENTS.md)，里面有跨主机配置步骤和验收标准。

## 快速开始

1. 在 Debian 运行 `bash debian/install.sh`。服务端使用 Python 3、Pillow 和已有的 sshd。v4 通过一次性 SSH 命令接收文件。
2. 从已登录的 Debian 会话执行以下命令。保留当前会话，直到 Windows A 验证新连接。

   ```bash
   sudo install -m 644 debian/20-clipbridge-env.conf /etc/ssh/sshd_config.d/20-clipbridge-env.conf
   sudo /usr/sbin/sshd -t && sudo /usr/sbin/sshd -T | awk '$1 == "acceptenv" {print}'
   sudo /usr/sbin/sshd -t && sudo systemctl reload ssh
   ```

   检查第二条命令的输出中包含 `CLIPBRIDGE_WS`，再重载 sshd。

3. 在 Windows A 的 OpenSSH 配置中，给现有 `Host debian` 段加上 `SetEnv CLIPBRIDGE_WS=workspace-a`。设备 B 在自己的 `Host debian` 段使用 `workspace-b`。保存后直接验证。

   ```powershell
   notepad "$env:USERPROFILE\.ssh\config"
   ssh -nT -o BatchMode=yes -o StrictHostKeyChecking=yes debian '~/.local/bin/clipbridge doctor'
   ```

4. Windows 上运行 `windows/build-hotkey.ps1`。它使用已有的 MSVC 或 MinGW。将编译后的 EXE、`clipbridge-send.ps1` 和 `clipbridge-notify.ps1` 放在同一目录，例如 `D:\Tools\ClipBridge\ClipBridgeHotkey.exe`。
5. 先按 [手动验收表](tests/manual-test-matrix.md) 验证路径粘贴，再从 Windows 桌面启动 EXE。默认按 `Alt+Shift+V` 上传并复制路径，由你手动粘贴。程序在后台运行。它通过 Windows 应用通知报告上传失败，或提醒路径已复制、可手动粘贴。

## 配置

| 配置 | 类型 | 默认值 | 含义 |
|---|---|---|---|
| SSH `SetEnv CLIPBRIDGE_WS` | `workspace-a` 或 `workspace-b` | 必填 | 本机上传的工作空间。 |
| 上传器 `-SshHost` | SSH 别名 | `debian` | 手动运行发送器时可覆盖。常驻 EXE 使用默认别名。 |
| EXE `--auto-paste terminal.exe` | 确认过的终端程序名 | 关闭 | 仅对指定终端启用 `Ctrl+Shift+V`。默认等待 8 秒。 |
| EXE `--paste-timeout seconds` | 1–60 秒整数 | 8 秒 | 超时后只复制路径，上传仍会继续。需与 `--auto-paste` 一起使用。 |
| 登录自启脚本 `-AutoPasteTerminal` | 终端程序名 | 关闭 | 验收后可运行 `install-user-startup.ps1` 注册普通权限登录任务，可用 `-PasteTimeoutSeconds` 设置时限。 |

在 Windows 终端完成手动测试后，可用实际进程名启动自动模式。Windows Terminal 的名称通常是 `WindowsTerminal.exe`。

```powershell
& 'D:\Tools\ClipBridge\ClipBridgeHotkey.exe' --auto-paste WindowsTerminal.exe --paste-timeout 8
```

切换模式前运行 `ClipBridgeHotkey.exe --stop`，等待当前进程退出。`--cancel-upload` 可以取消正在进行的上传。自动粘贴成功时保持安静，其他提示由 Windows 通知设置控制。

开启自动模式时，在上传期间保持当前 Agent 编辑区和窗格。程序会检查前台窗口和进程，窗口切换或超过时限时仅复制路径。同一终端窗口里的窗格切换可能检测不到。

## 用法

- `clipbridge-send.ps1` 手动上传，并输出服务端确认过的路径。加 `-CopyPath` 可复制它。路径为单行文本。
- `clipbridge receive --format png|archive` 从 SSH 标准输入接收二进制，返回单行 JSON。
- `clipbridge doctor` 检查环境变量映射和工作空间能否写入。
- `clipbridge latest` 返回当前 v4 工作空间最近的成功回执。
- PNG 上限 15 MiB、2500 万像素。ZIP 上限 200 MiB，解包总量上限 200 MiB，最多 2000 条目。
- 如果原先部署过 Xvfb 版，先跑通 v4，再切换 XPipe 默认环境并停用旧服务。

### 原生 tmux

ClipBridge 通过 Windows 终端粘贴路径。SSH 会话内可以直接运行 Agent，也可以使用原生 tmux 或 Agent Manager。各自沿用现有窗口、会话和 socket。自动粘贴只能判断 Windows 前台窗口，无法区分同一窗口内的 tmux pane、标签页或密码提示。

普通文件路径可以直接粘到 tmux 中的编辑区。图片路径是否转成附件，由当前 Agent 和终端的粘贴方式决定。用实际界面按 [手动验收表](tests/manual-test-matrix.md) 测试。
