<#
.SYNOPSIS
    Installe en une fois : Chrome, Firefox, Acrobat Reader, Teams, FortiClient VPN,
    TeamViewer QuickSupport (dans C:\teamviewer, avec raccourcis) et Microsoft 365 Apps (Office).

.DESCRIPTION
    A lancer en administrateur. Chaque logiciel est installe pour TOUS les utilisateurs
    de la machine (sauf TeamViewer QS, exe portable copie dans C:\teamviewer).
    Un logiciel deja installe est ignore, sauf avec -Force.
    Journal complet : C:\ProgramData\Install-Logiciels\

.PARAMETER Only
    N'installe que ces logiciels. Valeurs : chrome, firefox, acrobat, teams,
    forticlient, teamviewer, office.

.PARAMETER Skip
    Exclut ces logiciels (memes valeurs que -Only).

.PARAMETER Force
    Reinstalle meme si le logiciel est deja detecte.

.PARAMETER NoPause
    Ne demande pas d'appuyer sur Entree a la fin.

.EXAMPLE
    .\Install-Logiciels.ps1
.EXAMPLE
    .\Install-Logiciels.ps1 -Only chrome,teams
.EXAMPLE
    .\Install-Logiciels.ps1 -Skip office
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$Force,
    [switch]$NoPause,
    [string]$FirefoxLang      = 'fr',               # 'fr' = francais, 'en-US' = anglais
    [string]$OfficeProductId  = 'O365ProPlusRetail', # Microsoft 365 Apps. Business : 'O365BusinessRetail'
    [string]$OfficeLanguage   = 'fr-fr'
)

# ----------------------------------------------------------------------------
# Liens de telechargement (repris de vos raccourcis)
# ----------------------------------------------------------------------------
$Urls = @{
    # MSI Chrome, essayes dans l'ordre (le 1er est celui de votre raccourci) ; winget en dernier recours
    Chrome      = @(
        'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi',
        'https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise64.msi',
        'https://dl.google.com/edgedl/chrome/install/GoogleChromeStandaloneEnterprise64.msi'
    )
    Firefox     = "https://download.mozilla.org/?product=firefox-msi-latest-ssl&os=win64&lang=$FirefoxLang"
    Teams       = 'https://go.microsoft.com/fwlink/?linkid=2243204'
    Forti       = 'https://links.fortinet.com/forticlient/win/vpnagent'
    OfficeODT   = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20430-20146.exe'
    TeamViewer  = 'https://download.teamviewer.com/download/TeamViewerQS_x64.exe'
}

# ----------------------------------------------------------------------------
# Preparation
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # accelere fortement Invoke-WebRequest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Ce script doit etre lance en administrateur (clic droit > Executer en tant qu'administrateur)." -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Appuyez sur Entree pour fermer' | Out-Null }
    exit 1
}

$LogDir  = 'C:\ProgramData\Install-Logiciels'
$WorkDir = Join-Path $env:TEMP 'Install-Logiciels'
New-Item -ItemType Directory -Path $LogDir, $WorkDir -Force | Out-Null
Start-Transcript -Path (Join-Path $LogDir ("install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null

$Results      = [System.Collections.Generic.List[object]]::new()
$RebootNeeded = $false

# ----------------------------------------------------------------------------
# Fonctions utilitaires
# ----------------------------------------------------------------------------
function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $Results.Add([pscustomobject]@{ Logiciel = $Name; Statut = $Status; Detail = $Detail })
}

function Test-Installed {
    # Vrai si un logiciel dont le nom correspond est installe pour la machine (registre HKLM).
    param([string[]]$NamePattern)
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $apps = Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue
    foreach ($pattern in $NamePattern) {
        if ($apps | Where-Object { $_.DisplayName -like $pattern }) { return $true }
    }
    return $false
}

function Get-RemoteFile {
    param([string]$Url, [string]$OutFile, [int]$Retries = 3)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing `
                -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            if ((Get-Item $OutFile).Length -lt 100KB) {
                throw "Le fichier telecharge est trop petit (page d'erreur ?) : $Url"
            }
            return
        } catch {
            if ($i -eq $Retries) { throw }
            Write-Host "Echec du telechargement (essai $i/$Retries), nouvelle tentative..." -ForegroundColor Yellow
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

function Install-FromMsi {
    param([string]$Name, [string]$Url, [string]$FileName)
    $msi = Join-Path $WorkDir $FileName
    Write-Host "Telechargement de $Name..."
    Get-RemoteFile -Url $Url -OutFile $msi
    $log = Join-Path $LogDir "$Name-msi.log"
    Write-Host "Installation de $Name..."
    $msiArgs = @('/i', "`"$msi`"", '/qn', '/norestart', '/L*v', "`"$log`"")
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
    if ($p.ExitCode -eq 3010) { $script:RebootNeeded = $true }
    elseif ($p.ExitCode -ne 0) { throw "msiexec a retourne le code $($p.ExitCode) (voir $log)" }
}

