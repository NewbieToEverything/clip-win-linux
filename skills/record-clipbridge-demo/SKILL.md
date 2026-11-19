---
name: record-clipbridge-demo
description: Record real ClipBridge transfers in an isolated Windows terminal and assemble a privacy-reviewed GIF showing the upload card and the remote agent input. Use for creating or refreshing the repository demo.
---

# 实机录制 ClipBridge 演示

1. 在 Linux 的临时目录建一个虚构项目，在 Windows 准备一张生成的示例图片。用单独的 Windows Terminal 窗口经 SSH 启动远端 OpenCode。非登录 SSH shell 可能找不到 Agent，使用已核实的可执行文件路径。首次抓帧前确认输入框可用，且画面只含演示内容。
2. SSH 登录 Windows 通常在 Session 0。把 [抓帧脚本](scripts/capture.ps1) 放在 Windows 演示目录，通过当前桌面用户的交互式计划任务运行 PowerShell 5.1（`-NoProfile -STA -WindowStyle Hidden`）。任务使用 `Interactive` 登录类型，并允许在电池供电时启动。传入演示窗口唯一标题、示例图和帧目录。若窗口启动失败、失焦或桌面锁定，停止本轮，避免拍到其他窗口。
3. 在独立终端里最大化窗口，保留右下角的 ClipBridge 上传卡片。暂时关闭输入法浮窗，把鼠标移出窗框按钮区域，避免工具提示。过小的图片不会触发延迟显示的进度窗，可用较大的合成 PNG。脚本会改变 Windows 当前剪贴板，并在目标窗口处于前台时按 `Alt+Shift+V`。它不提交 Agent 消息。
4. 下载挑选的起始帧、卡片进度帧和最终帧。确认卡片可读、OpenCode 显示图片标签，并逐帧检查连接地址、真实项目名、用户名、终端标题、输入法浮窗和意外覆盖的窗口。若出现无关内容，优先重录；也可裁切无关边缘，保留右下角卡片。不要提交原始帧、失败截图或录制日志。
5. 把选好的帧按时间排序，从 `frame-00.png` 开始连续编号。保留最终画面约两秒。用 FFmpeg 缩放并生成 GIF，例如：

   ```bash
   ffmpeg -framerate 5 -i frame-%02d.png \
     -filter_complex 'scale=1200:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse' \
     -loop 0 clipbridge-demo.gif
   ```

6. 录完只关闭本轮专用测试窗，保留其他终端和 Agent 会话。停用临时抓帧任务。用户授权发布时，更新仓库的 `docs/clipbridge-demo-overlay.gif` 和两版 README 的说明，将实机录制与模拟画面明确区分。
