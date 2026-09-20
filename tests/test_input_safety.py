"""Offline regression checks; no desktop interaction or WeChat messages."""
import os
from pathlib import Path
import subprocess
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'scripts/wx_send.ps1'
PS = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'


@unittest.skipUnless(PS.exists(), 'Windows PowerShell required')
class InputSafetyTests(unittest.TestCase):
    def run_ps(self, body):
        escaped = str(SOURCE).replace("'", "''")
        setup = f"""$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing
$ast = [Management.Automation.Language.Parser]::ParseFile('{escaped}', [ref]$null, [ref]$null)
$ast.FindAll({{param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}}, $false) | ForEach-Object {{ Invoke-Expression $_.Extent.Text }}
"""
        return subprocess.run([str(PS), '-NoProfile', '-NonInteractive', '-Command', setup + body],
                              capture_output=True, text=True, encoding='utf-8', timeout=20)

    def test_unrecognized_divider_is_not_guessed(self):
        result = self.run_ps("""
$bmp = [Drawing.Bitmap]::new(896,648)
$g = [Drawing.Graphics]::FromImage($bmp)
$g.Clear([Drawing.Color]::White)
try {
    if ((Find-Divider $bmp 896 648) -ne -1) { throw 'Blank screen accepted' }
    $g.FillRectangle([Drawing.Brushes]::Gray, 0, 0, 309, 648)
    if ((Find-Divider $bmp 896 648) -ne 309) { throw 'Real divider not detected' }
} finally { $g.Dispose(); $bmp.Dispose() }
""")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_list_click_rejected_but_real_input_accepted(self):
        result = self.run_ps("""
$title = [pscustomobject]@{ X=324 }
$geo = [pscustomobject]@{ W=896; H=648; DivX=188; Input=[pscustomobject]@{L=200;R=808;T=578;B=628;CX=260;CY=603} }
if (Test-InputGeometry $geo $title) { throw 'Click in conversation list accepted' }
$geo.DivX=308
$geo.Input=[pscustomobject]@{L=324;R=868;T=496;B=628;CX=384;CY=529}
if (-not (Test-InputGeometry $geo $title)) { throw 'Real input rejected' }
""")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_light_theme_boundary_at_threshold_is_detected(self):
        result = self.run_ps("""
$bmp = [Drawing.Bitmap]::new(1340,648)
$g = [Drawing.Graphics]::FromImage($bmp)
$left = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(243,243,244))
try {
    $g.Clear([Drawing.Color]::FromArgb(250,250,250))
    $g.FillRectangle($left, 0, 0, 309, 648)
    if ((Find-Divider $bmp 1340 648) -ne 309) { throw 'Light theme divider missed at RGB difference 20' }
    $focused = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(244,244,245))
    try { $g.FillRectangle($focused, 0, 520, 309, 128) } finally { $focused.Dispose() }
    if ((Find-Divider $bmp 1340 648) -ne 309) { throw 'Divider lost after lower input rows change to RGB difference 17' }
    # One horizontal image edge must not qualify as a vertical divider.
    $g.Clear([Drawing.Color]::White)
    $g.FillRectangle([Drawing.Brushes]::Gray, 309, 100, 60, 100)
    if ((Find-Divider $bmp 1340 648) -ne -1) { throw 'Short image edge accepted as divider' }
} finally { $left.Dispose(); $g.Dispose(); $bmp.Dispose() }
""")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_changed_chat_stops_before_next_action(self):
        result = self.run_ps("""
function Get-WinShot { [pscustomobject]@{Path='fixture'} }
function Get-Geometry { [pscustomobject]@{DivX=308} }
function Invoke-Ocr { @() }
function Get-ChatTitle { [pscustomobject]@{NText='different chat'; X=324} }
$null = Read-TargetView ([IntPtr]1) 'fixture' 'expected chat'
Write-Output 'UNSAFE_NEXT_ACTION'
""")
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertNotIn('UNSAFE_NEXT_ACTION', result.stdout)


if __name__ == '__main__':
    unittest.main()
