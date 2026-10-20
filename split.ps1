$dir = (Read-Host "Chemin du dossier").Trim('"').Trim()
if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Host "Dossier introuvable." -ForegroundColor Red; return }

Get-ChildItem -LiteralPath $dir -File | ForEach-Object { "{0,-50} {1,10:N1} Mo" -f $_.Name, ($_.Length/1MB) }

$name = (Read-Host "`nNom du fichier à découper").Trim('"').Trim()
$src = Join-Path $dir $name
if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Write-Host "Fichier introuvable." -ForegroundColor Red; return }

$max  = 24000000
$base = [IO.Path]::GetFileNameWithoutExtension($src)
$buf  = New-Object byte[] 4MB
$parts = @()

$in = [IO.File]::OpenRead($src)
try {
    $i = 1
    while ($in.Position -lt $in.Length) {
        $partName = "${base}_p$i"
        $out = [IO.File]::Create((Join-Path $dir $partName))
        try {
            $written = 0
            while ($written -lt $max) {
                $n = $in.Read($buf, 0, [Math]::Min($buf.Length, $max - $written))
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n)
                $written += $n
            }
        } finally { $out.Close() }
        $parts += $partName
        Write-Host "$partName : $([Math]::Round($written/1MB,2)) Mo"
        $i++
    }
} finally { $in.Close() }

# Génération du .bat de recomposition
$list = ($parts | ForEach-Object { "`"$_`"" }) -join '+'
$bat = @(
    '@echo off',
    'cd /d "%~dp0"',
    "copy /b $list `"$name`"",
    'echo.',
    "echo $name recompose."
) -join "`r`n"
$oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
[IO.File]::WriteAllText((Join-Path $dir "recompiler_${base}.bat"), $bat, $oem)

Write-Host "Terminé : $($parts.Count) partie(s) + recompiler_${base}.bat" -ForegroundColor Green
