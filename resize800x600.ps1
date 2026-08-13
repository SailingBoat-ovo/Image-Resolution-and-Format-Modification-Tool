#Requires -Version 5.1
<#
    图片分辨率修改工具（Image Resolution Resizer）

    Copyright (C) 2026 FANCHUAN

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#>

<#
.SYNOPSIS
    把图片调整为指定分辨率（默认 800x600）。
    不带参数运行会进入全屏交互式终端界面；带参数运行保持命令行模式。

.DESCRIPTION
    全屏终端界面支持：
      - 拖入/输入多张图片，文件列表可随时增删
      - 自定义目标宽度、高度
      - 三种缩放方式：居中留白（推荐，不变形）/ 居中裁剪（不变形）/ 拉伸（会变形）
      - 自定义输出目录、批量处理、进度条与结果面板

    命令行模式参数：
      Path/OutDir/Out/Suffix/Mode/Width/Height/Quality

.EXAMPLE
    .\resize800x600.ps1
    进入全屏交互式终端界面。

.EXAMPLE
    .\resize800x600.ps1 照片.jpg
    直接处理。

.EXAMPLE
    .\resize800x600.ps1 *.jpg -Width 1024 -Height 768 -Mode fit -OutDir .\out
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [Alias('File')]
    [string[]]$Path = @(),

    [string]$OutDir,
    [string]$Out,

    [ValidateSet('stretch', 'cover', 'fit')]
    [string]$Mode = 'fit',

    [string]$Suffix = '',

    [ValidateRange(1, 10000)]
    [int]$Width = 800,

    [ValidateRange(1, 10000)]
    [int]$Height = 600,

    [ValidateRange(1, 100)]
    [int]$Quality = 92
)

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing

$ImageExtensions = @('.jpg', '.jpeg', '.png', '.bmp', '.gif', '.tif', '.tiff')
$script:ToolVersion = 'v2.3'
$script:ScriptDir = if ($env:RESIZE_TOOL_DIR) {
    $env:RESIZE_TOOL_DIR.TrimEnd('\')
} elseif ($PSScriptRoot) {
    $PSScriptRoot
} else {
    try { (Split-Path -Parent $MyInvocation.MyCommand.Path) } catch { (Get-Location).Path }
}

# 调试日志：仅在 RESIZE_TOOL_DEBUG=1 或发生错误时写入
function Write-DebugLog {
    param([string]$Message)
    try {
        if ($env:RESIZE_TOOL_DEBUG -or ($script:Ui -and $script:Ui.LastError)) {
            $logPath = Join-Path $script:ScriptDir 'resize800x600.log'
            $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
        }
    } catch { }
}

# 宽字符查表（CJK / 全角字符按 2 个终端列计算），避免逐字符调用函数拖慢渲染
$WideCharTable = [bool[]]::new(0x40000)
foreach ($range in @(
        @(0x1100, 0x115F), @(0x2E80, 0xA4CF), @(0xAC00, 0xD7A3),
        @(0xF900, 0xFAFF), @(0xFE30, 0xFE4F), @(0xFF00, 0xFF60),
        @(0xFFE0, 0xFFE6), @(0x20000, 0x3FFFD)
    )) {
    for ($n = $range[0]; $n -le $range[1]; $n++) {
        $WideCharTable[$n] = $true
    }
}

# ================================================================
# 文字与网格工具
# ================================================================

function Get-DisplayWidth {
    param([string]$Text)
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        if ($WideCharTable[[int]$ch]) { $width += 2 } else { $width += 1 }
    }
    return $width
}

function Pad-Display {
    param([string]$Text, [int]$Width)
    $pad = $Width - (Get-DisplayWidth $Text)
    if ($pad -lt 0) { $pad = 0 }
    return ($Text + (' ' * $pad))
}

function Truncate-Display {
    param([string]$Text, [int]$Width)
    if ((Get-DisplayWidth $Text) -le $Width) { return $Text }
    $result = ''
    $used = 0
    foreach ($ch in $Text.ToCharArray()) {
        $cw = if ($WideCharTable[[int]$ch]) { 2 } else { 1 }
        if ($used + $cw -gt ($Width - 1)) { break }
        $result += $ch
        $used += $cw
    }
    return ($result + '…')
}

$script:Ui = $null

function New-TuiGrid {
    param([int]$Width, [int]$Height)
    $grid = @()
    $color = @()
    for ($y = 0; $y -lt $Height; $y++) {
        $row = [char[]]::new($Width)
        $crow = [int[]]::new($Width)
        for ($x = 0; $x -lt $Width; $x++) {
            $row[$x] = ' '
            $crow[$x] = [int][ConsoleColor]::Gray
        }
        $grid += , $row
        $color += , $crow
    }
    return @{ Grid = $grid; Color = $color }
}

function Reset-TuiGrid {
    $touched = $script:Ui.Touched
    foreach ($cell in $touched) {
        $x = $cell[0]
        $y = $cell[1]
        if ($x -ge 0 -and $x -lt $script:Ui.ScreenW -and $y -ge 0 -and $y -lt $script:Ui.ScreenH) {
            $script:Ui.Grid[$y][$x] = ' '
            $script:Ui.Color[$y][$x] = [int][ConsoleColor]::Gray
        }
    }
    $touched.Clear()
}

