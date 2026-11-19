param(
 [Parameter(Mandatory)][string]$WindowTitle,
 [Parameter(Mandatory)][string]$SampleImage,
 [Parameter(Mandatory)][string]$FrameDirectory,
 [switch]$CloseWindow
)
$ErrorActionPreference='Stop'
$dir=(New-Item -ItemType Directory -Force -Path $FrameDirectory).FullName
if(Get-ChildItem -LiteralPath $dir -Filter 'frame-*.png' -File | Select-Object -First 1){
 throw 'Choose a new frame directory for this capture.'
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DemoWindow {
 public delegate bool EnumProc(IntPtr hwnd,IntPtr state);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr state);
 public static IntPtr FindTitle(string title) {
  IntPtr match=IntPtr.Zero;
  EnumWindows((h,p)=>{var text=new StringBuilder(256);GetWindowText(h,text,text.Capacity);
   if(text.ToString()==title){match=h;return false;}return true;},IntPtr.Zero);
  return match;
 }
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder title,int size);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint msg,IntPtr w,IntPtr l);
}
'@
[void][DemoWindow]::SetProcessDPIAware()
$tag=$WindowTitle
function Get-DemoRect {
 $h=[DemoWindow]::GetForegroundWindow()
 $title=[Text.StringBuilder]::new(256)
 [void][DemoWindow]::GetWindowText($h,$title,256)
 if($title.ToString() -cne $tag){return}
 $r=[DemoWindow+Rect]::new()
 if([DemoWindow]::GetWindowRect($h,[ref]$r)){return $r}
}
function Save-Frame([string]$name){
 $r=Get-DemoRect
 if(!$r){throw 'Demo window lost focus'}
 $area=[Windows.Forms.Screen]::FromHandle([DemoWindow]::GetForegroundWindow()).WorkingArea
 $left=[Math]::Max($r.Left+12,$area.Left)
 $top=[Math]::Max($r.Top+85,$area.Top+85)
 $width=[Math]::Min($r.Right,$area.Right)-$left
 $height=[Math]::Min($r.Bottom,$area.Bottom)-$top
 if($width -lt 420 -or $height -lt 240){throw 'Demo window too small'}
 $bitmap=[Drawing.Bitmap]::new($width,$height)
 $g=[Drawing.Graphics]::FromImage($bitmap)
 try {
  $g.CopyFromScreen($left,$top,0,0,$bitmap.Size)
  if(!(Get-DemoRect)){throw 'Focus changed while capturing'}
  $bitmap.Save((Join-Path $dir $name),[Drawing.Imaging.ImageFormat]::Png)
 } finally {$g.Dispose();$bitmap.Dispose()}
}
try {
 $ready=$false
 for($i=0;$i -lt 75;$i++){
  if(Get-DemoRect){$ready=$true;break}
  Start-Sleep -Milliseconds 400
 }
 if(!$ready){throw 'Demo window was not foreground'}
 Save-Frame 'frame-00.png'
 $files=[Collections.Specialized.StringCollection]::new()
 [void]$files.Add((Get-Item -LiteralPath $SampleImage).FullName)
 [Windows.Forms.Clipboard]::SetFileDropList($files)
 if(!(Get-DemoRect)){throw 'Demo window lost focus'}
 [Windows.Forms.SendKeys]::SendWait('%+v')
 for($i=1;$i -le 30;$i++){
  Start-Sleep -Milliseconds 160
  Save-Frame ('frame-{0:00}.png' -f $i)
 }
 Set-Content -LiteralPath (Join-Path $dir 'capture-status.txt') -Value 'CAPTURE_READY'
} catch {
 Set-Content -LiteralPath (Join-Path $dir 'capture-status.txt') -Value 'CAPTURE_ABORTED'
 throw
} finally {
 if($CloseWindow){
  $h=[DemoWindow]::FindTitle($tag)
  if($h -ne [IntPtr]::Zero){[void][DemoWindow]::PostMessage($h,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)}
 }
}
