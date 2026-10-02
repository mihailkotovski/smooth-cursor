# Генерирует PNG курсоров 128x128 для smooth-cursor.lua.
# Хотспоты (в пикселях этого холста) продублированы в таблице CURSORS в smooth-cursor.lua.
param([Parameter(Mandatory = $true)][string]$OutDir)

Add-Type -AssemblyName System.Drawing

$Size = 128   # итоговый размер
$SS = 4       # суперсэмплинг при отрисовке

function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return , $p
}

function New-RoundPen($color, [single]$width) {
    $pen = New-Object System.Drawing.Pen $color, $width
    $pen.LineJoin = 'Round'
    $pen.StartCap = 'Round'
    $pen.EndCap = 'Round'
    return $pen
}

function Draw-Arrow($g, $fill, $outline) {
    $ox = 30; $oy = 12; $k = 1.2
    $src = @(0, 0), @(0, 72), @(16.5, 56), @(27, 81), @(38, 76.5), @(27.5, 52), @(50, 52)
    $pts = $src | ForEach-Object { New-Object System.Drawing.PointF ($ox + $_[0] * $k), ($oy + $_[1] * $k) }
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddPolygon([System.Drawing.PointF[]]$pts)
    $g.DrawPath((New-RoundPen $outline 9), $path)
    $g.DrawPath((New-RoundPen $fill 1.5), $path)
    $g.FillPath((New-Object System.Drawing.SolidBrush $fill), $path)
}

function Draw-Hand($g, $fill, $outline) {
    $shapes = @(
        (New-RoundRect 50 10 15 70 7.5),   # указательный
        (New-RoundRect 65 40 15 45 7.5),   # средний
        (New-RoundRect 80 45 15 42 7.5),   # безымянный
        (New-RoundRect 95 51 14 38 7),     # мизинец
        (New-RoundRect 50 62 59 52 18)     # ладонь
    )
    $ol = New-RoundPen $outline 7
    foreach ($s in $shapes) { $g.DrawPath($ol, $s) }
    $g.DrawLine((New-RoundPen $outline 22), 35, 69, 56, 92)   # большой палец
    $brush = New-Object System.Drawing.SolidBrush $fill
    foreach ($s in $shapes) { $g.FillPath($brush, $s) }
    $g.DrawLine((New-RoundPen $fill 15), 35, 69, 56, 92)
    $sep = New-RoundPen $outline 2.5
    $g.DrawLine($sep, 65, 56, 65, 76)
    $g.DrawLine($sep, 80, 59, 80, 77)
    $g.DrawLine($sep, 95, 63, 95, 78)
}

function Draw-IBeam($g, $fill, $outline) {
    foreach ($pen in (New-RoundPen $outline 10), (New-RoundPen $fill 4)) {
        $g.DrawLine($pen, 64, 27, 64, 101)
        $g.DrawLine($pen, 54, 27, 74, 27)
        $g.DrawLine($pen, 54, 101, 74, 101)
    }
}

function New-Layer([int]$px, [scriptblock]$paint) {
    $bmp = New-Object System.Drawing.Bitmap $px, $px, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::FromArgb(0, 255, 255, 255))
    & $paint $g
    $g.Dispose()
    return , $bmp
}

function Save-Cursor([string]$name, [string]$shape, $fill, $outline) {
    $black = [System.Drawing.Color]::Black
    $big = $Size * $SS
    $draw = { param($g, $f, $o) $g.ScaleTransform($SS, $SS); & "Draw-$shape" $g $f $o }

    $body = New-Layer $big { param($g) & $draw $g $fill $outline }
    $silhouette = New-Layer $big { param($g) & $draw $g $black $black }
    # тень: силуэт, размытый уменьшением и обратным увеличением
    $blurred = New-Layer ($Size / 4) { param($g) $g.DrawImage($silhouette, 0, 0, $Size / 4, $Size / 4) }

    $final = New-Layer $Size {
        param($g)
        $cm = New-Object System.Drawing.Imaging.ColorMatrix
        $cm.Matrix33 = 0.38
        $ia = New-Object System.Drawing.Imaging.ImageAttributes
        $ia.SetColorMatrix($cm)
        $dst = New-Object System.Drawing.Rectangle 0, 3, $Size, $Size
        $g.DrawImage($blurred, $dst, 0, 0, $blurred.Width, $blurred.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $g.DrawImage($body, 0, 0, $Size, $Size)
    }
    $path = Join-Path $OutDir "$name.png"
    $final.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output "saved $path"
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$white = [System.Drawing.Color]::White
$black = [System.Drawing.Color]::FromArgb(255, 20, 20, 20)
Save-Cursor "arrow-dark" "Arrow" $black $white
Save-Cursor "arrow-light" "Arrow" $white $black
Save-Cursor "hand" "Hand" $white $black
Save-Cursor "ibeam" "IBeam" $black $white