function Write-TuiText {
    param(
        [int]$X,
        [int]$Y,
        [string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    $x = $X
    foreach ($ch in $Text.ToCharArray()) {
        if ($x -ge $script:Ui.ScreenW) { break }
        if ($x -ge 0 -and $y -ge 0 -and $y -lt $script:Ui.ScreenH) {
            $script:Ui.Grid[$y][$x] = $ch
            $script:Ui.Color[$y][$x] = [int]$Color
            $script:Ui.Touched.Add(@($x, $y))
        }
        $x++
        if ($WideCharTable[[int]$ch]) { $x++ }
    }
}

function Draw-TuiBox {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$Title = '',
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )
    Write-TuiText $X $Y ('┌' + ('─' * ($Width - 2)) + '┐') $Color
    for ($i = 1; $i -lt ($Height - 1); $i++) {
        Write-TuiText $X ($Y + $i) ('│' + (' ' * ($Width - 2)) + '│') $Color
    }
    Write-TuiText $X ($Y + $Height - 1) ('└' + ('─' * ($Width - 2)) + '┘') $Color
    if ($Title) {
        Write-TuiText ($X + 2) $Y (' ' + $Title + ' ') $Color
    }
}

function Update-TuiScreen {
    if ($script:Ui.TestMode) {
        $rows = @()
        for ($y = 0; $y -lt $script:Ui.ScreenH; $y++) {
            $sb = [System.Text.StringBuilder]::new()
        for ($x = 0; $x -lt $script:Ui.ScreenW; $x++) {
            $ch = $script:Ui.Grid[$y][$x]
            $null = $sb.Append($ch)
            if ($WideCharTable[[int]$ch]) { $x++ }
            }
            $rows += $sb.ToString().TrimEnd()
        }
        $snapshot = $rows -join "`n"
        if ($snapshot -ne $script:Ui.LastSnapshot) {
            $script:Ui.Transcript.Add($snapshot)
            $script:Ui.LastSnapshot = $snapshot
        }
        return
    }

    [Console]::SetCursorPosition(0, 0)
    for ($y = 0; $y -lt $script:Ui.ScreenH; $y++) {
        $sb = [System.Text.StringBuilder]::new()
        $segments = [System.Collections.Generic.List[object]]::new()
        $lastColor = -1
        for ($x = 0; $x -lt $script:Ui.ScreenW; $x++) {
            $col = $script:Ui.Color[$y][$x]
            if ($col -ne $lastColor) {
                if ($sb.Length -gt 0) {
                    $segments.Add([pscustomobject]@{ Color = $lastColor; Text = $sb.ToString() })
                    $null = $sb.Clear()
                }
                $lastColor = $col
            }
            $ch = $script:Ui.Grid[$y][$x]
            $null = $sb.Append($ch)
            if ($WideCharTable[[int]$ch]) { $x++ }
        }
        if ($sb.Length -gt 0) {
            $segments.Add([pscustomobject]@{ Color = $lastColor; Text = $sb.ToString() })
        }
        foreach ($seg in $segments) {
            [Console]::ForegroundColor = [ConsoleColor]$seg.Color
            [Console]::Write($seg.Text)
        }
        [Console]::ForegroundColor = [ConsoleColor]::Gray
        if ($y -lt ($script:Ui.ScreenH - 1)) { [Console]::WriteLine() }
    }
}

# ================================================================
# 图片处理
# ================================================================

function Invoke-ExifOrientation {
    param([System.Drawing.Image]$Image)
    try {
        $prop = $Image.GetPropertyItem(0x0112)
    } catch {
        return
    }
    if (-not $prop -or $prop.Value.Length -lt 2) { return }
    $orientation = [BitConverter]::ToUInt16($prop.Value, 0)
    switch ($orientation) {
        2 { $Image.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX) }
        3 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
        4 { $Image.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipY) }
        5 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipX) }
        6 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
        7 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipX) }
        8 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
    }
}

function Resolve-ImageFiles {
    param([string[]]$RawPaths, [switch]$Quiet)

    $result = @()
    foreach ($raw in $RawPaths) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $items = @(Get-Item -LiteralPath $raw -ErrorAction SilentlyContinue)
        if ($items.Count -eq 0) {
            $items = @(Get-Item -Path $raw -ErrorAction SilentlyContinue)
        }
        if ($items.Count -eq 0) {
            if (-not $Quiet) { Write-Warning "找不到文件: $raw" }
            continue
        }
        foreach ($item in $items) {
            if ($item.PSIsContainer) {
                $inner = @(
                    Get-ChildItem -LiteralPath $item.FullName -File -ErrorAction SilentlyContinue |
                        Where-Object { $ImageExtensions -contains $_.Extension.ToLowerInvariant() }
                )
                $result += $inner.FullName
            } else {
                $result += $item.FullName
            }
        }
    }
    return @($result | Select-Object -Unique)
}

