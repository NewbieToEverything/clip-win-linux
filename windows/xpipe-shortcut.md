# XPipe 联动快捷方式

本说明适用于 Windows 上使用 XPipe 的用户。联动快捷方式先启动 XPipe，再由 `start-with-xpipe.ps1` 在同一桌面会话启动 ClipBridge；关闭 XPipe 后，启动器会等待当前发送结束，再关闭 ClipBridge。

## 配置

1. 将 `ClipBridgeHotkey.exe`、`clipbridge-agent.ps1`、`clipbridge-notify.ps1`、`start-with-xpipe.ps1` 和 `start-with-xpipe.vbs` 放进同一个安装目录。
2. 在该目录中保留原 XPipe 快捷方式的副本，并命名为 `XPipe-original.lnk`。不要把它替换成联动快捷方式。
3. 在桌面新建快捷方式。目标填写：

   ```text
   wscript.exe //B //Nologo "<ClipBridge 安装目录>\start-with-xpipe.vbs"
   ```

   将 `<ClipBridge 安装目录>` 换成实际目录，例如 `%LOCALAPPDATA%\ClipBridge` 对应的完整路径。快捷方式的“起始位置”可留空。

4. 给快捷方式取名，例如 `XPipe + ClipBridge`，然后用它启动 XPipe。确认 XPipe 和 ClipBridge 都运行后，再将此快捷方式固定到任务栏。之后从任务栏启动 XPipe 时也使用这个新快捷方式。
5. 原登录任务 `ClipBridge Hotkey` 仅供启动器读取 EXE 和参数，联动模式下应停止并禁用：

   ```powershell
   Stop-ScheduledTask -TaskName 'ClipBridge Hotkey' -ErrorAction SilentlyContinue
   Disable-ScheduledTask -TaskName 'ClipBridge Hotkey'
   ```

## 验证与更新

- 检查任务状态为 `Disabled`，并确认任务动作仍包含正确的安装路径、SSH 别名和自动粘贴参数。禁用该任务是联动模式的正常状态。
- 启动 XPipe 后，在任务管理器中确认 `xpiped.exe` 与 `ClipBridgeHotkey.exe` 同属当前桌面会话。退出 XPipe 后，确认 ClipBridge 随之退出。
- 更新程序时，在同一桌面会话里先构建到临时文件名并运行 `--self-check`。正常停止旧 ClipBridge 后替换 EXE，再按任务动作中的参数启动新版。验证新版仍在运行且会话与 XPipe 相同。
- 启动器不会自动重启已意外退出的 ClipBridge。若更新后未能在同一桌面会话重新启动，退出 XPipe，再从联动快捷方式重开并复核进程。

## 终端程序不同于 XPipe

可以复用此模式，但需修改 `start-with-xpipe.ps1`：将原快捷方式文件名和被跟踪的进程名换成对应终端程序。确认该进程能代表终端主窗口的生命周期，再按上面的步骤创建快捷方式。