function Install-WithWinget {
    param([string]$Id)
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wg) { throw 'winget est introuvable (installer "App Installer" depuis le Microsoft Store).' }
    & $wg.Source install --id $Id -e --scope machine --silent `
        --accept-package-agreements --accept-source-agreements | Out-Host
    $code = $LASTEXITCODE
    # -1978335189 (0x8A15002B) = deja a jour / rien a faire : pas une erreur
    if ($code -ne 0 -and $code -ne -1978335189) { throw "winget a retourne le code $code" }
}

function New-Shortcut {
    param([string]$Path, [string]$Target, [string]$Description = '')
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath       = $Target
    $lnk.WorkingDirectory = Split-Path -Parent $Target
    $lnk.IconLocation     = "$Target,0"
    $lnk.Description      = $Description
    $lnk.Save()
}

function Invoke-Step {
    param([string]$Key, [string]$Label, [scriptblock]$Action)
    if ($Only -and ($Only -notcontains $Key)) { return }
    if ($Skip -and ($Skip -contains $Key))    { Add-Result $Label 'Ignore' 'Exclu par -Skip'; return }
    Write-Host ""
    Write-Host "=== $Label ===" -ForegroundColor Cyan
    try {
        $detail = & $Action | Select-Object -Last 1
        Add-Result $Label 'OK' ([string]$detail)
        Write-Host "OK : $detail" -ForegroundColor Green
    } catch {
        Write-Host "ERREUR : $($_.Exception.Message)" -ForegroundColor Red
        Add-Result $Label 'ECHEC' $_.Exception.Message
    }
}

# ----------------------------------------------------------------------------
# Installations
# ----------------------------------------------------------------------------

Invoke-Step 'chrome' 'Google Chrome' {
    if (-not $Force -and (Test-Installed 'Google Chrome*')) { return 'Deja installe' }

    # 1) MSI en priorite : on essaie chaque lien dans l'ordre
    $done = $false
    foreach ($url in $Urls.Chrome) {
        try {
            Install-FromMsi -Name 'Chrome' -Url $url -FileName 'chrome64.msi'
            $done = $true
            $how  = "MSI ($url)"
            break
        } catch {
            Write-Host "MSI en echec avec $url : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # 2) winget uniquement en dernier recours
    if (-not $done) {
        Write-Host 'Aucun MSI n''a fonctionne, dernier recours : winget...' -ForegroundColor Yellow
        Install-WithWinget -Id 'Google.Chrome'
        $how = 'winget (dernier recours)'
    }
    "Installe pour tous les utilisateurs via $how"
}

Invoke-Step 'firefox' 'Mozilla Firefox' {
    if (-not $Force -and (Test-Installed 'Mozilla Firefox*')) { return 'Deja installe' }
    Install-FromMsi -Name 'Firefox' -Url $Urls.Firefox -FileName 'firefox.msi'
    'Installe (tous les utilisateurs)'
}

Invoke-Step 'acrobat' 'Adobe Acrobat Reader' {
    if (-not $Force -and (Test-Installed 'Adobe Acrobat*')) { return 'Deja installe' }
    Install-WithWinget -Id 'Adobe.Acrobat.Reader.64-bit'
    'Installe via winget (machine)'
}

Invoke-Step 'teams' 'Microsoft Teams (nouvelle version)' {
    $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*MSTeams*' }
    if (-not $Force -and $prov) { return 'Deja provisionne' }
    $exe = Join-Path $WorkDir 'teamsbootstrapper.exe'
    Write-Host 'Telechargement du bootstrapper Teams...'
    Get-RemoteFile -Url $Urls.Teams -OutFile $exe
    Write-Host 'Provisionnement de Teams pour tous les utilisateurs...'
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = (& $exe -p 2>&1 | Out-String) } finally { $ErrorActionPreference = $old }
    Write-Host $out
    if ($out -notmatch '"success"\s*:\s*true') { throw "Le bootstrapper n'a pas confirme le succes : $out" }
    'Provisionne (Teams apparait a la prochaine ouverture de session)'
}

Invoke-Step 'forticlient' 'FortiClient VPN' {
    if (-not $Force -and (Test-Installed 'FortiClient*')) { return 'Deja installe' }
    $exe = Join-Path $WorkDir 'FortiClientVPNOnlineInstaller.exe'
    Write-Host 'Telechargement de FortiClient VPN (installateur en ligne)...'
    Get-RemoteFile -Url $Urls.Forti -OutFile $exe
    Write-Host 'Installation de FortiClient VPN...'
    $log = Join-Path $LogDir 'FortiClientVPN-install.log'
    Start-Process -FilePath $exe -ArgumentList '/quiet', '/norestart', '/log', "`"$log`"" -Wait
    # L'installateur en ligne peut rendre la main avant la fin : on attend l'apparition du logiciel.
    $deadline = (Get-Date).AddMinutes(10)
    while (-not (Test-Installed 'FortiClient*') -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
    if (-not (Test-Installed 'FortiClient*')) { throw "Installation non detectee apres 10 min (voir $log)" }
    'Installe (tous les utilisateurs)'
}