function Resize-OneImage {
    param(
        [string]$InputPath,
        [int]$TargetWidth,
        [int]$TargetHeight,
        [string]$ResizeMode,
        [string]$TargetOutDir,
        [string]$OutputName,
        [string]$NameSuffix,
        [int]$JpegQuality
    )

    $result = [pscustomobject]@{
        Path      = $InputPath
        OutPath   = ''
        OutWidth  = 0
        OutHeight = 0
        OK        = $false
        Message   = ''
    }

    $src = $null
    $dst = $null
    $g = $null
    try {
        $src = [System.Drawing.Image]::FromFile($InputPath)
        Invoke-ExifOrientation $src
        $srcW = $src.Width
        $srcH = $src.Height
        if ($srcW -lt 1 -or $srcH -lt 1) { throw '图片尺寸无效' }

        $suffix = if ($NameSuffix) { $NameSuffix } else { "_${TargetWidth}x${TargetHeight}" }
        $srcDir = Split-Path -Parent $InputPath
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
        $ext = [System.IO.Path]::GetExtension($InputPath).ToLowerInvariant()

        $finalOutDir = if ($TargetOutDir) { $TargetOutDir } else { $srcDir }
        if (-not (Test-Path -LiteralPath $finalOutDir)) {
            New-Item -ItemType Directory -Path $finalOutDir | Out-Null
        }
        $outPath = if ($OutputName) {
            Join-Path $finalOutDir $OutputName
        } else {
            Join-Path $finalOutDir ($baseName + $suffix + $ext)
        }
        if ([System.IO.Path]::GetFullPath($outPath) -eq [System.IO.Path]::GetFullPath($InputPath)) {
            throw '输出路径与输入路径相同，请使用 -OutDir 或 -Out 指定其他位置。'
        }

        $dst = [System.Drawing.Bitmap]::new($TargetWidth, $TargetHeight, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.Clear([System.Drawing.Color]::White)

        switch ($ResizeMode) {
            'stretch' {
                $g.DrawImage($src, 0, 0, $TargetWidth, $TargetHeight)
            }
            'cover' {
                $scale = [Math]::Max($TargetWidth / $srcW, $TargetHeight / $srcH)
                $cropW = $TargetWidth / $scale
                $cropH = $TargetHeight / $scale
                $cropX = [int][Math]::Max(0, [Math]::Round(($srcW - $cropW) / 2))
                $cropY = [int][Math]::Max(0, [Math]::Round(($srcH - $cropH) / 2))
                $destRect = [System.Drawing.Rectangle]::new(0, 0, $TargetWidth, $TargetHeight)
                $g.DrawImage(
                    $src, $destRect,
                    $cropX, $cropY,
                    [int][Math]::Round($cropW), [int][Math]::Round($cropH),
                    [System.Drawing.GraphicsUnit]::Pixel
                )
            }
            'fit' {
                $scale = [Math]::Min($TargetWidth / $srcW, $TargetHeight / $srcH)
                $drawW = [int][Math]::Round($srcW * $scale)
                $drawH = [int][Math]::Round($srcH * $scale)
                $x = [int][Math]::Round(($TargetWidth - $drawW) / 2)
                $y = [int][Math]::Round(($TargetHeight - $drawH) / 2)
                $g.DrawImage($src, $x, $y, $drawW, $drawH)
            }
        }

        $outExt = [System.IO.Path]::GetExtension($outPath).ToLowerInvariant()
        if ($outExt -in '.jpg', '.jpeg') {
            $codec = @([System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' })[0]
            $ep = [System.Drawing.Imaging.EncoderParameters]::new(1)
            $ep.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
            $dst.Save($outPath, $codec, $ep)
        } else {
            switch ($outExt) {
                '.png'  { $fmt = [System.Drawing.Imaging.ImageFormat]::Png }
                '.bmp'  { $fmt = [System.Drawing.Imaging.ImageFormat]::Bmp }
                '.gif'  { $fmt = [System.Drawing.Imaging.ImageFormat]::Gif }
                '.tif'  { $fmt = [System.Drawing.Imaging.ImageFormat]::Tiff }
                '.tiff' { $fmt = [System.Drawing.Imaging.ImageFormat]::Tiff }
                default {
                    $fmt = [System.Drawing.Imaging.ImageFormat]::Jpeg
                    $outPath = [System.IO.Path]::ChangeExtension($outPath, '.jpg')
                }
            }
            $dst.Save($outPath, $fmt)
        }

        $result.OutPath = $outPath
        $result.OutWidth = $dst.Width
        $result.OutHeight = $dst.Height
        $result.OK = $true
    } catch {
        $result.Message = $_.Exception.Message
    } finally {
        if ($g) { $g.Dispose() }
        if ($dst) { $dst.Dispose() }
        if ($src) { $src.Dispose() }
    }
    return $result
}

function Invoke-ResizeImages {
    param(
        [string[]]$Files,
        [int]$TargetWidth,
        [int]$TargetHeight,
        [string]$ResizeMode,
        [string]$TargetOutDir,
        [string]$OutputName,
        [string]$NameSuffix,
        [int]$JpegQuality
    )

    if ($Files.Count -eq 0) {
        Write-Warning '没有可处理的文件。'
        return 1
    }
    if ($OutputName -and $Files.Count -gt 1) {
        Write-Warning '-Out 只能用于单张图片，已忽略该参数。'
        $OutputName = ''
    }

    $done = 0
    $failed = 0
    foreach ($inputPath in $Files) {
        $r = Resize-OneImage -InputPath $inputPath -TargetWidth $TargetWidth -TargetHeight $TargetHeight -ResizeMode $ResizeMode -TargetOutDir $TargetOutDir -OutputName $OutputName -NameSuffix $NameSuffix -JpegQuality $JpegQuality
        if ($r.OK) {
            Write-Host "已生成: $($r.OutPath) ($($r.OutWidth)x$($r.OutHeight))" -ForegroundColor Green
            $done++
        } else {
            Write-Warning "处理失败: $inputPath -> $($r.Message)"
            $failed++
        }
    }
    Write-Host ''
    Write-Host "完成：成功 $done 张，失败 $failed 张。"
    if ($failed -gt 0) { return 1 }
    return 0
}

# ================================================================
# 简易菜单（输入被重定向 / 窗口太小时的回退方案）
# ================================================================

function Read-IntOrDefault {
    param([string]$Prompt, [int]$Default)
    while ($true) {
        $answer = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        $value = 0
        if ([int]::TryParse($answer, [ref]$value) -and $value -ge 1 -and $value -le 10000) {
            return $value
        }
        Write-Host '请输入 1 到 10000 之间的整数。' -ForegroundColor Yellow
    }
}

function Read-ResizeMode {
    Write-Host ''
    Write-Host '请选择缩放方式：'
    Write-Host '  1) 不拉伸 · 等比缩放后居中留白（推荐，不变形，保留完整画面）'
    Write-Host '  2) 不拉伸 · 等比放大后居中裁剪（不变形，可能裁掉边缘）'
    Write-Host '  3) 拉伸到目标分辨率（会变形）'
    while ($true) {
        $answer = Read-Host '请输入 1、2 或 3 [默认 1]'
        switch ($answer) {
            ''      { return 'fit' }
            '1'     { return 'fit' }
            '2'     { return 'cover' }
            '3'     { return 'stretch' }
            default { Write-Host '请输入 1、2 或 3。' -ForegroundColor Yellow }
        }
    }
}

function Show-SimpleMenu {
    Write-Host ''
    Write-Host '（当前终端不支持全屏界面，使用简易菜单）' -ForegroundColor DarkGray
    Write-Host ('============ 图片分辨率修改工具 ' + $script:ToolVersion + ' · 作者：FANCHUAN ============') -ForegroundColor Cyan
    Write-Host '说明：可以直接把图片文件拖进本窗口，也可以输入路径；'
    Write-Host '      多个文件用空格分隔，支持通配符（如 *.jpg）。'
    Write-Host '================================================' -ForegroundColor Cyan
    Write-Host ''

    while ($true) {
        $pathLine = Read-Host '请输入图片路径（直接回车 = 当前目录的所有常见图片）'
        $tokens = @()
        if (-not [string]::IsNullOrWhiteSpace($pathLine)) {
            $parseErrors = $null
            $tokens = @(
                [System.Management.Automation.PSParser]::Tokenize($pathLine, [ref]$parseErrors) |
                    ForEach-Object {
                        if ($_.Type -eq [System.Management.Automation.PSTokenType]::String -or
                            $_.Type -eq [System.Management.Automation.PSTokenType]::CommandArgument -or
                            $_.Type -eq [System.Management.Automation.PSTokenType]::Command) {
                            $_.Content
                        }
                    }
            )
        } else {
            $tokens = @('*.jpg', '*.jpeg', '*.png', '*.bmp', '*.gif', '*.tif', '*.tiff')
        }

        $files = @(Resolve-ImageFiles -RawPaths $tokens)
        if ($files.Count -eq 0) {
            Write-Host '没有找到可处理的图片，请重新输入。' -ForegroundColor Yellow
            continue
        }
        Write-Host ''
        Write-Host "找到 $($files.Count) 个文件：" -ForegroundColor Green
        $files | ForEach-Object { Write-Host "  $_" }

        $targetWidth = Read-IntOrDefault "目标宽度 [默认 $Width]" $Width
        $targetHeight = Read-IntOrDefault "目标高度 [默认 $Height]" $Height
        $resizeMode = Read-ResizeMode
        $outDir = Read-Host '输出目录（回车 = 与原图同目录）'
        if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = '' }

        $modeLabel = switch ($resizeMode) {
            'stretch' { '拉伸（会变形）' }
            'cover'   { '不拉伸 · 居中裁剪' }
            'fit'     { '不拉伸 · 居中留白' }
        }
        Write-Host ''
        Write-Host "即将处理：$($files.Count) 张图片 → ${targetWidth}x${targetHeight}，方式：$modeLabel" -ForegroundColor Yellow
        $confirm = Read-Host '确认开始？(Y/N)'
        if ($confirm -notmatch '^[yY]') { continue }

        $total = $files.Count
        $okCount = 0
        for ($i = 0; $i -lt $total; $i++) {
            $r = Resize-OneImage -InputPath $files[$i] -TargetWidth $targetWidth -TargetHeight $targetHeight -ResizeMode $resizeMode -TargetOutDir $outDir -OutputName '' -NameSuffix "_${targetWidth}x${targetHeight}" -JpegQuality $Quality
            $pct = [Math]::Round((($i + 1) / $total) * 100)
            $filled = [Math]::Floor($pct / 5)
            $bar = ('█' * $filled) + ('░' * (20 - $filled))
            Write-Host ("进度 [{0}] {1,3}%  ({2}/{3})  {4}" -f $bar, $pct, ($i + 1), $total, (Split-Path -Leaf $files[$i])) -ForegroundColor Yellow
            if ($r.OK) {
                Write-Host "已生成: $($r.OutPath) ($($r.OutWidth)x$($r.OutHeight))" -ForegroundColor Green
                $okCount++
            } else {
                Write-Warning "处理失败: $($files[$i]) -> $($r.Message)"
            }
        }
        Write-Host ''
        Write-Host "完成：成功 $okCount 张，失败 $($total - $okCount) 张。"

        $again = Read-Host '是否继续处理其他图片？(Y/N)'
        if ($again -notmatch '^[yY]') { break }
        Write-Host ''
    }
    Write-Host '再见！'
}

# ================================================================
# 全屏 TUI
# ================================================================

$ModeLabels = @('居中留白·推荐', '居中裁剪·不变形', '拉伸·会变形')
$ModeNames = @('fit', 'cover', 'stretch')

function Render-Tui {
    Reset-TuiGrid
    $u = $script:Ui

    # ---- 标题区 ----
    Draw-TuiBox 0 0 80 4 (' 图片分辨率修改工具 ' + $script:ToolVersion + ' ') Cyan
    Write-TuiText 2 1 (Pad-Display ('图片分辨率修改工具 ' + $script:ToolVersion) 76) White
    Write-TuiText 2 2 (Pad-Display '将图片调整为目标分辨率 · 作者：FANCHUAN · 输出不会覆盖原图' 76) DarkCyan

    # ---- 文件列表 ----
    $filesActive = ($u.Field -eq 0)
    $filesTitle = if ($filesActive) { '▶ 文件列表' } else { '  文件列表' }
    $filesColor = if ($filesActive) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Cyan }
    Draw-TuiBox 0 5 80 9 $filesTitle $filesColor

    $countText = '共 ' + $u.Files.Count + ' 个文件'
    Write-TuiText (78 - (Get-DisplayWidth $countText)) 6 $countText DarkGray

    if ($u.Files.Count -eq 0) {
        Write-TuiText 2 8 '（空）按 A 添加图片，或把图片直接拖进窗口' DarkGray
    } else {
        $maxRows = 5
        for ($i = 0; $i -lt [Math]::Min($maxRows, $u.Files.Count); $i++) {
            $name = $u.Files[$i]
            if ((Get-DisplayWidth $name) -gt 66) { $name = Truncate-Display $name 66 }
            Write-TuiText 2 (7 + $i) ('  ' + ($i + 1) + '. ' + $name) Gray
        }
    }
    Write-TuiText 2 12 '  [A] 添加图片    [X] 清空列表' Yellow

    # ---- 处理设置 ----
    Draw-TuiBox 0 14 80 6 ' 处理设置 ' Cyan

    Write-TuiText 2 15 '目标分辨率' White
    if ($u.Field -eq 1) { Write-TuiText 12 15 '▶' Yellow }
    Write-TuiText 14 15 '宽度 [ ' Gray
    Write-TuiText 22 15 $u.WidthText ($(if ($u.Field -eq 1) { [ConsoleColor]::Yellow } else { [ConsoleColor]::White }))
    Write-TuiText (22 + $u.WidthText.Length) 15 ' ]' Gray
    if ($u.Field -eq 2) { Write-TuiText 34 15 '▶' Yellow }
    Write-TuiText 36 15 '高度 [ ' Gray
    Write-TuiText 44 15 $u.HeightText ($(if ($u.Field -eq 2) { [ConsoleColor]::Yellow } else { [ConsoleColor]::White }))
    Write-TuiText (44 + $u.HeightText.Length) 15 ' ]' Gray

    Write-TuiText 2 16 '缩放方式' White
    if ($u.Field -eq 3) { Write-TuiText 12 16 '▶' Yellow }
    for ($m = 0; $m -lt 3; $m++) {
        $radio = if ($m -eq $u.Mode) { '●' } else { '○' }
        $label = $radio + ' ' + $ModeLabels[$m]
        $color = if ($m -eq $u.Mode) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray }
        Write-TuiText (14 + $m * 22) 16 $label $color
    }

    Write-TuiText 2 17 '输出目录' White
    if ($u.Field -eq 4) { Write-TuiText 12 17 '▶' Yellow }
    Write-TuiText 14 17 '[' Gray
    if ($u.OutDir) {
        $dirText = Truncate-Display $u.OutDir 58
        Write-TuiText 16 17 $dirText ($(if ($u.Field -eq 4) { [ConsoleColor]::Yellow } else { [ConsoleColor]::White }))
        Write-TuiText (16 + (Get-DisplayWidth $dirText)) 17 ']' Gray
    } else {
        Write-TuiText 16 17 (Pad-Display '默认与原图相同' 58) ($(if ($u.Field -eq 4) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray }))
        Write-TuiText 74 17 ']' Gray
    }

    Write-TuiText 2 18 '操作  ↑↓ 切换项目 · Enter 编辑 · 1/2/3 或 ←→ 选模式 · S 开始 · Q 退出' DarkGray

    # ---- 状态与动作 ----
    if ($u.Status) {
        Write-TuiText 2 20 ('  ' + $u.Status) Green
    }
    if ($u.Editing) {
        Write-TuiText 2 21 (' ' * 76) Black
        $prompt = $u.InputPrompt
        $line = $prompt + '： ' + $u.InputBuffer
        if ((Get-DisplayWidth $line) -gt 74) { $line = Truncate-Display $line 74 }
        Write-TuiText 2 21 $line Yellow
        $cx = 2 + (Get-DisplayWidth ($prompt + '： ' + $u.InputBuffer))
        if ($cx -lt 78) { Write-TuiText $cx 21 '▌' White }
    } else {
        Write-TuiText 2 21 '  [S] 开始处理  [A] 添加  [X] 清空  [F1] 诊断  [Q] 退出' Green
    }

    Write-TuiText 2 23 (Pad-Display ('图片分辨率修改工具 ' + $script:ToolVersion + ' · 作者：FANCHUAN · 输出默认命名 原名_宽x高') 76) DarkGray
}

