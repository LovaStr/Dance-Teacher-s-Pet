# Generates the embedded button icons: src/icons/silence.rgba
#
# Each file is a raw 60x60 RGBA8 image (straight alpha), white glyph on a
# transparent background. src/icons.zig embeds them and derives a black copy
# for the light theme at compile time. Run from the repo root:
#
#   powershell -File tools/gen_icons.ps1
#
# (GDI+ is used only to draw; nothing here is needed to build Dance Teacher’s Pet.)

Add-Type -AssemblyName System.Drawing
$S = 60
$out = Join-Path $PSScriptRoot '..\src\icons'
New-Item -ItemType Directory -Force $out | Out-Null
$out = (Resolve-Path $out).Path

function New-Canvas {
    $bmp = New-Object System.Drawing.Bitmap $S, $S, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    return @{ bmp = $bmp; g = $g }
}

function Save-Canvas($c, $name) {
    $c.g.Dispose()
    $rect = New-Object System.Drawing.Rectangle 0, 0, $S, $S
    $d = $c.bmp.LockBits($rect, 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $n = $S * $S * 4
    $bgra = New-Object byte[] $n
    [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $bgra, 0, $n)
    $c.bmp.UnlockBits($d)
    $rgba = New-Object byte[] $n
    for ($i = 0; $i -lt $n; $i += 4) {
        # White glyph: colour is forced to white, only coverage (alpha) matters.
        $rgba[$i] = 255; $rgba[$i + 1] = 255; $rgba[$i + 2] = 255; $rgba[$i + 3] = $bgra[$i + 3]
    }
    [System.IO.File]::WriteAllBytes((Join-Path $out "$name.rgba"), $rgba)
    $c.bmp.Dispose()
}

function Pen($w, $alpha = 255) {
    $p = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($alpha, 255, 255, 255)), $w
    $p.StartCap = 'Round'; $p.EndCap = 'Round'; $p.LineJoin = 'Round'
    return $p
}
function Brush($alpha = 255) { New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($alpha, 255, 255, 255)) }
function Pt($x, $y) { New-Object System.Drawing.PointF ([single]$x), ([single]$y) }

function Round-Rect($x, $y, $w, $h, $r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Waveform whose outer ends are trimmed off by two cut marks.
$c = New-Canvas; $pen = Pen 4.5
$bars = @(@(18, 4), @(25, 13), @(32, 24), @(39, 15), @(46, 6))  # x, half-height
foreach ($b in $bars) { $c.g.DrawLine($pen, (Pt ($b[0] - 4) (30 - $b[1])), (Pt ($b[0] - 4) (30 + $b[1]))) }
$c.g.DrawLine($pen, (Pt 6 18), (Pt 6 42))
$c.g.DrawLine($pen, (Pt 54 18), (Pt 54 42))
Save-Canvas $c 'silence'


Get-ChildItem $out -Filter *.rgba | ForEach-Object { "{0} {1} bytes" -f $_.Name, $_.Length }