Invoke-Step 'teamviewer' 'TeamViewer QuickSupport' {
    $dir  = 'C:\teamviewer'
    $dest = Join-Path $dir 'TeamViewerQS.exe'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Host 'Telechargement de TeamViewer QuickSupport...'
    Get-RemoteFile -Url $Urls.TeamViewer -OutFile $dest
    $info = @("Fichier : $dest")

    # Raccourcis : Bureau public + menu Demarrer commun (C:\ProgramData\Microsoft\Windows\Start Menu\Programs)
    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $startMenu     = [Environment]::GetFolderPath('CommonPrograms')
    $startLnk      = Join-Path $startMenu 'TeamViewerQS.lnk'
    New-Shortcut -Path (Join-Path $publicDesktop 'TeamViewerQS.lnk') -Target $dest -Description 'TeamViewer QuickSupport'
    New-Shortcut -Path $startLnk -Target $dest -Description 'TeamViewer QuickSupport'
    $info += 'raccourcis : Bureau public + menu Demarrer commun'

    # Barre des taches : Windows n'a pas de barre des taches "publique". Seule methode fiable :
    # un LayoutModification.xml dans le profil Default, qui epingle l'application pour les
    # NOUVEAUX profils (au 1er ouverture de session). Les profils existants ne sont pas modifies.
    try {
        $shellDir = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell'
        $layout   = Join-Path $shellDir 'LayoutModification.xml'
        if (Test-Path $layout) {
            $info += 'barre des taches : LayoutModification.xml deja present, epingle non ajoute (a ajouter a la main)'
        } else {
            New-Item -ItemType Directory -Path $shellDir -Force | Out-Null
            @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection>
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\TeamViewerQS.lnk" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@ | Set-Content -Path $layout -Encoding UTF8
            $info += 'barre des taches : epingle pour les nouveaux profils uniquement'
        }
    } catch {
        $info += "barre des taches : echec ($($_.Exception.Message))"
    }
    $info -join ' | '
}

Invoke-Step 'office' 'Microsoft 365 Apps (Office)' {
    if (-not $Force -and (Test-Installed 'Microsoft 365*', 'Microsoft Office*')) { return 'Deja installe' }
    $odt    = Join-Path $WorkDir 'officedeploymenttool.exe'
    $odtDir = Join-Path $WorkDir 'odt'
    New-Item -ItemType Directory -Path $odtDir -Force | Out-Null
    Write-Host "Telechargement de l'Office Deployment Tool..."
    Get-RemoteFile -Url $Urls.OfficeODT -OutFile $odt
    Start-Process -FilePath $odt -ArgumentList '/quiet', "/extract:`"$odtDir`"" -Wait
    $setup = Join-Path $odtDir 'setup.exe'
    if (-not (Test-Path $setup)) { throw "setup.exe introuvable apres extraction de l'ODT" }

    $cfg = Join-Path $odtDir 'configuration.xml'
    @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="$OfficeProductId">
      <Language ID="$OfficeLanguage" />
    </Product>
  </Add>
  <Updates Enabled="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
"@ | Set-Content -Path $cfg -Encoding ASCII

    Write-Host 'Installation de Microsoft 365 Apps (plusieurs Go, cela peut prendre 10 a 30 min)...'
    $p = Start-Process -FilePath $setup -ArgumentList '/configure', "`"$cfg`"" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "setup.exe /configure a retourne le code $($p.ExitCode)" }
    "Installe ($OfficeProductId, $OfficeLanguage). Activation a faire a la premiere ouverture."
}

# ----------------------------------------------------------------------------
# Bilan
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "================ BILAN ================" -ForegroundColor Cyan
$Results | Format-Table -AutoSize -Wrap | Out-Host
if ($RebootNeeded) { Write-Host 'Un redemarrage est recommande.' -ForegroundColor Yellow }
Write-Host "Journal : $LogDir"

Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
Stop-Transcript | Out-Null

if (-not $NoPause) { Read-Host 'Termine, appuyez sur Entree pour fermer' | Out-Null }
if ($Results | Where-Object { $_.Statut -eq 'ECHEC' }) { exit 1 } else { exit 0 }