function Render-TuiProcessing {
    param(
        [string]$Title,
        [int]$Current,
        [int]$Total,
        [System.Collections.Generic.List[object]]$Results,
        [string]$CurrentFile = ''
    )
    Reset-TuiGrid
    Draw-TuiBox 0 0 80 20 $Title Cyan

    $percent = if ($Total -gt 0) { [Math]::Round(($Current / $Total) * 100) } else { 0 }
    $filled = [Math]::Floor($percent / 2.5)
    $bar = ('█' * $filled) + ('░' * (40 - $filled))
    $spin = @('|', '/', '-', '\')[$script:Ui.SpinIndex % 4]
    $sec = ''
    if ($script:Ui.ProcessingStart) {
        $elapsed = [DateTime]::Now - $script:Ui.ProcessingStart
        $sec = ' · 已用 ' + [Math]::Round($elapsed.TotalSeconds, 1) + ' 秒'
    }
    $line = $spin + ' 正在处理第 ' + $Current + ' / ' + $Total + ' 张' + $sec
    Write-TuiText 2 2 $line White
    Write-TuiText 2 3 (Truncate-Display $CurrentFile 72) DarkGray
    Write-TuiText 2 4 ('  [' + $bar + ']  ' + $percent + '%') Yellow

    $y = 7
    foreach ($r in $Results) {
        if ($y -gt 16) { break }
        if ($r.OK) {
            $txt = '✓ ' + (Truncate-Display (Split-Path -Leaf $r.Path) 28) + ' → ' + $r.OutWidth + 'x' + $r.OutHeight
            Write-TuiText 2 $y $txt Green
        } else {
            $txt = '✗ ' + (Truncate-Display (Split-Path -Leaf $r.Path) 28) + ' — ' + (Truncate-Display $r.Message 30)
            Write-TuiText 2 $y $txt Red
        }
        $y++
    }
    if ($Current -lt $Total) {
        Write-TuiText 2 $y ('… ' + (Truncate-Display $CurrentFile 60)) DarkGray
    }
    if ($Current -eq 1) {
        Write-TuiText 2 18 (Pad-Display '处理中，请稍候… 大图可能需要几秒' 76) DarkGray
    } else {
        Write-TuiText 2 18 (Pad-Display '处理中，请稍候…' 76) DarkGray
    }
}

function Render-TuiDone {
    param(
        [System.Collections.Generic.List[object]]$Results,
        [int]$Total
    )
    Reset-TuiGrid
    Draw-TuiBox 0 0 80 20 ' 处理完成 ' Green

    $okCount = @($Results | Where-Object { $_.OK }).Count
    $failCount = $Total - $okCount
    $sec = ''
    if ($script:Ui.ProcessingStart) {
        $elapsed = [DateTime]::Now - $script:Ui.ProcessingStart
        $sec = ' · 用时 ' + [Math]::Round($elapsed.TotalSeconds, 1) + ' 秒'
    }
    Write-TuiText 2 2 ("处理完成：成功 {0} 张 · 失败 {1} 张{2}" -f $okCount, $failCount, $sec) White

    $y = 4
    foreach ($r in $Results) {
        if ($y -gt 16) { break }
        if ($r.OK) {
            $txt = '✓ ' + (Truncate-Display (Split-Path -Leaf $r.Path) 28) + ' → ' + $r.OutWidth + 'x' + $r.OutHeight
            Write-TuiText 2 $y $txt Green
        } else {
            $txt = '✗ ' + (Truncate-Display (Split-Path -Leaf $r.Path) 28) + ' — ' + (Truncate-Display $r.Message 30)
            Write-TuiText 2 $y $txt Red
        }
        $y++
    }
    Write-TuiText 2 18 (Pad-Display '[Enter] 返回主界面    [Q] 退出' 76) DarkGray
}

function Render-TuiDiag {
    Reset-TuiGrid
    $u = $script:Ui
    Draw-TuiBox 0 0 80 20 ' 诊断信息 (F1 / Esc 返回) ' Yellow

    $termSize = '未知'
    $inputRedirect = '未知'
    try {
        $termSize = [Console]::WindowWidth.ToString() + ' x ' + [Console]::WindowHeight.ToString()
        $inputRedirect = [Console]::IsInputRedirected.ToString()
    } catch { }

    $lines = @(
        ('终端尺寸   ' + $termSize),
        ('输入重定向 ' + $inputRedirect),
        ('文件数量   ' + $u.Files.Count + ' 个'),
        ('当前字段   ' + $u.Field + '（0=文件 1=宽 2=高 3=模式 4=目录 5=开始）'),
        ('缩放方式   ' + $ModeLabels[$u.Mode]),
        ('目标尺寸   ' + $u.WidthText + ' x ' + $u.HeightText),
        ('输出目录   ' + $(if ($u.OutDir) { $u.OutDir } else { '默认与原图相同' })),
        ('最后按键   ' + $u.LastKey),
        ('程序版本   ' + $script:ToolVersion),
        ('脚本目录   ' + $script:ScriptDir)
    )
    $y = 2
    foreach ($line in $lines) {
        Write-TuiText 2 $y (Truncate-Display $line 72) Gray
        $y++
    }
    if ($u.LastError) {
        Write-TuiText 2 14 '最近错误：' Red
        Write-TuiText 2 15 (Truncate-Display $u.LastError 72) Red
    } else {
        Write-TuiText 2 14 '最近错误：无' Green
    }
    Write-TuiText 2 18 (Pad-Display '按 F1 或 Esc 返回主界面' 76) DarkGray
}

function Move-TuiField {
    param([int]$Step)
    $script:Ui.Field = ($script:Ui.Field + $Step + 6) % 6
}

function Start-TuiAdd {
    $u = $script:Ui
    $u.Editing = $true
    $u.InputPrompt = '添加图片（拖入窗口 / 输入路径，空格或换行分隔，支持通配符）'
    $u.InputBuffer = ''
}

function Commit-TuiInput {
    $u = $script:Ui
    $text = $u.InputBuffer
    switch ($u.Field) {
        0 {
            $tokens = @()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $parseErrors = $null
                $tokens = @(
                    [System.Management.Automation.PSParser]::Tokenize($text, [ref]$parseErrors) |
                        ForEach-Object {
                            if ($_.Type -eq [System.Management.Automation.PSTokenType]::String -or
                                $_.Type -eq [System.Management.Automation.PSTokenType]::CommandArgument -or
                                $_.Type -eq [System.Management.Automation.PSTokenType]::Command) {
                                $_.Content
                            }
                        }
                )
            }
            $added = @(Resolve-ImageFiles -RawPaths $tokens -Quiet)
            if ($added.Count -eq 0) {
                $u.Status = '没有找到可添加的图片文件。'
            } else {
                foreach ($f in $added) {
                    if (-not $u.Files.Contains($f)) { $u.Files.Add($f) }
                }
                $u.Status = '已添加 ' + $u.Files.Count + ' 个文件。'
                if (-not $u.TestMode) { $u.CooldownUntil = [Environment]::TickCount + 400 }
            }
        }
        1 {
            $n = 0
            if ([string]::IsNullOrWhiteSpace($text)) {
                $u.Status = '宽度未修改。'
            } elseif ([int]::TryParse($text, [ref]$n) -and $n -ge 1 -and $n -le 10000) {
                $u.WidthText = $n.ToString()
                $u.Status = '目标宽度已设为 ' + $n + '。'
            } else {
                $u.Status = '宽度无效，请输入 1-10000 的整数。'
            }
        }
        2 {
            $n = 0
            if ([string]::IsNullOrWhiteSpace($text)) {
                $u.Status = '高度未修改。'
            } elseif ([int]::TryParse($text, [ref]$n) -and $n -ge 1 -and $n -le 10000) {
                $u.HeightText = $n.ToString()
                $u.Status = '目标高度已设为 ' + $n + '。'
            } else {
                $u.Status = '高度无效，请输入 1-10000 的整数。'
            }
        }
        4 {
            $u.OutDir = $text.Trim()
            if ($u.OutDir) {
                $u.Status = '输出目录：' + $u.OutDir
            } else {
                $u.Status = '输出到原图所在目录。'
            }
        }
    }
    $u.Editing = $false
    $u.InputBuffer = ''
}

