$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$sourcePath = Join-Path $PSScriptRoot '..\..\docs\assets\app-icon-transparent-v2.png'
$resources = Join-Path $PSScriptRoot '..\android\app\src\main\res'
$source = [System.Drawing.Image]::FromFile($sourcePath)

function Export-Icon {
    param([string]$Path, [int]$Size, [int]$ArtworkSize)

    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $offset = ($Size - $ArtworkSize) / 2
        $graphics.DrawImage($source, [System.Drawing.Rectangle]::new($offset, $offset, $ArtworkSize, $ArtworkSize))
        $directory = Split-Path -Parent $Path
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Output "$Path ($Size x $Size)"
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

try {
    $sizes = [ordered]@{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
    foreach ($density in $sizes.Keys) {
        $size = $sizes[$density]
        Export-Icon -Path (Join-Path $resources "mipmap-$density\ic_launcher.png") -Size $size -ArtworkSize $size
    }

    # 四角取景框也属于主体，原稿在 108dp 图层中缩至 56dp，避免圆形裁切截断。
    Export-Icon -Path (Join-Path $resources 'drawable-xxxhdpi\journal_icon_foreground.png') -Size 432 -ArtworkSize 224
}
finally {
    $source.Dispose()
}
