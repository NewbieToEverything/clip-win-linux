# Agent 部署指南

当用户要求部署 ClipBridge 时，从本页开始。对照 [README](README.md) 执行配置，并用 [桌面验收表](tests/manual-test-matrix.md) 记录结果。

## 确认环境

- 确认当前 Shell 在 Windows 还是 Debian。确认 Windows 实际使用的终端程序、能免交互连接 Debian 的 SSH 别名，以及要用的工作空间（`workspace-a` 或 `workspace-b`）。
- 单机使用默认工作空间 A。两台 Windows 分别设置 A、B，可以共用 Debian 登录账号和 SSH 别名。工作空间用于路由上传，同一个 Unix 用户仍可读到两个空间。
- 沿用已有的 SSH 认证、XPipe 入口和 tmux server。避免修改 Shell 全局启动文件。通过现有 SSH 客户端检查连接，保护本机的凭据、配置原文和上传内容。
- 能执行的步骤直接执行。需要用户输入 sudo 密码、核对主机密钥、操作 Windows 桌面或安装缺失依赖时，给出对应主机上的具体操作。

## Debian 端

1. 需要 Python 3、Pillow 和正在提供 SSH 登录的 sshd。Debian 上可用 `python3-pil` 提供 Pillow。用 `/usr/bin/python3 -c 'import PIL'` 核实。
2. 在仓库根目录运行 `bash debian/install.sh`。它把接收器部署到 `~/.local/bin/clipbridge`。
3. 在现有 SSH 会话中按 README 安装 `debian/20-clipbridge-env.conf`。先跑 `sudo /usr/sbin/sshd -t`，确认有效配置允许 `CLIPBRIDGE_WS`，再 reload SSH。保留原会话直到新连接通过。
4. 可在服务器直接运行 `CLIPBRIDGE_WS=workspace-a ~/.local/bin/clipbridge doctor` 检查本地存储。还要从 Windows 做一次 SSH 验证，见下一节。

## Windows 端

1. 在已有的 OpenSSH Host 段设置 `SetEnv CLIPBRIDGE_WS=workspace-a`，设备 B 使用 `workspace-b`。上传器和热键 EXE 默认使用 `debian`。如用户保留其他别名，手动上传可传 `-SshHost`，常驻热键仍需要能用 `debian` 连接。
2. 从 Windows 桌面 PowerShell 验证实际连接。返回的 JSON 要对应本机配置的工作空间。

   ```powershell
   ssh -nT -o BatchMode=yes -o StrictHostKeyChecking=yes debian '~/.local/bin/clipbridge doctor'
   ```

3. 在有 MSVC 或 MinGW 的构建环境运行 `windows/build-hotkey.ps1`。把 `ClipBridgeHotkey.exe`、`clipbridge-send.ps1` 和 `install-user-startup.ps1` 放在同一 Windows 目录。没有构建工具时，说明所缺依赖并确认后再安装。
4. 先运行 EXE 的默认模式。在记事本有焦点时复制测试图片或文件，按 `Alt+Shift+V`。托盘提示成功后手动粘贴，应该得到 Debian 路径。再在实际终端的编辑区按 `Ctrl+Shift+V`，验证粘贴路径的行为。
5. 核对终端进程名后才启用自动粘贴。以下是 Windows Terminal 的示例。切换启动参数前，先从托盘退出当前 ClipBridge，以免两个进程同时注册热键。

   ```powershell
   & .\ClipBridgeHotkey.exe --auto-paste WindowsTerminal.exe --paste-timeout 8
   ```

   自动粘贴只在收到有效回执且前台窗口匹配时发送一次文本粘贴。等待超时，或切换到另一个 Windows 窗口时，成功的路径仍可手动粘贴。自动粘贴无法识别同一终端内的窗格切换，用户应在等待时保持编辑位置。用户要求登录自启时，再用同一目录的自启脚本注册普通权限计划任务。

   ```powershell
   & .\install-user-startup.ps1 -AutoPasteTerminal WindowsTerminal.exe -PasteTimeoutSeconds 8
   ```

## 验收和修改

- 服务端回归测试用 `/usr/bin/python3 -B -m unittest discover -s tests -v`。验证 PNG、文件/目录和工作空间路由。
- 桌面端验证热键只触发一次、上传失败不会贴出旧路径、切窗降级为手动粘贴。接收端回执校验成功后才能写入本地剪贴板。
- 原生 tmux 和 Agent Manager 都沿用当前终端的路径粘贴。逐个记录目标界面的结果。路径文本、附件标签和模型确实读到了图像是三种不同的验收结果。
- 优先使用仓库内的脚本和测试。提交前筛除本机身份、主机地址、上传样本和编译产物。保留现有 SSH 信任设置，避免把验证步骤写成绕过主机密钥检查的命令。