function Handle-TuiInput {
    param($KeyInfo)
    $u = $script:Ui
    $now = [Environment]::TickCount
    if ($KeyInfo.Key -eq 'Enter') {
        if (-not $u.TestMode -and $u.Field -eq 0 -and $u.InputBuffer.Length -gt 0 -and ($now - $u.LastKeyMs) -lt 60) {
            # 多行粘贴：紧跟在字符后面的回车视为换行分隔符，继续接收下一行路径
            $u.InputBuffer += ' '
        } else {
            Commit-TuiInput
        }
        $u.LastKeyMs = $now
        return
    }
    if ($KeyInfo.Key -eq 'Escape') {
        $u.Editing = $false
        $u.InputBuffer = ''
        $u.Status = '已取消。'
        $u.LastKeyMs = $now
        return
    }
    if ($KeyInfo.Key -eq 'Backspace') {
        if ($u.InputBuffer.Length -gt 0) {
            $u.InputBuffer = $u.InputBuffer.Substring(0, $u.InputBuffer.Length - 1)
        }
        $u.LastKeyMs = $now
        return
    }
    $ch = $KeyInfo.KeyChar
    if ($ch -eq [char]0) { $u.LastKeyMs = $now; return }
    if ($u.Field -eq 1 -or $u.Field -eq 2) {
        if ([char]::IsDigit($ch) -and $u.InputBuffer.Length -lt 5) { $u.InputBuffer += $ch }
    } elseif ($u.Field -eq 0 -or $u.Field -eq 4) {
        if ($u.InputBuffer.Length -lt 4000) { $u.InputBuffer += $ch }
    }
    $u.LastKeyMs = $now
}

