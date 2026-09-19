# Read-only: is the desktop locked? Does WeChat still have a usable window?
# Touches nothing. No ShowWindow / SetForegroundWindow / no files written.
$ErrorActionPreference = 'Stop'
try { [void][Dpi] } catch {
    Add-Type -Name Dpi -Namespace '' -MemberDefinition '
[DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);' | Out-Null
}
# Keep the HRESULT: if DPI awareness did not take effect, every rect printed below is
# a scaled logical value while CopyFromScreen works in physical pixels -- that mismatch
# is exactly what makes "clicks land nowhere" bugs, so it must be visible, not swallowed.
#   0 = S_OK, 0x80070005 = E_ACCESSDENIED (already set for this process -- also fine),
#   0x80070057 = E_INVALIDARG.
$dpiHr = $null
try { $dpiHr = [Dpi]::SetProcessDpiAwareness(2) } catch { $dpiHr = 'THREW: ' + $_.Exception.Message }

Add-Type @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public class P22{
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out R r);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EW cb,IntPtr p);
 [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
 // Windows 10 1607+. Missing export throws at call time, not at Add-Type time,
 // so the caller guards it with try/catch rather than probing for it here.
 [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint f,bool inh,uint acc);
 [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
 [DllImport("user32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
 public static extern bool GetUserObjectInformationW(IntPtr h,int i,StringBuilder p,int n,out int need);
 public delegate bool EW(IntPtr h,IntPtr p);
 public struct R{public int L,T,Rr,B;}
 public static List<IntPtr> All=new List<IntPtr>();
 public static void Scan(){All.Clear();EnumWindows(delegate(IntPtr h,IntPtr p){All.Add(h);return true;},IntPtr.Zero);}
 public static string Txt(IntPtr h){var s=new StringBuilder(512);GetWindowTextW(h,s,512);return s.ToString();}
 public static string Cls(IntPtr h){var s=new StringBuilder(256);GetClassNameW(h,s,256);return s.ToString();}
}
'@

# ---- DPI / screen geometry ----
# First, because every rect printed further down depends on it: without per-monitor
# awareness GetWindowRect hands back logical (scaled) coords while CopyFromScreen reads
# physical pixels, and nothing announces the mismatch.
$hrTxt = if ($dpiHr -is [int]) { '0x{0:X8}' -f $dpiHr } else { [string]$dpiHr }
Write-Output ("SetProcessDpiAwareness(2) = {0}   (0x00000000=OK, 0x80070005=already set, both fine)" -f $hrTxt)
$dpi = 0
try { $dpi = [P22]::GetDpiForSystem() } catch { $dpi = 0 }
if ($dpi -gt 0) {
    Write-Output ("system DPI = {0}   => scale {1:P0}   (96 = 100%)" -f $dpi, ($dpi / 96.0))
} else {
    Write-Output 'system DPI = unavailable (GetDpiForSystem absent, pre-1607 Windows)'
}
Write-Output ("primary screen (physical px) = {0} x {1}" -f [P22]::GetSystemMetrics(0), [P22]::GetSystemMetrics(1))
Write-Output ("virtual desktop = ({0},{1}) {2} x {3}" -f `
        [P22]::GetSystemMetrics(76), [P22]::GetSystemMetrics(77), `
        [P22]::GetSystemMetrics(78), [P22]::GetSystemMetrics(79))

$fg = [P22]::GetForegroundWindow()
Write-Output ("GetForegroundWindow = {0}" -f $fg)
if ($fg -ne 0) { Write-Output ("  fg class={0}" -f [P22]::Cls($fg)) }

# The definitive lock test: OpenInputDesktop fails when Winlogon owns the input desktop.
$d = [P22]::OpenInputDesktop(0, $false, 0x0001)
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
if ($d -eq [IntPtr]::Zero) {
    Write-Output ("OpenInputDesktop = FAIL err={0}   => LOCKED (or secure desktop)" -f $err)
} else {
    $sb = New-Object System.Text.StringBuilder 256
    $need = 0
    [P22]::GetUserObjectInformationW($d, 2, $sb, 256, [ref]$need) | Out-Null
    Write-Output ("OpenInputDesktop = OK  name='{0}'   => UNLOCKED" -f $sb.ToString())
    [P22]::CloseDesktop($d) | Out-Null
}
Write-Output ("LogonUI running = {0}" -f [bool](Get-Process -Name 'LogonUI' -ErrorAction SilentlyContinue))

# Same class and title patterns wx_send.ps1 selects candidates with -- a hardcoded
# 'Qt51514QWindowIcon' listed nothing at all on any other WeChat build, which reads as
# "WeChat has no window" when the real answer is "the Qt version moved".
$clsRe = '^(Qt\d+QWindowIcon|WeChatMainWndForPC|mmui::MainWindow)$'
$titleRe = '^(微信|Weixin|WeChat)$'
$procs = @(Get-Process -Name 'Weixin', 'WeChat' -ErrorAction SilentlyContinue)
$pids = @($procs | ForEach-Object { $_.Id })
# MainWindowHandle is the first candidate wx_send.ps1 tries, so flag it: with several
# WeChat processes alive, which one owns the real main window is the whole question.
$mains = @($procs | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
    ForEach-Object { [int64]$_.MainWindowHandle })
[P22]::Scan()
Write-Output ("--- WeChat top-level windows (read-only), class {0} ---" -f $clsRe)
foreach ($h in [P22]::All) {
    $wpid = [uint32]0
    [P22]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
    if ($pids -notcontains [int]$wpid) { continue }
    $cls = [P22]::Cls($h)
    if ($cls -notmatch $clsRe) { continue }
    $ttl = [P22]::Txt($h)
    $r = New-Object P22+R
    [P22]::GetWindowRect($h, [ref]$r) | Out-Null
    $flag = ''
    if ($mains -contains [int64]$h) { $flag += '  <= MainWindowHandle (tried first)' }
    if ($ttl -notmatch $titleRe) { $flag += ('  !! title outside {0}, wx_send skips it' -f $titleRe) }
    Write-Output ("h={0,-9} pid={1,-6} vis={2,-5} icon={3,-5} {4}x{5} @({6},{7}) cls={8} title=[{9}]{10}" -f `
            $h, $wpid, [P22]::IsWindowVisible($h), [P22]::IsIconic($h), `
        ($r.Rr - $r.L), ($r.B - $r.T), $r.L, $r.T, $cls, $ttl, $flag)
}

# Can we capture the screen at all? Brightness only, nothing written to disk.
Add-Type -AssemblyName System.Drawing
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
    Write-Output ("screen capture mean brightness = {0:N1} / 255  (near 0 => black, capture unusable)" -f ($sum / $n))
} catch {
    Write-Output ("screen capture THREW: {0}" -f $_.Exception.Message)
}

# ---- OCR ----
# wx_send.ps1 reads the chat title with the offline Windows OCR engine and refuses to type
# anything when the title does not match, so "OCR unavailable" and "OCR resolved to a
# non-Chinese language" are both fatal -- and they fail very differently: the first throws,
# the second returns confident garbage for Chinese text and surfaces as a puzzling exit 5.
# Print the PowerShell edition first: the WinRT type load below only works under Windows
# PowerShell 5.1, so an unexpected 7.x here explains every failure that follows.
Write-Output ("--- OCR ---  PSVersion = {0}  (must be 5.1.x; pwsh 7 cannot load WinRT types)" -f $PSVersionTable.PSVersion)
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]
    $langs = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages |
            ForEach-Object { $_.LanguageTag })
    if ($langs.Count -eq 0) {
        Write-Output 'AvailableRecognizerLanguages = (none)'
    } else {
        Write-Output ("AvailableRecognizerLanguages = {0}" -f ($langs -join ', '))
    }
    # Exactly the order Get-OcrEngine in wx_send.ps1 uses, so what prints here is the
    # engine the real send will get -- not a different one that happens to work.
    $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    $how = 'TryCreateFromUserProfileLanguages()'
    if (-not $eng) {
        foreach ($tag in @('zh-Hans-CN', 'zh-Hans', 'zh-CN', 'en-US')) {
            try {
                $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage(
                    (New-Object Windows.Globalization.Language($tag)))
                if ($eng) { $how = "TryCreateFromLanguage('$tag')"; break }
            } catch {}
        }
    }
    if (-not $eng) {
        Write-Output 'OCR engine = NONE  => wx_send.ps1 will abort before typing anything.'
        Write-Output '  fix: 设置 > 时间和语言 > 语言 > 中文(简体) > 选项 > 添加「光学字符识别」'
    } else {
        $tag = $eng.RecognizerLanguage.LanguageTag
        Write-Output ("OCR engine = OK  lang={0}  via {1}" -f $tag, $how)
        if ($tag -notlike 'zh*') {
            Write-Output ("  !! not a Chinese recognizer: Chinese chat titles will come back as")
            Write-Output ("     garbage and the title check fails with exit 5 for no obvious reason.")
        }
    }
} catch {
    Write-Output ("OCR probe THREW: {0}" -f $_.Exception.Message)
    Write-Output '  => a type-load failure here almost always means this ran under pwsh 7;'
    Write-Output '     rerun with powershell.exe (5.1), which is what the skill uses.'
}
