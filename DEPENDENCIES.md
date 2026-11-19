# 部署依赖

先在对应主机检查依赖。缺什么就向用户列出安装命令，得到同意后再安装。

| 用途 | 依赖 | 检查方式 |
|---|---|---|
| Linux 接收端 | Python 3.9 或更新版、Pillow、已运行的 OpenSSH Server | `/usr/bin/python3 -c 'import sys; from PIL import Image; assert sys.version_info >= (3, 9)'`；从 Windows 运行 README 的 SSH 检查 |
| Linux 安装脚本 | Bash、GNU coreutils 的 `install` | `command -v bash install` |
| Linux 定时清理 | systemd 用户管理器；也可用系统自己的定时工具 | `systemctl --user list-timers` |
| Windows 运行 | Windows 11、Windows PowerShell 5.1、.NET Framework 自带的 WinForms 和 System.Drawing、OpenSSH Client | `$PSVersionTable.PSVersion`、`Get-Command ssh.exe`、`Add-Type -AssemblyName System.Windows.Forms, System.Drawing` |
| Windows 构建 | 支持 C++17 的 MSVC 和 Windows SDK，或 MinGW-w64 GCC。需要 Direct2D、DirectWrite、DWM 的头文件和链接库 | `Get-Command cl.exe,g++.exe -ErrorAction SilentlyContinue`；运行 `windows/build-hotkey.ps1` |
| 自动粘贴（可选） | 支持 `Ctrl+Shift+V` 的终端，例如 Windows Terminal | 在实际终端测试粘贴 |
| XPipe 联动（可选） | XPipe、Windows Script Host、Task Scheduler 的 PowerShell 模块 | `Get-Command wscript.exe, Get-ScheduledTask` |

Debian 可用系统包安装 Linux 依赖：

```bash
sudo apt install python3 python3-pil openssh-server
```

其他发行版使用各自的包管理器。Python 依赖声明在 [requirements.txt](requirements.txt)。接收器和定时服务默认使用 `/usr/bin/python3`，所以 Pillow 需要对这个解释器可见。只安装到虚拟环境时，须让 SSH 接收命令和定时清理都使用那个环境的解释器。

当前 SSH 上传和 Windows 粘贴无需 xclip、Xvfb 或 tmux。

## Windows 安装与检查

### 运行已编译的客户端

在 Windows 11 的交互桌面使用系统自带的 Windows PowerShell 5.1。客户端会用 WinForms 和 System.Drawing 读取剪贴板，使用 `ssh.exe` 向 Linux 发起连接。Windows 上的 OpenSSH Server 只在需要从别的机器远程管理这台 Windows 时使用。

在 Windows PowerShell 检查：

```powershell
$PSVersionTable.PSVersion
Get-Command ssh.exe
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
```

如果缺少 OpenSSH Client，经用户同意后在管理员 PowerShell 执行。安装完成后回到普通权限的桌面会话继续部署。参见 [Microsoft OpenSSH 安装指南](https://learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse)。

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

将 `ClipBridgeHotkey.exe`、`clipbridge-agent.ps1` 和 `clipbridge-notify.ps1` 放在同一目录。没有现成 EXE 时，从源码构建。

### 从源码构建

选择一种工具链即可：

- **MSVC**：在 [Visual Studio Build Tools](https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio) 中选「使用 C++ 的桌面开发」，保留 MSVC 和 Windows SDK。打开 **Developer PowerShell for Visual Studio**，确认 `Get-Command cl.exe` 能找到编译器。
- **MinGW-w64**：安装 [MSYS2](https://www.msys2.org/)，在 **UCRT64** 终端运行 `pacman -S --needed mingw-w64-ucrt-x86_64-gcc`。再在 Windows PowerShell 将 UCRT64 的 `bin` 加到当前会话的 PATH。例如默认安装位置用 `$env:Path = 'C:\msys64\ucrt64\bin;' + $env:Path`。确认 `Get-Command g++.exe` 指向这套工具链。

从仓库根目录运行：

```powershell
.\windows\build-hotkey.ps1
```

默认输出 `windows\ClipBridgeHotkey.exe`。编译器和 SDK 只用于构建。

### 可选功能

- 自动粘贴：目标终端需支持 `Ctrl+Shift+V`。先用 Windows Terminal 验证，再设置 `--auto-paste WindowsTerminal.exe`。
- 登录自启：使用 Windows Task Scheduler 和 PowerShell 的 ScheduledTasks 模块。用 `Get-Command Register-ScheduledTask` 检查。
- XPipe 联动：需要已经安装的 XPipe、可用的 `wscript.exe` 和 ScheduledTasks 模块。按 README 配置。Windows Script Host 若被组织策略禁用，可使用普通登录自启。