function Activate-TuiField {
    $u = $script:Ui
    switch ($u.Field) {
        0 { Start-TuiAdd }
        1 {
            $u.Editing = $true
            $u.InputPrompt = '输入目标宽度（1-10000，当前 ' + $u.WidthText + '）'
            $u.InputBuffer = ''
        }
        2 {
            $u.Editing = $true
            $u.InputPrompt = '输入目标高度（1-10000，当前 ' + $u.HeightText + '）'
            $u.InputBuffer = ''
        }
        3 { $u.Mode = ($u.Mode + 1) % 3 }
        4 {
            $u.Editing = $true
            $u.InputPrompt = '输入输出目录（当前 ' + ($(if ($u.OutDir) { $u.OutDir } else { '默认与原图相同' })) + '）'
            $u.InputBuffer = ''
        }
        5 { $u.Status = '按 S 开始处理。' }
    }
}

function Start-TuiProcessing {
    $u = $script:Ui
    if ($u.Files.Count -eq 0) {
        $u.Status = '请先添加图片（按 A）。'
        return
    }
    $w = 0
    $h = 0
    if (-not [int]::TryParse($u.WidthText, [ref]$w) -or -not [int]::TryParse($u.HeightText, [ref]$h)) {
        $u.Status = '分辨率无效。'
        return
    }

    $modeName = $ModeNames[$u.Mode]
    $suffix = '_' + $w + 'x' + $h
    $total = $u.Files.Count
    $results = [System.Collections.Generic.List[object]]::new()
    $u.Processing = $true
    $u.ProcessingStart = [DateTime]::Now
    $u.SpinIndex = 0

    $i = 0
    try {
        foreach ($file in @($u.Files)) {
            $i++
            $u.SpinIndex++
            Render-TuiProcessing -Title ' 正在处理 ' -Current $i -Total $total -Results $results -CurrentFile $file
            Update-TuiScreen
            $r = Resize-OneImage -InputPath $file -TargetWidth $w -TargetHeight $h -ResizeMode $modeName -TargetOutDir $u.OutDir -OutputName '' -NameSuffix $suffix -JpegQuality $Quality
            $results.Add($r)
            if (-not $u.TestMode) {
                # 让进度条有足够时间被看到（批量大时缩短停留时间）
                $hold = if ($total -le 20) { 120 } else { 60 }
                if ($i -eq 1) { $hold = 350 }
                Start-Sleep -Milliseconds $hold
            }
        }
    } catch {
        if ($i -ge 1 -and $i -le $u.Files.Count) {
            $results.Add([pscustomobject]@{
                Path = $u.Files[$i - 1]
                OutPath = ''
                OutWidth = 0
                OutHeight = 0
                OK = $false
                Message = $_.Exception.Message
            })
        }
    } finally {
        $u.Processing = $false
        $u.Done = $true
        $u.Results = $results
        Render-TuiDone -Results $results -Total $total
        Update-TuiScreen
    }
}

