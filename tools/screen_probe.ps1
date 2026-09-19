#requires -Version 5.1
<#
.SYNOPSIS
    打印 DPI 感知下的真实屏幕尺寸、微信窗口矩形，以及两者的关系。
.DESCRIPTION
    排查「窗口比屏幕大 / 超出屏幕」导致点击落到屏幕外、截图区域不存在的问题。
    必须先设 DPI 感知再调用任何窗口 API，否则拿到的是缩放后的逻辑值。
#>
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class SP {
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EW cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public delegate bool EW(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, R2, B; }
}
'@
try { [void][SP]::SetProcessDpiAwareness(2) } catch {}

$sw = [SP]::GetSystemMetrics(0)      # SM_CXSCREEN
$sh = [SP]::GetSystemMetrics(1)      # SM_CYSCREEN
$vx = [SP]::GetSystemMetrics(76)     # SM_XVIRTUALSCREEN
$vy = [SP]::GetSystemMetrics(77)
$vw = [SP]::GetSystemMetrics(78)     # SM_CXVIRTUALSCREEN
$vh = [SP]::GetSystemMetrics(79)
Write-Host ("主屏(物理像素)  : {0} x {1}" -f $sw, $sh)
Write-Host ("虚拟桌面        : {0},{1} {2} x {3}" -f $vx, $vy, $vw, $vh)

$pids = @([System.Diagnostics.Process]::GetProcesses() |
    Where-Object { $_.ProcessName -match '^(Weixin|WeChat)$' } |
    ForEach-Object { [uint32]$_.Id })
Write-Host ("微信进程 pid    : {0}" -f ($pids -join ','))

Write-Host '--- 微信顶层窗口 ---'
$cb = [SP+EW] {
    param($h, $p)
    $pid2 = 0
    [void][SP]::GetWindowThreadProcessId($h, [ref]$pid2)
    if ($pids -notcontains $pid2) { return $true }
    $sb = New-Object System.Text.StringBuilder 512
    [void][SP]::GetWindowTextW($h, $sb, 512); $title = $sb.ToString()
    $sb2 = New-Object System.Text.StringBuilder 256
    [void][SP]::GetClassNameW($h, $sb2, 256); $cls = $sb2.ToString()
    $r = New-Object SP+R; [void][SP]::GetWindowRect($h, [ref]$r)
    $c = New-Object SP+R; [void][SP]::GetClientRect($h, [ref]$c)
    $w = $r.R2 - $r.L; $hh = $r.B - $r.T
    $over = @()
    if ($r.L -lt 0) { $over += ('左超 ' + (-$r.L)) }
    if ($r.T -lt 0) { $over += ('上超 ' + (-$r.T)) }
    if ($r.R2 -gt $sw) { $over += ('右超 ' + ($r.R2 - $sw)) }
    if ($r.B -gt $sh) { $over += ('下超 ' + ($r.B - $sh)) }
    Write-Host ("  h={0,-10} vis={1,-5} icon={2,-5} rect=({3},{4})-({5},{6}) {7}x{8}  client={9}x{10}  cls={11} title=[{12}]" -f `
            $h, [SP]::IsWindowVisible($h), [SP]::IsIconic($h), $r.L, $r.T, $r.R2, $r.B, $w, $hh,
        ($c.R2 - $c.L), ($c.B - $c.T), $cls, $title)
    if ($over.Count -gt 0) {
        Write-Host ("      !! 超出主屏: {0}   —— 超出部分点不到、也截不到" -f ($over -join '，'))
    }
    return $true
}
[void][SP]::EnumWindows($cb, [IntPtr]::Zero)
exit 0
