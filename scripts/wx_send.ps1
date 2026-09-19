<#
.SYNOPSIS
    向指定微信会话发送一条文本消息（纯本地，不经任何第三方服务）。

.DESCRIPTION
    微信 4.x 自绘界面，无 UIAutomation 可访问树，故采用
    「前台化 -> 截图 -> 系统离线 OCR 定位 -> 合成鼠标键盘」的方式驱动。
    几何全部像素级自标定，不依赖固定分辨率/缩放比/主题。

    发送前会 OCR 核对聊天标题是否等于目标会话，不符立即中止且不输入任何内容，
    以避免发错人。

.PARAMETER Target
    目标会话名，例如「文件传输助手」。

.PARAMETER Message
    消息正文。多行请用 `n 分隔，或改用 -MessageFile。

.PARAMETER MessageFile
    从 UTF-8 文本文件读取正文，优先级高于 -Message。

.PARAMETER DryRun
    走完全部流程并把正文粘贴进输入框，但不按回车。用于安全验证。

.PARAMETER KeepShots
    保留过程截图（默认发送后删除，截图含聊天内容）。

.PARAMETER ShotDir
    截图目录，默认 $env:TEMP\wx_send_shots。

.OUTPUTS
    退出码 0=成功 2=未找到微信窗口 3=无法前台化 4=未定位到目标会话
    5=标题核对失败已中止 6=已发送但未能确认 7=未定位到输入框
    8=桌面不可交互（锁屏/屏幕关闭，应转入排队等解锁） 1=其他错误
#>
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Message = '',
    [string]$MessageFile = '',
    [switch]$DryRun,
    [switch]$KeepShots,
    [string]$ShotDir = ''
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---------------------------------------------------------------- DPI 感知
# 必须在任何窗口 API 调用之前执行，否则 GetWindowRect 返回逻辑坐标
# 而 CopyFromScreen 抓物理像素，截图会变成左上角的一块。
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class NativeDpi {
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
try { [NativeDpi]::SetProcessDpiAwareness(2) | Out-Null }
catch { try { [NativeDpi]::SetProcessDPIAware() | Out-Null } catch {} }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# ---------------------------------------------------------------- Win32
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public struct RECT { public int Left, Top, Right, Bottom; }
public class Wx {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, IntPtr e);
    public struct POINT { public int X, Y; }

    public static string Cls(IntPtr h) {
        var s = new StringBuilder(256);
        GetClassNameW(h, s, 256);
        return s.ToString();
    }

    // Windows 的「前台锁」：只有持有前台、或刚收到用户输入的进程才准调
    // SetForegroundWindow，别人调一律静默失败。通知场景里前台必然是用户正在用的
    // 程序（Chrome 之类），而我们这个子 PowerShell 从没收过输入 —— 所以直接调必失败，
    // 这是常态不是例外。两招，都只作用于本进程，不碰任何全局系统设置：
    //   1. 把自己的输入队列临时挂到当前前台线程上，借它的身份调（AttachThreadInput）；
    //   2. 合成一次 ALT 按下抬起，让系统认为本进程刚收到用户输入，从而拿到豁免。
    // 用完立刻解除挂接。
    //
    // 注意：不要再去动 SPI_SETFOREGROUNDLOCKTIMEOUT 把前台锁超时置 0 —— 那是改全局
    // 系统设置（等于替用户永久削弱一道防抢焦保护，哪怕事后还原也有窗口期），
    // 已被权限系统按「Security Weaken」拒绝。上面两招够用。
    const byte VK_MENU = 0x12;
    const uint KEYUP = 0x0002;
    public static bool ForceForeground(IntPtr h) {
        if (GetForegroundWindow() == h) return true;

        uint fgTid = 0, dummy;
        IntPtr fg = GetForegroundWindow();
        if (fg != IntPtr.Zero) fgTid = GetWindowThreadProcessId(fg, out dummy);
        uint myTid = GetCurrentThreadId();

        bool attached = false;
        if (fgTid != 0 && fgTid != myTid) attached = AttachThreadInput(fgTid, myTid, true);
        try {
            for (int i = 0; i < 4; i++) {
                // 合成 ALT 按下+抬起，让本进程被视为"刚收到用户输入"
                keybd_event(VK_MENU, 0, 0, IntPtr.Zero);
                keybd_event(VK_MENU, 0, KEYUP, IntPtr.Zero);
                BringWindowToTop(h);
                SetForegroundWindow(h);
                System.Threading.Thread.Sleep(220);
                if (GetForegroundWindow() == h) return true;
            }
        } finally {
            if (attached) AttachThreadInput(fgTid, myTid, false);
        }
        return GetForegroundWindow() == h;
    }
    const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
    // LastSet 记下我们自己最后一次把指针放到哪儿，收尾还原时用它判断"这中间用户有没有
    // 自己动过鼠标"：还在我们放的地方才还原，被用户挪走了就别抢回去。
    public static POINT LastSet;
    public static bool HasSet = false;
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        // 记实际落点而不是请求的坐标：SetCursorPos 会被裁到屏幕范围内，
        // 多屏/缩放下请求值和实际值可能差一点，拿请求值去比对会误判成"用户动过"。
        POINT p; if (GetCursorPos(out p)) { LastSet = p; HasSet = true; }
        System.Threading.Thread.Sleep(90);
        mouse_event(LEFTDOWN, 0, 0, 0, IntPtr.Zero);
        System.Threading.Thread.Sleep(45);
        mouse_event(LEFTUP, 0, 0, 0, IntPtr.Zero);
    }
    // 还原指针。原样返回 false 表示"没还原"（用户自己动过，或压根没动过指针）。
    public static bool RestoreCursor(POINT orig) {
        if (!HasSet) return false;
        POINT now;
        if (!GetCursorPos(out now)) return false;
        // 容差 2px：某些鼠标驱动/输入过滤会有 1px 抖动。
        if (Math.Abs(now.X - LastSet.X) > 2 || Math.Abs(now.Y - LastSet.Y) > 2) return false;
        return SetCursorPos(orig.X, orig.Y);
    }

    public class WinInfo {
        public IntPtr H; public string Title; public string Cls;
        public uint Pid; public int W, Ht; public bool Ico;
    }
    // FindWindowW 匹配不到最小化的微信主窗口（实测返回 0，即使标题类名完全一致），
    // 因此改用 EnumWindows 自行筛选。
    public static List<WinInfo> Enum(uint[] pids) {
        var list = new List<WinInfo>();
        var want = new HashSet<uint>(pids);
        EnumWindows((h, p) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (want.Count > 0 && !want.Contains(pid)) return true;
            var sb = new StringBuilder(512); GetWindowTextW(h, sb, 512);
            var sc = new StringBuilder(512); GetClassNameW(h, sc, 512);
            RECT r; GetWindowRect(h, out r);
            list.Add(new WinInfo {
                H = h, Title = sb.ToString(), Cls = sc.ToString(), Pid = pid,
                W = r.Right - r.Left, Ht = r.Bottom - r.Top, Ico = IsIconic(h)
            });
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@
$SW_MAXIMIZE = 3; $SW_SHOW = 5; $SW_RESTORE = 9

function Log([string]$m) { Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Send-Keys([string]$k) { [System.Windows.Forms.SendKeys]::SendWait($k); Start-Sleep -Milliseconds 140 }

# ---------------------------------------------------------------- OCR
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]
$script:AsTaskM = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

function Await($op, $type) {
    $m = $script:AsTaskM.MakeGenericMethod($type)
    $tk = $m.Invoke($null, @($op))
    $tk.Wait(25000) | Out-Null
    return $tk.Result
}

function Get-OcrEngine {
    $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($e) { return $e }
    foreach ($tag in @('zh-Hans-CN', 'zh-Hans', 'zh-CN', 'en-US')) {
        try {
            $lang = New-Object Windows.Globalization.Language($tag)
            $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
            if ($e) { return $e }
        } catch {}
    }
    return $null
}

# OCR 会在汉字之间插空格，所有比较都必须先去空白
function Norm([string]$s) { if ($null -eq $s) { return '' } return ($s -replace '\s', '') }

function Invoke-Ocr([string]$imgPath) {
    $p = [System.IO.Path]::GetFullPath($imgPath.Replace('/', '\'))
    $sf = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($p)) ([Windows.Storage.StorageFile])
    $st = Await ($sf.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($st)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $eng = Get-OcrEngine
    if (-not $eng) { throw 'OCR 引擎不可用：请在「设置 > 时间和语言 > 语言」中为中文添加「光学字符识别」可选功能。' }
    $res = Await ($eng.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    $out = New-Object System.Collections.ArrayList
    foreach ($line in $res.Lines) {
        if ($line.Words.Count -eq 0) { continue }
        $ax = [double]::MaxValue; $ay = [double]::MaxValue; $bx = 0.0; $by = 0.0
        foreach ($wd in $line.Words) {
            $r = $wd.BoundingRect
            if ($r.X -lt $ax) { $ax = $r.X }
            if ($r.Y -lt $ay) { $ay = $r.Y }
            if (($r.X + $r.Width) -gt $bx) { $bx = $r.X + $r.Width }
            if (($r.Y + $r.Height) -gt $by) { $by = $r.Y + $r.Height }
        }
        $w = [int]($bx - $ax); $h = [int]($by - $ay)
        # LText：只留字母和汉字。OCR 在数字和标点上经常认错（连字符→全角句点、
        # 冒号→全角冒号），拿含标点的串做子串匹配会无谓地失败。探针比对一律用它，
        # 而会话标题那种要求精确相等的比对仍然用 NText。
        $null = $out.Add([pscustomobject]@{
                Text = $line.Text; NText = (Norm $line.Text)
                LText = ((Norm $line.Text) -replace '[^\p{L}]', '')
                X = [int]$ax; Y = [int]$ay; W = $w; H = $h
                CX = [int]($ax + $w / 2); CY = [int]($ay + $h / 2)
            })
    }
    return $out
}

# ---------------------------------------------------------------- 窗口 / 截图
function Test-DesktopUsable {
    # 锁屏 / 屏幕已关闭 / 切到安全桌面时，本脚本赖以工作的三件事全部失效：
    # SetForegroundWindow 失败、CopyFromScreen 只出黑屏、合成输入无处可去。
    # 实测锁屏时：GetForegroundWindow()=0、截图平均亮度 0.0/255，
    # 而 OpenInputDesktop 仍会返回 'Default'（不可靠，不用它判断）。
    # 两个条件同时成立才算不可用，避免把"正好一片纯黑的桌面"误判成锁屏。
    $fg = [Wx]::GetForegroundWindow()
    $bright = -1.0
    try {
        $bmp = New-Object System.Drawing.Bitmap 240, 240
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size(240, 240)))
        $g.Dispose()
        $sum = 0.0; $n = 0
        for ($y = 0; $y -lt 240; $y += 8) {
            for ($x = 0; $x -lt 240; $x += 8) {
                $c = $bmp.GetPixel($x, $y); $sum += ($c.R + $c.G + $c.B) / 3.0; $n++
            }
        }
        $bmp.Dispose()
        $bright = $sum / $n
    } catch { $bright = -1.0 }
    $locked = [bool](Get-Process -Name 'LogonUI' -ErrorAction SilentlyContinue)

    # 锁屏有两副面孔，只认「前台=0 且纯黑」会漏掉第二种：
    #   a) 已黑屏：GetForegroundWindow()=0、亮度 0.0；
    #   b) 锁屏界面刚亮起：前台是 Windows.UI.Core.CoreWindow（锁屏自己的窗口），
    #      壁纸让亮度有 80 上下 —— 两个条件一个都不满足，于是被判成"可用"，
    #      然后在夺前台时才失败，报成 exit 3「无法进入聊天主界面」，含义完全不对。
    # 所以补一条：LogonUI 在跑，且前台是 CoreWindow，就按不可用处理（排队等解锁）。
    $fgCls = ''
    if ($fg -ne 0) { try { $fgCls = [Wx]::Cls($fg) } catch { $fgCls = '' } }
    $lockUi = ($locked -and $fgCls -eq 'Windows.UI.Core.CoreWindow')

    $usable = -not (($fg -eq 0 -and $bright -lt 2.0) -or $lockUi)
    return [pscustomobject]@{
        Usable = $usable; Fg = $fg; Brightness = $bright; LogonUI = $locked; FgCls = $fgCls
    }
}

$script:FgForced = 0
function Assert-Fg([IntPtr]$hwnd) {
    # 每次截图 / 输入前的硬闸：窗口必须存在、非最小化、可见、且是前台。
    # 否则 GetWindowRect 会返回陈旧或屏幕外的矩形（最小化时是 157x25 @(-16000,-16000)），
    # CopyFromScreen 就会抓到别的程序 —— 实测曾抓到 Claude Code 自己的窗口。
    # 这里只做"恢复 + 前台"，不改变窗口大小：候选窗口可能是辅助窗口，
    # 在甄别阶段就把它最大化会破坏用户桌面。
    if (-not [Wx]::IsWindow($hwnd)) { throw '窗口已消失' }
    if ([Wx]::IsIconic($hwnd)) {
        [Wx]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
        Start-Sleep -Milliseconds 600
    }
    if (-not [Wx]::IsWindowVisible($hwnd)) {
        # 隐藏到托盘：SW_SHOW 能同时恢复显示并前台化
        [Wx]::ShowWindow($hwnd, $SW_SHOW) | Out-Null
        Start-Sleep -Milliseconds 600
    }
    for ($i = 0; $i -lt 6; $i++) {
        if ([Wx]::GetForegroundWindow() -eq $hwnd -and -not [Wx]::IsIconic($hwnd)) { break }
        [Wx]::ShowWindow($hwnd, $SW_SHOW) | Out-Null
        # 裸的 SetForegroundWindow 在前台被别的程序占着时会静默失败，
        # 必须走 ForceForeground 去破前台锁。详见该函数注释。
        $script:FgForced++
        [Wx]::ForceForeground($hwnd) | Out-Null
        Start-Sleep -Milliseconds 400
    }
    if ([Wx]::GetForegroundWindow() -ne $hwnd) { throw '无法置于前台' }
    if ([Wx]::IsIconic($hwnd)) { throw '仍处于最小化状态' }
}

function Get-WinSize([IntPtr]$hwnd) {
    $r = New-Object RECT
    [Wx]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    return [pscustomobject]@{ W = ($r.Right - $r.Left); H = ($r.Bottom - $r.Top) }
}

$script:ShotN = 0

# 每次存盘前都确认截图目录还在，不能只在启动时建一次。
# 这个目录里的截图含聊天内容，看完按规矩要整个删掉（`rm -rf "$TEMP/wx_send_shots"`），
# 于是"目录被删掉"是正常操作而不是异常：删在两次发送之间没事，删在本进程启动之后、
# 某次存盘之前，`$bmp.Save()` 就抛「GDI+ 中发生一般性错误」—— 那句报错什么都不说，
# 只让整次发送以退出码 1 失败（2026-09-19 真踩过一次）。
# 回来的只有 $true/$false：调用方只在真的重建了目录时才记一行日志，
# 正常情况下不该往日志里灌 8 条"目录还在"。
function Ensure-ShotDir {
    if (Test-Path -LiteralPath $script:Shots) { return $false }
    New-Item -ItemType Directory -Path $script:Shots -Force | Out-Null
    return $true
}

function Get-WinShot([IntPtr]$hwnd, [string]$tag) {
    Assert-Fg $hwnd
    Start-Sleep -Milliseconds 220
    $r = New-Object RECT
    [Wx]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -lt 300 -or $h -lt 200) { throw ("窗口尺寸异常: {0}x{1}" -f $w, $h) }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    $script:ShotN++
    $path = Join-Path $script:Shots ("{0:d2}_{1}.png" -f $script:ShotN, $tag)
    if (Ensure-ShotDir) { Log ("   截图目录不在了，已重建: {0}" -f $script:Shots) }
    try {
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } catch {
        # GDI+ 的报错只有一句「一般性错误」，不说是哪个文件、为什么。
        # 上面刚确认过目录，那剩下的可能是磁盘满、路径被占、权限 —— 把路径带上，
        # 好让下一次排查有个起点，别再只剩一句"退出码 1"。
        throw ("截图存盘失败({0}): {1}" -f $path, $_.Exception.Message)
    } finally {
        $bmp.Dispose()
    }
    return [pscustomobject]@{ Path = $path; L = $r.Left; T = $r.Top; W = $w; H = $h }
}

# 裸点击：只在能确保「截图到点击之间没有耗时步骤」时才可用。
# 本脚本里每次点击前都隔着一次约 10 秒的 OCR，所以一律走 Click-Live，
# 这个函数目前没有调用点，保留只为对照说明。
function Click-InWin($shot, [int]$ix, [int]$iy) { [Wx]::Click(($shot.L + $ix), ($shot.T + $iy)) }

function Click-Live([IntPtr]$hwnd, $shot, [int]$ix, [int]$iy) {
    # 点击前必须重新确认前台并重读窗口原点。原因：OCR 一步要 10 秒上下，
    # 从截图到点击之间前台可能已经被别的程序抢走（实测抢走后这一下点在别人窗口上，
    # 随后的 ^v 也粘到别人那里，日志却一切正常，只在校验时才暴露）；窗口若被挪动，
    # $shot 里记的原点也就过期了。窗口内的相对坐标仍然有效，重读原点即可。
    Assert-Fg $hwnd
    $r = New-Object RECT
    [Wx]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    if (($r.Left -ne $shot.L) -or ($r.Top -ne $shot.T)) {
        Log ("   窗口已移动 ({0},{1})->({2},{3})，按新原点点击" -f $shot.L, $shot.T, $r.Left, $r.Top)
    }
    [Wx]::Click(($r.Left + $ix), ($r.Top + $iy))
}

# ---------------------------------------------------------------- 像素级几何自标定
function Px-Diff($a, $b) {
    return ([math]::Abs($a.R - $b.R) + [math]::Abs($a.G - $b.G) + [math]::Abs($a.B - $b.B))
}

function Measure-Ink([string]$shotPath, [int]$x0, [int]$x1, [int]$y0, [int]$y1, [int]$minDev) {
    # 数指定矩形里「有字的列数」，用来在 OCR 读不出正文时判断输入框是空的还是有字。
    # 数列数而不是数像素：空框里的文本光标实测 4px 宽、37px 高（200% 缩放），
    # 按像素数它和一个汉字同量级，按列数它只占 4 列，而一个汉字至少 14 列
    # （100% 缩放），这个判据跨缩放比例都分得开。
    # $minDev 是「算不算有字」的亮度偏离门槛，比 Find-* 系列的 8/20 大得多：
    # 那两处找的是背景色之间的细微边界，这里要分的是底色和文字。
    # 调用方必须显式给值，因为空输入框并不是纯底色 —— WeChat 会在里面画一行
    # 淡色提示文字（实测 10 个字符、约 263 列）。实测三档亮度：
    # 底色 35、提示文字峰值 123（偏离 88）、真正的正文峰值 224（偏离 189）。
    # 要把提示文字和正文分开就得取 130 上下，取 40 会把提示文字也数成有字。
    $bmp = New-Object System.Drawing.Bitmap($shotPath)
    try {
        $x0 = [math]::Max(0, $x0); $y0 = [math]::Max(0, $y0)
        $x1 = [math]::Min($bmp.Width - 1, $x1); $y1 = [math]::Min($bmp.Height - 1, $y1)
        if ($x1 -le ($x0 + 8) -or $y1 -le ($y0 + 4)) { return -1 }
        # 底色取该区域亮度众数（底色占绝对多数），不写死数值，深浅主题都适用。
        $hist = New-Object 'int[]' 256
        for ($y = $y0; $y -le $y1; $y += 4) {
            for ($x = $x0; $x -le $x1; $x += 4) {
                $c = $bmp.GetPixel($x, $y)
                $hist[[int](($c.R + $c.G + $c.B) / 3)]++
            }
        }
        $bg = 0; $best = -1
        for ($i = 0; $i -lt 256; $i++) { if ($hist[$i] -gt $best) { $best = $hist[$i]; $bg = $i } }
        $cols = 0
        for ($x = $x0; $x -le $x1; $x++) {
            for ($y = $y0; $y -le $y1; $y += 3) {
                $c = $bmp.GetPixel($x, $y)
                if ([math]::Abs([int](($c.R + $c.G + $c.B) / 3) - $bg) -gt $minDev) { $cols++; break }
            }
        }
        return $cols
    } finally { $bmp.Dispose() }
}

function Find-Divider($bmp, [int]$w, [int]$h) {
    # 会话列表与聊天面板之间的竖直分栏线：
    # 在多条横向扫描线上都发生色变的那一列（列表背景与面板背景亮度不同）。
    $ys = @(); for ($k = 2; $k -le 10; $k++) { $ys += [int]($h * $k / 12.0) }
    $n = $ys.Count
    $x0 = [int](0.08 * $w); $x1 = [int](0.40 * $w)
    if ($x1 -le ($x0 + 2)) { return [int](0.21 * $w) }
    $hit = New-Object 'int[]' ($w)
    foreach ($y in $ys) {
        $p = $bmp.GetPixel($x0, $y)
        for ($x = $x0 + 1; $x -lt $x1; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if ((Px-Diff $c $p) -gt 20) { $hit[$x]++ }
            $p = $c
        }
    }
    # 由严到宽找：命中行数最多的、最右边的那一列
    for ($t = $n; $t -ge [int]([math]::Ceiling($n * 0.8)); $t--) {
        for ($x = $x1 - 1; $x -gt $x0; $x--) { if ($hit[$x] -ge $t) { return $x } }
    }
    return [int](0.21 * $w)
}

function Find-InputBox($bmp, [int]$w, [int]$h, [int]$divX) {
    # 输入框上边框的判据是「左端紧贴分栏线」，不是「覆盖率高」也不是「y 最小」。
    # 实测三类横线（面板宽 1555 与 2283 两种窗口都一致）：
    #   消息气泡边缘   左端距分栏线 460~816   覆盖率 26~64%
    #   输入框上下边框 左端距分栏线 24~28     覆盖率 58~96%
    #   窗口外框       左端距分栏线 8         覆盖率 99~100%
    # 覆盖率随窗口宽度剧烈波动（宽窗口右侧还有一栏空面板会把它摊薄），不能当主判据；
    # 左端内缩量则稳定。窗口外框用"排除底部 2.5% 高度"剔掉。
    $panelW = $w - $divX
    if ($panelW -lt 200) { return $null }
    $step = 4
    $insetMin = [int](0.008 * $panelW); if ($insetMin -lt 12) { $insetMin = 12 }
    $insetMax = [int](0.04 * $panelW); if ($insetMax -lt 40) { $insetMax = 40 }
    # 扫到贴底：窗口外框内缩量只有 8px，已被 insetMin 挡掉，不必再靠高度排除，
    # 这样才能拿到输入框真正的下边框（实测 h=1703 时在 1677，0.975H 会把它切掉）。
    $yStop = $h - 6

    $rows = New-Object System.Collections.ArrayList
    for ($y = [int](0.55 * $h); $y -lt $yStop; $y++) {
        $lo = -1; $hi = -1; $cnt = 0; $tot = 0
        for ($x = $divX + 8; $x -lt ($w - 4); $x += $step) {
            $tot++
            if ((Px-Diff $bmp.GetPixel($x, $y) $bmp.GetPixel($x, $y - 1)) -gt 8) {
                $cnt++
                if ($lo -lt 0) { $lo = $x }
                $hi = $x
            }
        }
        if ($tot -eq 0 -or $lo -lt 0) { continue }
        $inset = $lo - $divX
        $cov = $cnt / [double]$tot
        if ($inset -ge $insetMin -and $inset -le $insetMax -and
            $cov -ge 0.40 -and ($hi - $lo) -ge ($panelW * 0.40)) {
            $null = $rows.Add([pscustomobject]@{ Y = $y; L = $lo; R = $hi })
        }
    }
    if ($rows.Count -eq 0) { return $null }
    $first = $rows | Select-Object -First 1
    $topY = $first.Y; $bl = $first.L; $br = $first.R
    $last = $rows | Select-Object -Last 1
    $botY = if ($last.Y -gt ($topY + 60)) { $last.Y } else { [int]($h * 0.96) }

    # 点击点：横向贴左边框内侧，纵向取框内上部，避开底部那排工具栏图标
    # （表情/文件/剪刀/话筒在框底上方约 40px，「发送」按钮在右下角）。
    $cx = $bl + 60
    if ($cx -gt ($br - 40)) { $cx = [int](($bl + $br) / 2) }
    $dy = [int](($botY - $topY) * 0.25)
    if ($dy -lt 25) { $dy = 25 }
    if ($dy -gt 90) { $dy = 90 }
    $cy = $topY + $dy
    return [pscustomobject]@{ L = $bl; T = $topY; R = $br; B = $botY; CX = $cx; CY = $cy }
}

function Get-Geometry([string]$shotPath) {
    $bmp = New-Object System.Drawing.Bitmap($shotPath)
    try {
        $w = $bmp.Width; $h = $bmp.Height
        $divX = Find-Divider $bmp $w $h
        $ib = Find-InputBox $bmp $w $h $divX
        return [pscustomobject]@{ W = $w; H = $h; DivX = $divX; Input = $ib }
    } finally { $bmp.Dispose() }
}

function Get-ChatTitle($ocr, $geo) {
    # 聊天标题 = 分栏线右侧、顶部横带内、最左边的那行"真文字"。
    # 必须过滤 OCR 噪声：图标常被识别成 'O' / '0' / '囗' 之类的单字符。
    $top = [int](0.025 * $geo.H); $bot = [int](0.085 * $geo.H)
    $c = $ocr | Where-Object {
        $_.X -gt $geo.DivX -and $_.Y -ge $top -and $_.Y -le $bot -and
        $_.W -ge 40 -and ($_.NText.Length -ge 2 -or $_.NText -match '[一-鿿]')
    } | Sort-Object X
    if ($c) { return ($c | Select-Object -First 1) }
    return $null
}

# 标题是否就是目标会话。群聊标题后面会跟成员数：目标「项目组」，
# 微信标题栏显示「项目组（5）」，精确相等一比就崩，群聊会全部发不出去。
# 放宽只允许这一种形态：目标名 + 末尾一对括号 + 括号里纯数字，别的一律不放过。
#   放行：项目组（5）  项目组(5)
#   拦住：项目组的群   小明和项目组   项目组（老板）
# 这是防发错人的闸，放宽必须窄 —— 用 Escape 把目标名当字面量，正则锚死两头，
# 括号里只认 \d+，所以它不可能把另一个人的名字放进来。
function Test-TitleIsTarget([string]$nTitle, [string]$nTarget) {
    if ([string]::IsNullOrEmpty($nTitle)) { return $false }
    # 目标空串时正则会退化成只剩括号那截，「（5）」这种标题就被放行了。
    # 主流程已经提前拦了空目标，这里再短路一次：这是闸，不留退化路径。
    if ([string]::IsNullOrEmpty($nTarget)) { return $false }
    if ($nTitle -eq $nTarget) { return $true }
    $re = '^' + [regex]::Escape($nTarget) + '(?:（\d+）|\(\d+\))$'
    return ($nTitle -match $re)
}

function Set-Clip([string]$text) {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Set-Clipboard -Value $text
            Start-Sleep -Milliseconds 120
            $back = Get-Clipboard -Raw
            if ($null -ne $back -and (Norm $back) -eq (Norm $text)) { return $true }
        } catch { Start-Sleep -Milliseconds 200 }
    }
    return $false
}

# ================================================================ 主流程
$script:Shots = if ($ShotDir) { $ShotDir } else { Join-Path $env:TEMP 'wx_send_shots' }
$null = Ensure-ShotDir     # 启动时建一次；之后每次存盘前 Get-WinShot 还会再确认

$nTarget = Norm $Target
# -Target 只给空白（' '）时 Norm 之后是空串，那样标题闸没有可比的东西，
# 不该让它往下走到"点开某个会话再说"。
if ([string]::IsNullOrWhiteSpace($nTarget)) { Log '!! 目标会话名为空'; exit 1 }
$body = if ($MessageFile) {
    if (-not (Test-Path $MessageFile)) { Log "!! 消息文件不存在: $MessageFile"; exit 1 }
    [System.IO.File]::ReadAllText($MessageFile, [System.Text.Encoding]::UTF8)
} else { $Message }
if ([string]::IsNullOrWhiteSpace($body)) { Log '!! 消息正文为空'; exit 1 }
$lines = ($body -replace "`r`n", "`n" -replace "`r", "`n").Split("`n")

# 串行化：多个 hook、多个 Claude 会话可能同时触发，绝不能同时抢焦点操作微信。
# 'Global\' 前缀是关键：不加就只在当前会话(登录 session)内互斥，跨会话等于没锁。
$mutex = New-Object System.Threading.Mutex($false, 'Global\WxSendSkillMutex')
$owned = $false
# 一次完整发送实测 60~70 秒（标题核对和粘贴校验各要几轮 OCR）。超时必须显著大于
# 单次耗时，否则前面那个还在正常干活，后面这个就超时放弃了 —— 锁在，却没排上队。
$lockWaitMs = 300000
try {
    # 先探一次不等待的：拿到就直接走。这样"排队中"那行日志只在真排队时才出现。
    $owned = $mutex.WaitOne(0)
    if (-not $owned) {
        Log ("另一个发送任务正在进行，排队等待（最长 {0} 秒）…" -f [int]($lockWaitMs / 1000))
        $owned = $mutex.WaitOne($lockWaitMs)
    }
} catch [System.Threading.AbandonedMutexException] {
    # 上一个持有者进程被杀或崩溃，没走到 ReleaseMutex。抛这个异常时锁其实已经归我们了，
    # 当成失败就会既不发送也不释放、白等一场，所以必须认成拿到。
    $owned = $true
    Log '!! 上一个发送任务异常终止（锁被遗弃），已接管'
} catch {
    $owned = $false
}
if (-not $owned) {
    Log ("!! 排队等待 {0} 秒仍未轮到，放弃未发送（稍后重试即可）" -f [int]($lockWaitMs / 1000))
    exit 9
}

$origClip = $null
try { $origClip = Get-Clipboard -Raw } catch {}
$origFg = [Wx]::GetForegroundWindow()
# 指针原位：整条流程会点会话行和输入框，把鼠标挪到微信窗口里去。
# 在场判断通常保证这会儿人不在，但人随时可能回来，收尾要把指针放回去。
$origPos = New-Object Wx+POINT
$origPosOk = $false
try { $origPosOk = [Wx]::GetCursorPos([ref]$origPos) } catch { $origPosOk = $false }
$code = 1

try {
    # ---- 0. 桌面可用性闸：锁屏时直接失败，不要白折腾 20 秒再报个误导性的错 ----
    $du = Test-DesktopUsable
    if (-not $du.Usable) {
        Log ("!! 桌面当前不可交互（前台窗口={0} 类名={1} 截图亮度={2:N1}/255 LogonUI={3}）" -f `
                $du.Fg, $du.FgCls, $du.Brightness, $du.LogonUI)
        Log '   锁屏或屏幕关闭时无法截图/点击，微信 GUI 自动化必然失败。消息未发送。'
        exit 8
    }
    # ---- 1. 找窗口 ----
    $procs = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '^(Weixin|WeChat)$' })
    if ($procs.Count -eq 0) { Log '!! 微信进程未运行'; exit 2 }
    $pids = @($procs | Select-Object -ExpandProperty Id)

    # 候选优先级：
    #  1) 进程的 MainWindowHandle —— 最可靠（实测正确指向真正的主窗口）
    #  2) EnumWindows 里标题/类名匹配的，非最小化优先
    # 不能只按"非最小化 + 面积最大"选：微信有个标题为 Weixin 的空白辅助窗口，
    # 主窗口最小化时它会被误选（实测把它最大化后截到一片白）。
    $cands = New-Object System.Collections.ArrayList
    foreach ($p in $procs) {
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $null = $cands.Add($p.MainWindowHandle) }
    }
    $wins = [Wx]::Enum([uint32[]]$pids)
    $named = $wins | Where-Object {
        $_.Title -match '^(微信|Weixin|WeChat)$' -and
        $_.Cls -match '^(Qt\d+QWindowIcon|WeChatMainWndForPC|mmui::MainWindow)$'
    } | Sort-Object @{E = { if ($_.Title -eq '微信') { 0 } else { 1 } } }, @{E = { -($_.W * $_.Ht) } }
    foreach ($w in $named) { if (-not $cands.Contains($w.H)) { $null = $cands.Add($w.H) } }
    if ($cands.Count -eq 0) { Log '!! 未找到微信主窗口，请确认微信已登录'; exit 2 }

    # ---- 2. 前台化、截图、并验证确实是聊天主界面 ----
    # 注意：绝不发送 {ESC}，微信 4.x 会把它当作「隐藏到托盘」。
    $hwnd = [IntPtr]::Zero; $s1 = $null; $geo = $null; $ocr1 = $null
    foreach ($h in $cands) {
        # 记下原始状态，甄别失败时还原，不留痕
        $wasVisible = [Wx]::IsWindowVisible($h)
        $wasIconic = [Wx]::IsIconic($h)
        $ok = $false
        try {
            Assert-Fg $h
            $sz = Get-WinSize $h
            if ($sz.W -lt 700 -or $sz.H -lt 500) {
                # 过小，界面会挤到定位不出分栏。先最大化再判。
                [Wx]::ShowWindow($h, $SW_MAXIMIZE) | Out-Null
                Start-Sleep -Milliseconds 800
            }
            $shot = Get-WinShot $h 'init'
            $g = Get-Geometry $shot.Path
            $o = Invoke-Ocr $shot.Path
            # 主界面判据：能找到分栏线和输入框，且分栏线左侧有足够多的会话行文字。
            # 空白辅助窗口过不了这一关（实测那个标题为 Weixin 的窗口截出来一片白）。
            # 只看会话列表，不要求输入框存在：主窗口右侧可能正停在
            # 公众号/朋友圈等没有输入框的页面，那依然是主窗口。
            # 空白辅助窗口一行文字都没有，靠 listRows 就能剔掉。
            $listRows = @($o | Where-Object { $_.X -lt $g.DivX -and $_.Y -gt [int](0.06 * $g.H) }).Count
            if ($listRows -ge 4) {
                $hwnd = $h; $s1 = $shot; $geo = $g; $ocr1 = $o; $ok = $true
                Log ("主窗口 h={0} {1}x{2} @({3},{4}) 分栏线 x={5} 列表行数={6}" -f $h, $shot.W, $shot.H, $shot.L, $shot.T, $g.DivX, $listRows)
                break
            }
            Log ("h={0} 不像聊天主界面（输入框={1} 列表行数={2}），换下一个" -f $h, [bool]$g.Input, $listRows)
        } catch {
            Log ("h={0} 甄别失败: {1}" -f $h, $_.Exception.Message)
        } finally {
            if (-not $ok) {
                if (-not $wasVisible) { [Wx]::ShowWindow($h, 0) | Out-Null }       # SW_HIDE
                elseif ($wasIconic) { [Wx]::ShowWindow($h, 6) | Out-Null }         # SW_MINIMIZE
            }
        }
    }
    if ($hwnd -eq [IntPtr]::Zero) { Log '!! 找到微信窗口但无法进入聊天主界面'; exit 3 }

    # ---- 3. 定位目标会话 ----
    # 先看它是不是已经开着：点击列表行是个开关，对着已打开的会话再点一下会把它关掉，
    # 右栏随之变空，表现为后面"标题(未识别)"重试到底全败。实测因此出现严格隔一次
    # 失败：上一轮把会话留在打开状态，下一轮那一点就给关了。已开着就别点。
    $already = Get-ChatTitle $ocr1 $geo
    if ($already -and (Test-TitleIsTarget $already.NText $nTarget)) {
        Log ("「{0}」已在前台会话，跳过点击" -f $Target)
        $hit = $null
        $skipOpen = $true
    } else {
        $skipOpen = $false
        $hit = $ocr1 | Where-Object {
            $_.X -lt $geo.DivX -and $_.Y -gt [int](0.06 * $geo.H) -and $_.NText -eq $nTarget
        } | Sort-Object Y | Select-Object -First 1
    }

    if ($skipOpen) {
        # 什么都不做，直接进标题核对
    }
    elseif ($hit) {
        Log ("列表命中「{0}」 at ({1},{2})  [强夺前台 {3} 次]" -f `
                $Target, $hit.X, $hit.Y, $script:FgForced)
        # 必须用 Click-Live：$s1 是 OCR 之前截的，到这里已经过期约 10 秒，
        # 期间前台可能被抢走。这一下点空了会话就没打开，后面标题栏整个是空的，
        # 于是表现为"标题(未识别)"重试四次全败 —— 重截图救不了，得点对。
        Click-Live $hwnd $s1 ([int]($hit.X + 84)) ([int]($hit.CY))
        Start-Sleep -Milliseconds 700
    } else {
        # ---- 3b. 搜索兜底 ----
        Log "列表里没有，改用搜索"
        if (-not (Set-Clip $Target)) { Log '!! 剪贴板写入失败'; exit 1 }
        Send-Keys '^f'
        Start-Sleep -Milliseconds 450
        Send-Keys '^v'
        Start-Sleep -Milliseconds 1100

        $s2 = Get-WinShot $hwnd 'search'
        $ocr2 = Invoke-Ocr $s2.Path
        $g2 = Get-Geometry $s2.Path
        # 不能按回车：高亮行是「搜索网络结果」。要点击真实条目。
        # 分栏线必须用搜索前那张图测出来的：搜索面板一铺开 Find-Divider 就测偏
        # （实测 613 -> 246），分组标签(x=269)和结果行(x=357)全落到测出来的线右边，
        # 被下面的 X 过滤连着筛掉 —— 屏幕上结果明明在，脚本却报「没找到」。
        # 不取两者较大值：万一搜索图测出个偏大的线，右栏文本（标题栏等）会被拉进
        # 候选，那是发错人的风险。搜索前那张是干净屏，用它。
        $divX = $geo.DivX
        # 用「聊天记录」当上界，而不是拿第一个分组标签当下界。
        # 原来那版取第一个匹配 ^(功能|联系人|聊天|通讯录|群聊)$ 的标签当下界，实测会错：
        # 给对方发过消息后，联系人头上的标签从「联系人」变成「最常使用」，不在正则里，
        # 于是锚点跳到更下面的「群聊」，把真联系人(y=258)排除掉，选中了「聊天记录」
        # 分组里文本同样是目标名的那一行(y=946) —— 点进去是消息搜索视图不是会话，
        # 标题闸报 exit 5。往正则里继续堆标签名补不完（微信改版 + OCR 读错）。
        # 聊天记录命中点开永远不是会话，联系人和群聊都排在它上面，所以切在这里。
        $cutY = $g2.H
        $histLabel = $ocr2 | Where-Object {
            $_.X -lt $divX -and $_.NText -match '^(聊天记录|相关聊天记录)$'
        } | Sort-Object Y | Select-Object -First 1
        if ($histLabel) { $cutY = $histLabel.Y }
        # 下界只为跳过搜索框本身（框里是目标名，OCR 常带个放大镜前缀）。
        $yMin = [int](0.06 * $g2.H)
        $pick = $ocr2 | Where-Object {
            $_.X -lt $divX -and $_.Y -gt $yMin -and $_.Y -lt $cutY -and $_.NText -eq $nTarget
        } | Sort-Object Y | Select-Object -First 1
        if (-not $pick) {
            # 只报数量不报内容：左栏是用户的私人会话和联系人，不往输出里倒。
            $nLeft = @($ocr2 | Where-Object {
                    $_.X -lt $divX -and $_.Y -gt $yMin -and $_.Y -lt $cutY
                }).Count
            Log ("!! 搜索结果里也没找到「{0}」 (divX={1} y 窗口={2}..{3} 候选行={4})" -f `
                    $Target, $divX, $yMin, $cutY, $nLeft)
            exit 4
        }
        Log ("搜索命中 at ({0},{1})" -f $pick.X, $pick.Y)
        Click-Live $hwnd $s2 ([int]($pick.X + 84)) ([int]($pick.CY))
        Start-Sleep -Milliseconds 900
    }

    # ---- 4. 安全闸：核对聊天标题 ----
    # 这一步不可省。实测打开的会话可能是别人（曾经是用户配偶的窗口），
    # 标题不符就必须在输入任何内容之前中止。
    # 重试是必要的：点完会话行，界面不一定立刻渲染好，实测大约一半的次数
    # 第一张截图里标题还没出来（或只出来一半），直接判失败会误报。
    # 重试只是反复「看」，任何一次都不会输入内容，所以不削弱安全性：
    # 仍然只有在确认标题 == 目标时才往下走。
    $s3 = $null; $g3 = $null; $title = $null; $lastSeen = ''; $ocr3 = $null
    for ($try = 1; $try -le 4; $try++) {
        if ($try -gt 1) { Start-Sleep -Milliseconds 700 }
        $s3 = Get-WinShot $hwnd ('opened{0}' -f $try)
        $g3 = Get-Geometry $s3.Path
        $ocr3 = Invoke-Ocr $s3.Path
        $t = Get-ChatTitle $ocr3 $g3
        if ($t -and (Test-TitleIsTarget $t.NText $nTarget)) { $title = $t; break }
        $lastSeen = if ($t) { $t.NText } else { '(未识别)' }
        Log ("   第 {0} 次核对标题：{1}，重试" -f $try, $lastSeen)
    }
    if (-not $title) {
        Log ("!! 标题核对失败（最后看到：{0}，目标：{1}），为避免发错人已中止，未输入任何内容" -f $lastSeen, $Target)
        exit 5
    }
    Log ("聊天标题 = 「{0}」 (x={1},y={2})" -f $title.NText, $title.X, $title.Y)

    # ---- 5~7. 聚焦输入框 -> 粘贴 -> 校验，失败就整体重来 ----
    # 合成一个循环而不是三步直线，因为失焦是常态而非异常：每次 OCR 要 10 秒，
    # 期间前台可能被别的程序抢走，这一轮的点击和 ^v 就全落到别人窗口上。
    # 单次失败不该直接放弃 —— 重新聚焦再粘一遍通常就好了。
    # 探针只做「包含子串」判断，所以下面一律用 .Contains()，不要用 -like：
    # 正文里的方括号在通配符里是字符类，而我们每条通知都以「[Claude Code]」开头，
    # 用 -like 会直接抛「指定的通配符模式无效: *[ClaudeC*」，等于条条都发不出去。
    # 探针要躲开数字和标点：OCR 在这两类字符上很不可靠。实测补发那条的第一行
    # 「[补发 09-19 19:03]」被读成「[补发09．1919：03]」—— 连字符成了全角句点、
    # 冒号成了全角冒号，于是探针 [补发09-1 永远匹配不上，粘贴明明成功却判成失败，
    # 重试三次后 exit 7。所以只保留字母和汉字来构造探针，
    # 并且跨行取（第一行可能是 [补发 ...] 这种全是数字标点的前缀，剥完剩不下几个字）。
    # 必须取自单独一行，不能跨行拼：OCR 是按行给结果的，拼出来的串不会出现在
    # 任何一行里，Contains 永远为假。挑第一行剥完还剩 4 个字以上的
    #（补发那条的第一行「[补发 09-19 19:03]」只剩「补发」两个字，太短，跳过它，
    # 用下一行「[Claude Code] 长任务已完成」）。
    $probe = ''
    foreach ($ln in $lines) {
        $c = ((Norm $ln) -replace '[^\p{L}]', '')
        if ($c.Length -ge 4) { $probe = $c; break }
    }
    if ($probe.Length -gt 10) { $probe = $probe.Substring(0, 10) }
    # 兜底：整条正文没有任何一行剥完还剩 4 个字（几乎不可能），退回原来的取法。
    if (-not $probe) {
        $probe = (Norm $lines[0])
        if ($probe.Length -gt 8) { $probe = $probe.Substring(0, 8) }
    }
    if (-not $probe) { $probe = '.' }   # 空探针会让 Contains 恒真，兜一下
    Log ("探针 = 「{0}」" -f $probe)

    # 上一次运行可能粘好了正文却在回车前失手（实测：回车前的 Assert-Fg 抢不回前台，
    # 于是 exit 1 转入队列重试）。那段残留还在输入框里，这一轮直接再粘就会发出重复内容。
    # 所以开粘之前先看一眼：只有当框里已经出现本条消息的探针时才清，
    # 避免把用户自己存在该会话里的草稿一并删掉。
    $leftover = $false
    if ($g3.Input -and $ocr3) {
        foreach ($o in $ocr3) {
            if ($o.Y -ge ($g3.Input.T - 5) -and $o.X -gt $g3.DivX -and $o.LText.Contains($probe)) {
                $leftover = $true; break
            }
        }
    }
    if ($leftover) { Log '   输入框里有本条消息的残留（上次回车前失手），先清空再粘' }

    $inBox = $false; $inkOnly = $false; $s4 = $null; $g4 = $null
    for ($att = 1; $att -le 3 -and -not $inBox; $att++) {
        $gIn = $(if ($att -eq 1) { $g3 } else { $g4 })
        $sIn = $(if ($att -eq 1) { $s3 } else { $s4 })
        if (-not $gIn.Input) { Log '!! 未能定位输入框'; exit 7 }
        if ($att -gt 1 -or $leftover) {
            # 重来之前先清掉上一轮可能残留在框里的半截正文，否则会叠字。
            # 这时焦点未必在输入框，所以先点一下再清。
            Log ("   第 {0} 次尝试粘贴（先清空输入框）" -f $att)
            Click-Live $hwnd $sIn $gIn.Input.CX $gIn.Input.CY
            Start-Sleep -Milliseconds 250
            Send-Keys '^a'; Start-Sleep -Milliseconds 120
            Send-Keys '{DELETE}'; Start-Sleep -Milliseconds 200
        }
        Log ("输入框 x={0}..{1} top={2} -> 点击 ({3},{4})" -f $gIn.Input.L, $gIn.Input.R, $gIn.Input.T, $gIn.Input.CX, $gIn.Input.CY)
        Click-Live $hwnd $sIn $gIn.Input.CX $gIn.Input.CY
        Start-Sleep -Milliseconds 350

        # 粘之前先量一次输入框首行的「有字列数」，给下面 OCR 读不出时留个后路。
        # 必须在点击并清空之后、粘贴之前量，而且两次要用同一个矩形才可比。
        $ibox = $gIn.Input
        $inkX0 = $ibox.L + 6; $inkX1 = $ibox.R - 6
        $bandH = [int](($ibox.B - $ibox.T) * 0.30); if ($bandH -lt 30) { $bandH = 30 }
        $inkY0 = $ibox.T + 4; $inkY1 = $ibox.T + $bandH
        $sBase = Get-WinShot $hwnd ('base{0}' -f $att)
        $inkBase = Measure-Ink $sBase.Path $inkX0 $inkX1 $inkY0 $inkY1 130

        # 逐行粘贴，行间用 Shift+Enter 换行，保证回车只在最后按一次。
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -gt 0) { Send-Keys '+{ENTER}'; Start-Sleep -Milliseconds 120 }
            $ln = $lines[$i]
            if ([string]::IsNullOrEmpty($ln)) { continue }
            if (-not (Set-Clip $ln)) { Log '!! 剪贴板写入失败'; exit 1 }
            Assert-Fg $hwnd        # ^v 之前再确认一次，别粘到别人窗口里
            Send-Keys '^v'
            Start-Sleep -Milliseconds 220
        }
        # 把光标移回正文开头。输入框是可滚动的：正文一长，粘完光标停在末尾，
        # 开头几行已经滚出可见区 —— 而 $probe 取的正是第一行，于是 OCR 看不到它，
        # 明明粘成功了却判成失败，重试三次全败后 exit 7。
        # 补发的消息更容易撞上：多了 [补发 ...] 前缀，正文更长。
        # 这一下只移动光标不改内容，后面的回车照样发整条。
        Send-Keys '^{HOME}'
        Start-Sleep -Milliseconds 400

        $s4 = Get-WinShot $hwnd ('typed{0}' -f $att)
        $g4 = Get-Geometry $s4.Path
        if ($g4.Input) {
            foreach ($o in (Invoke-Ocr $s4.Path)) {
                if ($o.Y -ge ($g4.Input.T - 5) -and $o.X -gt $g4.DivX -and $o.LText.Contains($probe)) { $inBox = $true; break }
            }
        }

        # OCR 没读到不等于没粘上。实测：整行只由同一个汉字组成时（「哈」「哈哈」
        # 「哈哈哈」「哈哈哈哈」都试过），Windows OCR 干脆不把它当成一行文本，
        # 一条结果都不返回 —— 掺进任何一个别的字（「哈哈哈好」「你哈哈哈」）立刻就能读。
        # 「好好好」正常，所以不是重复字的问题。这类正文靠探针永远校验不过，
        # 粘贴明明成功却重试三次后 exit 7，等于这条消息永远发不出去。
        # 所以再给一条不依赖 OCR 的判据：同一矩形的有字列数从「空」涨到「有字」。
        # 只在框原本基本是空的时候才认这条 —— 否则框里那点字可能是用户自己的草稿或
        # 上一轮的残留，认了就会把不该发的内容发出去。基线不干净就让下一轮先清空重来。
        if (-not $inBox) {
            $inkNow = Measure-Ink $s4.Path $inkX0 $inkX1 $inkY0 $inkY1 130
            # 阈值按实测定（200% 缩放、深色主题）：空框在 130 门槛下是 0 列
            # —— 淡色提示文字被门槛挡掉了，文本光标最多再添 4 列；三个汉字 63 列。
            # 涨幅门槛跟着首行带高走而不写死：字宽和带高都随 DPI 等比缩放，
            # 实测单字 21 列 / 带高 85 ≈ 0.25，取 0.15 倍，100% 缩放下也容得下单个汉字。
            $inkNeed = [math]::Max(6, [int](0.15 * $bandH))
            if ($inkBase -ge 0 -and $inkNow -ge 0 -and $inkBase -le 6 -and ($inkNow - $inkBase) -ge $inkNeed) {
                $inBox = $true; $inkOnly = $true
                Log ("   OCR 读不出这条正文，改用像素判据：有字列数 {0} -> {1}" -f $inkBase, $inkNow)
            } else {
                Log ("   第 {0} 次粘贴后仍未在输入框看到正文（有字列数 {1} -> {2}，需基线<=6 且涨幅>={3}）" -f `
                        $att, $inkBase, $inkNow, $inkNeed)
            }
        }
    }
    if (-not $inBox) {
        Log '!! 正文未出现在输入框区域，可能焦点始终不在输入框。已中止，不按回车。'
        Log ("   截图: {0}" -f $s4.Path)
        $KeepShots = $true
        exit 7
    }
    if ($inkOnly) {
        Log '正文已在输入框中（像素判据：框从空变成有字；OCR 读不出这条正文）'
    } else {
        Log '正文已在输入框中'
    }

    if ($DryRun) {
        # 上一步的 OCR 确认过正文在输入框里，但那张截图之后又过了约 10 秒，
        # 前台可能已经被抢走 —— 此时 ^a + DELETE 会打在别人窗口上，
        # 那是在别的程序里全选删除，后果比发错消息更严重。必须先夺回前台。
        Assert-Fg $hwnd
        Send-Keys '^a'; Start-Sleep -Milliseconds 150
        Send-Keys '{DELETE}'; Start-Sleep -Milliseconds 200
        Log '-- DryRun：不按回车，已清空输入框，流程结束。'
        $code = 0
        exit 0
    }

    # ---- 8. 发送 ----
    Assert-Fg $hwnd            # 同理：校验截图到这里又过了约 10 秒
    Send-Keys '{ENTER}'
    Start-Sleep -Milliseconds 1100

    # ---- 9. 确认已发出 ----
    # 判据是两条，缺一不可：
    #   a) 输入框里已经没有正文了 —— 这条才是真正能认出失败的那一条；
    #   b) 消息区出现了正文。
    # 为什么不能只看 (b)：$probe 是正文第一行的前 8 个字符，归一化后恒为 "[ClaudeC"，
    # 三种触发完全一样。只看 (b) 等于问"消息区里有没有任何一条通知"，那么只要历史
    # 记录里还留着一条旧通知在可见范围内，这次不管发没发出去都判成成功 ——
    # 恰好把"回车没生效"这个最该被队列救回来的失败模式报成 rc 0 静默丢掉。
    # 而 (a) 不受这个影响：第 7 步刚确认过正文在输入框里，回车生效的唯一表现就是它
    # 被清空。输入框是个小区域，不存在历史残留混进来。
    $s5 = Get-WinShot $hwnd 'sent'
    $g5 = Get-Geometry $s5.Path
    $ocr5 = Invoke-Ocr $s5.Path
    # 输入框没定位到时退回用窗口高度划界，别让 $g5.Input.T 直接抛空引用：
    # 走到这一步回车已经按下去了，消息很可能已经发出，此时崩掉会误报成失败。
    # 这种降级情况下 (a) 查不了，只能退回旧的单条判据。
    $msgBot = $(if ($g5.Input) { $g5.Input.T - 20 } else { [int](0.80 * $g5.H) })
    $inMsg = $false
    $stillInBox = $false
    foreach ($o in $ocr5) {
        if ($o.X -le $g5.DivX) { continue }
        if (-not $o.LText.Contains($probe)) { continue }
        if ($o.Y -lt $msgBot) { $inMsg = $true }
        elseif ($g5.Input -and $o.Y -ge ($g5.Input.T - 5)) { $stillInBox = $true }
    }
    if ($stillInBox) {
        # 唯一能确定是失败的情形：第 7 步刚确认正文在框里，回车生效就该把它清空。
        Log '!! 回车后正文仍在输入框里，判定未发出（会转入队列重试）'
        $KeepShots = $true
        $code = 6
    }
    elseif ($inMsg) { Log '已确认发送成功'; $code = 0 }
    else {
        # 框空了但消息区没找到抬头。消息区也会滚动，长正文发出后开头可能就在
        # 可见区之上 —— 所以这不能算失败：报失败会让队列再发一遍，等于发重复。
        # "回车前在框里、回车后框空了"已经足够说明发出去了。
        Log '已发出（框已清空）；消息区未看到抬头，可能是正文过长滚出可见区'
        $code = 0
    }
    exit $code
}
catch {
    Log ("!! 异常: {0}" -f $_.Exception.Message)
    $code = 1
    exit 1
}
finally {
    if ($null -ne $origClip) { try { Set-Clipboard -Value $origClip } catch {} }
    else { try { Set-Clipboard -Value ' ' } catch {} }
    if ($origFg -ne [IntPtr]::Zero -and [Wx]::IsWindow($origFg)) {
        try { [Wx]::SetForegroundWindow($origFg) | Out-Null } catch {}
    }
    # 还原鼠标位置。放在还原前台之后：先让窗口顺序回位，再把指针放回去。
    # RestoreCursor 只在"指针还停在我们最后放的位置"时才动手 —— 中途用户自己回来动了
    # 鼠标，就不该把他的指针抢回旧位置。
    if ($origPosOk) {
        try { if ([Wx]::RestoreCursor($origPos)) { Log '鼠标位置已还原' } } catch {}
    }
    if (-not $KeepShots) {
        try { Get-ChildItem -Path $script:Shots -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
    } else {
        Log ("截图保留在: {0}" -f $script:Shots)
    }
    if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
    try { $mutex.Dispose() } catch {}
}