function Handle-TuiKey {
    param($KeyInfo)
    $u = $script:Ui

    if ($null -eq $KeyInfo) { return }

    # 粘贴保护：添加文件后短暂忽略后续按键，防止多行粘贴的残留字符触发快捷键
    if (-not $u.TestMode -and [Environment]::TickCount -lt $u.CooldownUntil) { return }

    if ($KeyInfo.Key -ne 'X') { $u.ConfirmClear = $false }

    if ($u.Editing) {
        Handle-TuiInput $KeyInfo
        return
    }

    if ($u.Diag) {
        if ($KeyInfo.Key -eq 'F1' -or $KeyInfo.Key -eq 'Escape' -or $KeyInfo.Key -eq 'Enter') {
            $u.Diag = $false
        }
        return
    }

    if ($u.Done) {
        if ($KeyInfo.Key -eq 'Enter' -or $KeyInfo.Key -eq 'Spacebar') {
            $u.Done = $false
            $u.Results = $null
            $u.Field = 0
            $u.Status = '处理完成，可继续操作。'
        } elseif ($KeyInfo.Key -eq 'Q') {
            $u.Running = $false
        } elseif ($KeyInfo.Key -eq 'F1') {
            $u.Diag = $true
        }
        return
    }

    switch ($KeyInfo.Key) {
        'UpArrow'    { Move-TuiField -Step -1 }
        'DownArrow'  { Move-TuiField -Step 1 }
        'Tab'        { Move-TuiField -Step 1 }
        'Enter'      { Activate-TuiField }
        'F1'         { $u.Diag = $true }
        'Escape'     { $u.Status = '按 Q 退出，或使用 ↑↓ 选择项目。' }
        'Q'          { $u.Running = $false }
        'A'          { Start-TuiAdd }
        'X'          {
            if ($u.ConfirmClear) {
                $u.Files.Clear()
                $u.ConfirmClear = $false
                $u.Status = '文件列表已清空。'
            } elseif ($u.Files.Count -gt 0) {
                $u.ConfirmClear = $true
                $u.Status = '再次按 X 确认清空列表（按其他键取消）。'
            }
        }
        'S'          { Start-TuiProcessing }
        'LeftArrow'  { if ($u.Field -eq 3) { $u.Mode = ($u.Mode + 2) % 3 } }
        'RightArrow' { if ($u.Field -eq 3) { $u.Mode = ($u.Mode + 1) % 3 } }
        'D1'         { if ($u.Field -eq 3) { $u.Mode = 0 } }
        'D2'         { if ($u.Field -eq 3) { $u.Mode = 1 } }
        'D3'         { if ($u.Field -eq 3) { $u.Mode = 2 } }
    }
}

function New-TestKey {
    param([string]$KeyName, [char]$Char)
    return [ConsoleKeyInfo]::new($Char, [ConsoleKey]$KeyName, $false, $false, $false)
}

function Convert-TestTokens {
    param([string]$Spec)
    $keys = [System.Collections.Generic.List[object]]::new()
    foreach ($token in ($Spec -split ',')) {
        $special = $false
        switch ($token) {
            '<enter>'     { $keys.Add((New-TestKey 'Enter' ([char]13))); $special = $true }
            '<esc>'       { $keys.Add((New-TestKey 'Escape' ([char]27))); $special = $true }
            '<up>'        { $keys.Add((New-TestKey 'UpArrow' ([char]0))); $special = $true }
            '<down>'      { $keys.Add((New-TestKey 'DownArrow' ([char]0))); $special = $true }
            '<left>'      { $keys.Add((New-TestKey 'LeftArrow' ([char]0))); $special = $true }
            '<right>'     { $keys.Add((New-TestKey 'RightArrow' ([char]0))); $special = $true }
            '<tab>'       { $keys.Add((New-TestKey 'Tab' ([char]9))); $special = $true }
            '<backspace>' { $keys.Add((New-TestKey 'Backspace' ([char]8))); $special = $true }
            '<f1>'        { $keys.Add((New-TestKey 'F1' ([char]0))); $special = $true }
            default { $special = $false }
        }
        if ($special -or [string]::IsNullOrEmpty($token)) { continue }
        foreach ($ch in $token.ToCharArray()) {
            $keyName = 'A'
            if ($ch -ge [char]'0' -and $ch -le [char]'9') { $keyName = 'D' + $ch }
            elseif ($ch -ge [char]'a' -and $ch -le [char]'z') { $keyName = $ch.ToString().ToUpperInvariant() }
            elseif ($ch -ge [char]'A' -and $ch -le [char]'Z') { $keyName = $ch.ToString() }
            $keys.Add([ConsoleKeyInfo]::new($ch, [ConsoleKey]$keyName, $false, $false, $false))
        }
    }
    return @($keys)
}

function Read-TuiKey {
    $u = $script:Ui
    if ($u.TestMode) {
        if ($u.TestTokens.Count -eq 0) { return $null }
        $token = $u.TestTokens[0]
        $u.LastKey = $token.Key.ToString()
        if ($u.TestTokens.Count -eq 1) {
            $u.TestTokens = @()
        } else {
            $u.TestTokens = @($u.TestTokens[1..($u.TestTokens.Count - 1)])
        }
        return $token
    }
    $key = [Console]::ReadKey($true)
    $u.LastKey = $key.Key.ToString() + '/' + $key.KeyChar
    if ($env:RESIZE_TOOL_DEBUG) { Write-DebugLog ('按键: ' + $u.LastKey) }
    return $key
}

