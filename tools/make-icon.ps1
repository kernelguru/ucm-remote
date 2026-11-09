# Erzeugt das App-Icon (1024x1024, ohne Alphakanal) unter
# UCMRemote/Assets.xcassets/AppIcon.appiconset/AppIcon.png
# Aufruf: powershell -ExecutionPolicy Bypass -File tools/make-icon.ps1

Add-Type -AssemblyName System.Drawing

$size = 1024
$out = Join-Path $PSScriptRoot "..\UCMRemote\Assets.xcassets\AppIcon.appiconset\AppIcon.png"

$bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

# Hintergrund: diagonaler Verlauf Dunkelpetrol -> Petrol
$gradRect = New-Object System.Drawing.Rectangle -4, -4, ($size + 8), ($size + 8)
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush $gradRect,
    ([System.Drawing.Color]::FromArgb(255, 8, 31, 36)),
    ([System.Drawing.Color]::FromArgb(255, 13, 115, 107)), 45.0
$g.FillRectangle($bg, $gradRect)

# Lichtschein
$glowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$glowPath.AddEllipse(112, 112, 800, 800)
$glow = New-Object System.Drawing.Drawing2D.PathGradientBrush $glowPath
$glow.CenterColor = [System.Drawing.Color]::FromArgb(80, 115, 242, 204)
$glow.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 115, 242, 204))
$g.FillPath($glow, $glowPath)

$white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$mint = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 115, 242, 204))
$bgDark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 10, 60, 60))

# Schlüssel: Ring + Schaft + Bart (leicht diagonal)
$g.TranslateTransform(470, 470)
$g.RotateTransform(-35)
$ringPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 70
$g.DrawEllipse($ringPen, -330, -125, 250, 250)
$g.FillRectangle($white, -90, -38, 470, 76)
$g.FillRectangle($white, 250, 30, 60, 110)
$g.FillRectangle($white, 330, 30, 50, 80)
$g.ResetTransform()

# Zertifikats-Siegel unten rechts
$g.FillEllipse($mint, 600, 600, 300, 300)
$g.FillEllipse($bgDark, 640, 640, 220, 220)
$checkPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 115, 242, 204)), 36
$checkPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$checkPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$checkPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$g.DrawLines($checkPen, @(
    (New-Object System.Drawing.PointF 690, 752),
    (New-Object System.Drawing.PointF 735, 800),
    (New-Object System.Drawing.PointF 815, 705)
))

New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
Write-Output "Icon gespeichert: $out"
