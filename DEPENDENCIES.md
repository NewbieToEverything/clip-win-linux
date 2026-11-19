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

当前 SSH 上传和 Windows 粘贴无需 xclip、Xvfb 或 tmux。旧版 X11 命令仍留在源码中，仅在显式调用旧入口时才需要 X11 工具。
