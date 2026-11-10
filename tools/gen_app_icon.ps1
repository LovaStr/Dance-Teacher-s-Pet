# Generates the application icon: assets/icon.ico
#
# Draws the dancer from assets/icon.svg (same 100x100 coordinates) with GDI+
# at several sizes and packs them as PNG entries into one .ico. The .ico is
# embedded by assets/DanceTeachersPet.rc as icon 1, which Explorer uses for the
# exe and SDL uses for the window. Run from the repo root:
#
#   powershell -File tools/gen_app_icon.ps1
#
# (Nothing here is needed to build Dance Teacher's Pet; the .ico is checked in.)

Add-Type -AssemblyName System.Drawing
$sizes = @(16, 20, 24, 32, 40, 48, 64, 256)
$outFile = Join-Path $PSScriptRoot '..\assets\icon.ico'

function Color($hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Pt($x, $y) { New-Object System.Drawing.PointF ([single]$x), ([single]$y) }
function Pen($hex, $w) {
    $p = New-Object System.Drawing.Pen (Color $hex), ([single]$w)
    $p.StartCap = 'Round'; $p.EndCap = 'Round'; $p.LineJoin = 'Round'
    return $p
}
function Brush($hex) { New-Object System.Drawing.SolidBrush (Color $hex) }
function Fill-Ellipse($g, $hex, $cx, $cy, $rx, $ry) {
    $g.FillEllipse((Brush $hex), [single]($cx - $rx), [single]($cy - $ry), [single](2 * $rx), [single](2 * $ry))
}

function Draw-Dancer($g) {
    $suit = '#E24B4A'; $dark = '#A32D2D'; $skin = '#E8B48A'
    # Arms and legs (round-capped strokes).
    $g.DrawLine((Pen $suit 6.5), (Pt 55 31), (Pt 72 10))
    $g.DrawLines((Pen $suit 6.5), [System.Drawing.PointF[]]@((Pt 45 31), (Pt 32 44), (Pt 42 56)))
    $g.DrawLine((Pen $suit 8), (Pt 47 59), (Pt 45 86))
    $g.DrawLines((Pen $suit 8), [System.Drawing.PointF[]]@((Pt 54 59), (Pt 67 72), (Pt 64 86)))
    # Trouser cuffs and shoes.
    $g.FillPolygon((Brush $dark), [System.Drawing.PointF[]]@((Pt 41 85), (Pt 49 85), (Pt 50 88), (Pt 40 88)))
    $g.FillPolygon((Brush $dark), [System.Drawing.PointF[]]@((Pt 60 85), (Pt 68 85), (Pt 69 88), (Pt 59 88)))
    Fill-Ellipse $g $suit 44 90 6 2.8
    Fill-Ellipse $g $suit 65 90 6 2.8
    # Jacket: M42 29 Q50 25 58 29 L59 61 L41 61 Z (quadratic as cubic).
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddBezier((Pt 42 29), (Pt 47.333 26.333), (Pt 52.667 26.333), (Pt 58 29))
    $p.AddLine((Pt 58 29), (Pt 59 61))
    $p.AddLine((Pt 59 61), (Pt 41 61))
    $p.CloseFigure()
    $g.FillPath((Brush $suit), $p)
    $g.FillRectangle((Brush $dark), [single]41, [single]57, [single]18, [single]3)
    # Hands, head and its highlight.
    Fill-Ellipse $g $skin 73.5 8.5 3 3
    Fill-Ellipse $g $skin 43 57 3 3
    Fill-Ellipse $g $skin 50 19.5 7.4 7.4
    Fill-Ellipse $g '#F5D3B8' 47 15.5 2.4 1.4
}

function Render-Png([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.ScaleTransform([single]($size / 100.0), [single]($size / 100.0))
    Draw-Dancer $g
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return , $ms.ToArray()
}

# ICO container: ICONDIR, one ICONDIRENTRY per size, then the PNG images.
$images = foreach ($s in $sizes) { , (Render-Png $s) }
$ms = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $ms
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$images[$i].Length); $w.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $w.Write($img) }
$w.Flush()
[System.IO.File]::WriteAllBytes($outFile, $ms.ToArray())
$w.Dispose()

"{0}: {1} bytes, sizes {2}" -f (Resolve-Path $outFile).Path, (Get-Item $outFile).Length, ($sizes -join ', ')