function Start-Tui {
    $u = @{
        Files        = [System.Collections.Generic.List[string]]::new()
        WidthText    = $Width.ToString()
        HeightText   = $Height.ToString()
        Mode         = 0
        OutDir       = ''
        Field        = 0
        Editing      = $false
        InputBuffer  = ''
        InputPrompt  = ''
        Status       = '按 A 添加图片，或把图片拖进窗口；S 开始处理。'
        LastKeyMs    = 0
        CooldownUntil = 0
        ConfirmClear = $false
        ProcessingStart = $null
        SpinIndex    = 0
        Diag         = $false
        LastKey      = ''
        LastError    = ''
        SizeWarned   = $false
        ScreenW      = 80
        ScreenH      = 24
        Grid         = $null
        Color        = $null
        Transcript   = [System.Collections.Generic.List[string]]::new()
        LastSnapshot = ''
        TestMode     = $false
        TestTokens   = @()
        Touched      = [System.Collections.Generic.List[object]]::new()
        Running      = $true
        Done         = $false
        Results      = $null
        Processing   = $false
    }
    $script:Ui = $u

    $tuiTest = $env:RESIZE_TUI_TEST
    if ($tuiTest) {
        $u.TestMode = $true
        $u.TestTokens = @(Convert-TestTokens $tuiTest)
    }

    $grid = New-TuiGrid $u.ScreenW $u.ScreenH
    $u.Grid = $grid.Grid
    $u.Color = $grid.Color

    if (-not $u.TestMode) {
        [Console]::CursorVisible = $false
        [Console]::WriteLine('正在启动图片分辨率修改工具 ' + $script:ToolVersion + ' …')
        [Console]::WriteLine('作者：FANCHUAN，请稍候…')
        try {
            if (-not ('ConsoleModeHelper' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleModeHelper {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
'@
            }
            $handle = [ConsoleModeHelper]::GetStdHandle(-10)
            $mode = 0
            if ([ConsoleModeHelper]::GetConsoleMode($handle, [ref]$mode)) {
                $script:PrevConsoleMode = $mode
                # 关闭“快速编辑模式”，避免点击窗口后界面被选择状态卡住
                $newMode = ($mode -bor 0x80) -band (-bnot 0x40)
                [ConsoleModeHelper]::SetConsoleMode($handle, $newMode) | Out-Null
            }
        } catch { }
        [Console]::Clear()
    }

    try {
        while ($u.Running) {
            # 窗口尺寸检查：太小就提示拉大窗口，避免画面错乱
            if (-not $u.TestMode) {
                try {
                    if ([Console]::WindowWidth -lt 78 -or [Console]::WindowHeight -lt 20) {
                        if (-not $u.SizeWarned) {
                            $u.SizeWarned = $true
                            [Console]::Clear()
                            [Console]::CursorVisible = $true
                            Write-Host ''
                            Write-Host '  窗口太小：请把窗口拉大到至少 80 x 24，然后按任意键' -ForegroundColor Yellow
                        }
                        $null = [Console]::ReadKey($true)
                        continue
                    }
                } catch { }
                $u.SizeWarned = $false
            }

            if ($u.Diag) {
                Render-TuiDiag
                Update-TuiScreen
            } elseif (-not $u.Processing -and -not $u.Done) {
                Render-Tui
                Update-TuiScreen
            } else {
                Update-TuiScreen
            }
            $key = Read-TuiKey
            if ($null -eq $key) { break }
            Handle-TuiKey $key
            if ($env:RESIZE_TOOL_DEBUG) {
                Write-DebugLog ('状态: field=' + $u.Field + ' files=' + $u.Files.Count + ' editing=' + $u.Editing + ' mode=' + $u.Mode)
            }
        }
    } catch {
        $u.LastError = $_.Exception.Message
        Write-DebugLog ('错误: ' + $_.Exception.ToString())
        if (-not $u.TestMode) {
            try {
                Reset-TuiGrid
                Draw-TuiBox 0 0 80 20 ' 程序错误 ' Red
                Write-TuiText 2 2 '发生错误，详细信息已写入日志：' White
                Write-TuiText 2 3 (Truncate-Display (Join-Path $script:ScriptDir 'resize800x600.log') 72) DarkGray
                Write-TuiText 2 5 (Truncate-Display ('错误: ' + $u.LastError) 72) Red
                $y = 7
                foreach ($line in ($_.Exception.ToString() -split "`r?`n")) {
                    if ($y -gt 16) { break }
                    Write-TuiText 2 $y (Truncate-Display $line 72) DarkGray
                    $y++
                }
                Write-TuiText 2 18 (Pad-Display '按任意键退出' 76) White
                Update-TuiScreen
                $null = [Console]::ReadKey($true)
            } catch { }
        }
    } finally {
        if (-not $u.TestMode) {
            [Console]::CursorVisible = $true
            [Console]::ResetColor()
            [Console]::WriteLine()
            try {
                if ($null -ne $script:PrevConsoleMode -and ('ConsoleModeHelper' -as [type])) {
                    $handle = [ConsoleModeHelper]::GetStdHandle(-10)
                    [ConsoleModeHelper]::SetConsoleMode($handle, [uint32]$script:PrevConsoleMode) | Out-Null
                }
            } catch { }
        }
    }

    if ($u.TestMode) {
        foreach ($screen in $u.Transcript) {
            Write-Host $screen
            Write-Host ('─' * 80)
        }
    }
}

# ================================================================
# 主流程
# ================================================================

if ($Path.Count -eq 0) {
    $useTui = $false
    if ($env:RESIZE_TUI_TEST) {
        $useTui = $true
    } else {
        try {
            $useTui = (-not [Console]::IsInputRedirected) -and
                [Console]::WindowWidth -ge 78 -and
                [Console]::WindowHeight -ge 20
        } catch {
            $useTui = $false
        }
    }
    if ($useTui) {
        try {
            Start-Tui
        } catch {
            $err = $_.Exception.Message
            Write-Host ''
            Write-Host ('启动界面失败：' + $err) -ForegroundColor Red
            try {
                $logPath = Join-Path $script:ScriptDir 'resize800x600.log'
                Add-Content -LiteralPath $logPath -Value ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] 启动失败: ' + $_.Exception.ToString()) -Encoding UTF8
                Write-Host ('错误日志已写入：' + $logPath) -ForegroundColor DarkGray
            } catch { }
            Write-Host ''
            Write-Host '按回车键退出…' -ForegroundColor DarkGray
            $null = Read-Host
        }
    } else {
        Show-SimpleMenu
    }
} else {
    $files = @(Resolve-ImageFiles -RawPaths $Path)
    if ($files.Count -eq 0) {
        Write-Error '没有找到可处理的图片文件。'
        exit 1
    }
    if ($Out -and $files.Count -gt 1) {
        Write-Error '-Out 只能用于单张图片。'
        exit 1
    }
    $code = Invoke-ResizeImages -Files $files -TargetWidth $Width -TargetHeight $Height -ResizeMode $Mode -TargetOutDir $OutDir -OutputName $Out -NameSuffix $Suffix -JpegQuality $Quality
    exit $code
}
