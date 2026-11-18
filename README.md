# ClipBridge

ClipBridge 将 Windows 剪贴板中的图片、文件和文件夹经 SSH 安全传到 Debian，并返回可在远程终端使用的绝对路径。

## 快速开始

1. Debian 安装 Python 3 和 Pillow 后，在仓库运行 `bash debian/install.sh`。该脚本安装接收器并启用每小时缓存清理计时器。
2. Debian sshd 必须允许 `CLIPBRIDGE_WS` 环境变量。检查并重载 sshd 的步骤见 [Agent 部署指南](AGENTS.md#debian-端)。保持现有 SSH 会话，直到新连接验证成功。
3. Windows OpenSSH 配置中的 `Host debian` 段设置 `SetEnv CLIPBRIDGE_WS=workspace-a`；设备 B 使用 `workspace-b`。验证：

   ```powershell
   ssh -nT -o BatchMode=yes -o StrictHostKeyChecking=yes debian '~/.local/bin/clipbridge doctor'
   ```

4. 在 Windows 构建环境运行 `windows/build-hotkey.ps1`。将生成的 `ClipBridgeHotkey.exe`、`clipbridge-agent.ps1` 和 `clipbridge-notify.ps1` 放在同一目录。
5. 启动 EXE 后复制图片或文件，按 `Alt+Shift+V`。新版进度卡片用 Windows 自带 Direct2D/DirectWrite 绘制，超过约 300 毫秒才显示，避免小任务闪窗。成功后 Debian 保存原名文件并返回绝对路径。

## 配置

| 项目 | 默认值 | 含义 |
|---|---|---|
| SSH 别名 `debian` | `debian` | Windows 端专用长连接所用别名；使用该别名的现有密钥和主机信任配置。 |
| SSH `SetEnv CLIPBRIDGE_WS` | 必填 | `workspace-a` 或 `workspace-b`，隔离不同 Windows 设备的存储目录。 |
| `--auto-paste terminal.exe` | 关闭 | 允许向指定的前台终端执行自动粘贴，例如 `WindowsTerminal.exe`。 |
| `--paste-timeout seconds` | 8 秒 | 自动粘贴的等待上限，范围 1–60 秒。 |
| PNG 单文件上限 | 15 MiB | Windows 剪贴板位图编码成 PNG 后的大小上限。 |
| 普通文件上限 | 128 MiB | 单个文件大小。 |
| 单次上传上限 | 256 MiB | 一批文件的总大小；最多 200 个文件或目录项。 |
| 缓存 TTL | 24 小时 | Debian 接收文件默认保留期；近期文件及配额回收另受清理器保护。 |

## 用法

- `Alt+Shift+V`：读取 Windows 剪贴板并上传。自动粘贴时会把回执路径写入当前 Windows 剪贴板，并标记为不加入 `Win+V` 历史。同一 ClipBridge 进程复用专用 SSH 通道。可在图片或文件传输期间切换窗口，回执完成后程序仅在原前台窗口仍匹配且未超时的情况下输入路径。
- 自动粘贴通过 Windows 剪贴板和终端的 Ctrl+Shift+V 完成。图片是否成为 Agent 附件，须按 [桌面验收表](tests/manual-test-matrix.md) 在目标终端和输入框验证；未验证前请手动确认输入结果。
- 进度卡片不抢焦点，按原窗口所在屏幕右下角显示；百分比只用于已知总字节的上传阶段。高 DPI 清晰度需要在 Windows 100%、125%、150%、200% 缩放下实测。
- `windows/clipbridge-send.ps1`：一次性手动上传工具，兼容 PNG 与归档输入；成功后在标准输出返回路径。
- `clipbridge doctor`：检查工作空间和存储。
- `clipbridge latest`：查看该工作空间最近成功回执。
- `clipbridge stats --all`：查看缓存占用统计。
- `clipbridge prune --all [--dry-run]`：执行或预览缓存清理。
- `clipbridge serve --stdio`：供 Windows 持久 SSH 通道使用的帧式协议入口。

文件保存在 `~/.local/share/clipbridge/<workspace>/batches/`。清理器每小时运行，按 24 小时 TTL、磁盘配额和近期文件保护策略回收旧数据。缓存不能作为唯一备份。

接收端测试：`/usr/bin/python3 -B -m unittest discover -s tests -v`。Windows PowerShell 与真实终端的桌面验收步骤见 [桌面验收表](tests/manual-test-matrix.md)。
