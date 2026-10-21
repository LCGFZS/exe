$dir = (Read-Host "Chemin du dossier").Trim('"').Trim()
if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Host "Dossier introuvable." -ForegroundColor Red; exit 1 }

Get-ChildItem -LiteralPath $dir -File | ForEach-Object { "{0,-50} {1,10:N1} Mo" -f $_.Name, ($_.Length/1MB) }

$name = (Read-Host "`nNom du fichier à découper").Trim('"').Trim()
$src = Join-Path $dir $name
if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Write-Host "Fichier introuvable." -ForegroundColor Red; exit 1 }

$sizeInput = (Read-Host "Taille max par partie (ex: 24Mo, 1Go, 500Ko)").Trim()
if ($sizeInput -match '^(\d+(?:[.,]\d+)?)\s*(To|Go|Mo|Ko|o)$') {
    $val = [decimal]($Matches[1] -replace ',', '.')
    $multiplier = switch ($Matches[2].ToLower()) {
        'to' { [long]1099511627776 }
        'go' { [long]1073741824 }
        'mo' { [long]1048576 }
        'ko' { [long]1024 }
        'o'  { [long]1 }
    }
    $max = [long]($val * $multiplier)
    if ($max -le 0) { Write-Host "La taille doit être supérieure à 0." -ForegroundColor Red; exit 1 }
} else {
    Write-Host "Format invalide. Exemples valides : 24Mo, 1Go, 500Ko, 1To" -ForegroundColor Red; exit 1
}

$base  = [IO.Path]::GetFileNameWithoutExtension($src)
$buf   = New-Object byte[] 4194304
$parts = @()

try {
    $in = [IO.File]::OpenRead($src)
    if ($in.Length -eq 0) { $in.Close(); Write-Host "Le fichier source est vide." -ForegroundColor Red; exit 1 }
    try {
        $i = 1
        while ($in.Position -lt $in.Length) {
            $partName = "${base}_p$i"
            $partPath = Join-Path $dir $partName
            try {
                $out = [IO.File]::Create($partPath)
                try {
                    [long]$written = 0
                    while ($written -lt $max) {
                        $toRead = [int][Math]::Min([long]$buf.Length, $max - $written)
                        $n = $in.Read($buf, 0, $toRead)
                        if ($n -le 0) { break }
                        $out.Write($buf, 0, $n)
                        $written += $n
                    }
                } finally { $out.Close() }
                Write-Host "$partName : $([Math]::Round($written/1MB,2)) Mo"
            } catch {
                Write-Host "Erreur sur la partie $partName : $_" -ForegroundColor Red; exit 1
            }
            $parts += $partName
            $i++
        }
    } finally { $in.Close() }
} catch {
    Write-Host "Erreur lors du découpage : $_" -ForegroundColor Red; exit 1
}

# Génération du .bat de recomposition
$safeName = $name -replace '\^', '^^' -replace '%', '%%'
$list = ($parts | ForEach-Object { "`"$_`"" }) -join '+'
$bat = @(
    '@echo off',
    'cd /d "%~dp0"',
    "copy /b $list `"$name`"",
    'echo.',
    "echo $safeName recompose."
) -join "`r`n"
try {
    $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    [IO.File]::WriteAllText((Join-Path $dir "recompiler_${base}.bat"), $bat, $oem)
} catch {
    Write-Host "Avertissement : impossible de créer le .bat : $_" -ForegroundColor Yellow
}

Write-Host "Terminé : $($parts.Count) partie(s) + recompiler_${base}.bat" -ForegroundColor Green
