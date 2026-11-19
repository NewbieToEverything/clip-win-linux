# Agent 部署指南

执行 ClipBridge 部署时先读本页与 [中文 README](README.zh.md)，先按 [部署依赖](DEPENDENCIES.md) 检查两端环境，再按 [桌面验收表](tests/manual-test-matrix.md) 验证实际终端行为。

## 项目技能

制作或更新实机演示 GIF 时，读取 [record-clipbridge-demo](skills/record-clipbridge-demo/SKILL.md)。

## README 同步

[README.zh.md](README.zh.md) 是主维护版。修改 README 内容时先更新中文，再在同一次变更中同步英文 [README.md](README.md)。两版的架构、命令、配置默认值、限制和验收说明应一致。GitHub 默认展示英文，两版开头保留语言链接。

## 目标与约束

- 上传只读取剪贴板；自动粘贴会用回执路径覆盖当前剪贴板，并标记为不加入 Win+V 历史。原文件名、相对目录结构和内容哈希必须由 Debian 回执确认。
- 每台 Windows 使用 SSH `SetEnv CLIPBRIDGE_WS` 路由到独立工作空间。不要把主机密钥检查设为关闭。
- 使用独立的长期 SSH 子进程通道复用连接，不依赖 XPipe 已打开的终端隧道或同一局域网。
- 不要把 Unicode 字符输入描述为终端 Paste。需分别验收路径文本、附件标签和 Agent 实际读取图片。
- 不读取、复制或输出密钥、SSH 配置全文、剪贴板样本或用户目录中的敏感配置。

## 部署前确认

- 使用用户现有的 Linux SSH 别名，或与用户确认新别名。`linux` 是默认别名，实际部署和验证都用同一个别名。
- 使用用户指定的 Windows 安装目录。若无现有目录，建议当前用户的 `%LOCALAPPDATA%\ClipBridge`。将 EXE、脚本和可选的 XPipe 启动器放在一起。不要假定机器有 D 盘。
- 确认工作空间、目标终端进程名，以及是否需要自动粘贴、登录自启或 XPipe 联动。按实际设备配置，不按设备名称猜测。

## Debian 端

1. 确认 Python 3、Pillow 和现有 sshd 可用。缺少软件包时先向用户说明安装命令，不要自行安装。
2. 仓库根目录运行 `bash debian/install.sh`，安装接收器并启用用户级每小时清理计时器。`systemctl --user` 需要有效的用户服务管理器。
3. 在 Debian sshd 配置中允许 `CLIPBRIDGE_WS`。安装配置前保留当前 SSH 会话；用 `sudo /usr/sbin/sshd -t` 验证，再 reload SSH。
4. 在现有登录环境运行 `CLIPBRIDGE_WS=workspace-a ~/.local/bin/clipbridge doctor`。清理状态可用 `~/.local/bin/clipbridge stats --all` 查看。

## Windows 端

先检查 [Windows 安装与检查](DEPENDENCIES.md#windows-安装与检查)，按需准备运行环境、编译器和可选的 XPipe 联动依赖。

1. 在 Windows 的 OpenSSH Host 别名（例如 `linux`） 配置 `SetEnv CLIPBRIDGE_WS=workspace-a`；第二台设备可使用 `workspace-b`。SSH 私钥和 known_hosts 沿用用户现有配置。
2. 在 Windows PowerShell 验证连接：

   ```powershell
   ssh -nT -o BatchMode=yes -o StrictHostKeyChecking=yes linux '~/.local/bin/clipbridge doctor'
   ```

   回执工作空间必须和该设备映射一致。
3. 在有 MSVC 或 MinGW 的环境运行 `windows/build-hotkey.ps1`。构建需链接 Win32、Direct2D、DirectWrite 和 DWM 系统库。EXE、`clipbridge-agent.ps1`、`clipbridge-notify.ps1` 放在同一目录。`clipbridge-send.ps1` 是单次手动工具。
4. 启动 EXE 时传 `--ssh-host linux`，并替换成实际别名。配置登录自启时，向 `install-user-startup.ps1` 传同一个 `-SshHost`。XPipe 联动沿用计划任务的参数。启动后复制新图片或文件并按 `Alt+Shift+V`。检查右下角进度、Debian 文件名与 SHA-256，再到目标输入框检查生成的内容。
5. 原生进度卡片由 Direct2D/DirectWrite 绘制，超过约 300 ms 才显示，不抢焦点。自动输入受前台窗口、焦点变化与等待时限保护，但无法判断同一个终端窗口内的 pane 或 Agent 当前编辑区。没有通过相应桌面验收前，不应假定图片已成为附件。

## 协议与缓存

- `CBR5` 帧头包含请求 ID、工作空间、源名称、相对路径、长度及 SHA-256；随后是按序排列的文件字节。
- Debian 使用暂存目录、哈希核验和原子提交。重复请求 ID 可安全重试，避免确认帧丢失导致重复写入。
- 接收限制：每文件 128 MiB、每批 256 MiB、每工作空间 512 MiB、全局 1 GiB、最多 200 个条目、相对路径最多 32 层。
- 默认缓存 TTL 为 24 小时。清理器每小时检查 TTL、配额和陈旧暂存文件；近期文件受短时保护。可用 `prune --all --dry-run` 预览清理。
- 数据目录为 `~/.local/share/clipbridge/<workspace>/batches/`；旧版缓存也纳入统计和清理。此缓存不保证长期保存。

## 完成验收

先跑 Debian 单元测试，再在 Windows 实际桌面完成手动验收表。至少记录两台设备的 SSH 路由、文件/目录 Unicode 原名、同名文件、传输中切换窗口、失败重试和缓存清理。路径文本、附件标签与 Agent 正确读取图片必须分别记录。

- 如需跟随 XPipe 启停，按 [README 联动步骤](README.zh.md#随-xpipe-启停) 配置无控制台快捷方式，并保留已禁用的计划任务供启动器读取参数。
