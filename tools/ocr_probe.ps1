#requires -Version 5.1
<#
.SYNOPSIS
    对一张已有截图跑 OCR，只打印指定 y 区间内的文本框。用于排查标题带/输入框带。
.DESCRIPTION
    刻意不打印聊天区（截图含用户私人对话），只输出 -FromY..-ToY 之间的行。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [int]$FromY = 0,
    [int]$ToY = 200,
    [int]$FromX = 0,
    [switch]$RightPanelOnly,
    [switch]$ShowGeometry
)
$ErrorActionPreference = 'Stop'

# 复用 wx_send.ps1 里的 OCR / 几何实现：把它的函数定义段抽出来执行，
# 避免两份 OCR 代码走样。只取 function 块，不跑它的主流程。
$src = [System.IO.File]::ReadAllText(
    (Join-Path $PSScriptRoot '..\scripts\wx_send.ps1'), [System.Text.Encoding]::UTF8)
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $src, [ref]$null, [ref]$null)
# 全部函数都取，不逐个点名：几何检测内部还依赖 Find-Divider 等一串 helper，
# 列白名单只会漏。取的是 FunctionDefinitionAst，所以主流程不会被执行。
$defs = $ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)
foreach ($d in $defs) {
    . ([scriptblock]::Create($d.Extent.Text))
}
# WinRT / GDI 类型和 AsTask 反射都在 wx_send.ps1 的脚本作用域里做，
# 抽函数抽不到，这里照抄一份（保持和它一致）。
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]
$script:AsTaskM = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

$img = [System.IO.Path]::GetFullPath($Image)
Write-Host ("图片: {0}" -f $img)
$g = Get-Geometry $img
if ($ShowGeometry) {
    Write-Host ("几何: W={0} H={1} DivX={2} Input={3}" -f $g.W, $g.H, $g.DivX,
        $(if ($g.Input) { "L=$($g.Input.L) T=$($g.Input.T) R=$($g.Input.R) B=$($g.Input.B) 点击=($($g.Input.CX),$($g.Input.CY))" } else { '(未定位)' }))
}
# 左栏是用户的会话列表（私人内容），排查时用 -RightPanelOnly 把它挡掉。
$xMin = $FromX
if ($RightPanelOnly -and $g.DivX -gt $xMin) { $xMin = $g.DivX }
Write-Host ("--- x>={0} 且 y in [{1},{2}] 的 OCR 行 ---" -f $xMin, $FromY, $ToY)
$n = 0
foreach ($o in (Invoke-Ocr $img)) {
    if ($o.X -ge $xMin -and $o.Y -ge $FromY -and $o.Y -le $ToY) {
        $n++
        Write-Host ("  x={0,-5} y={1,-5} w={2,-5} h={3,-4} [{4}]" -f $o.X, $o.Y, $o.W, $o.H, $o.NText)
    }
}
if ($n -eq 0) { Write-Host '  (该区间内没有任何 OCR 结果)' }
exit 0
