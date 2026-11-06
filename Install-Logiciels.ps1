#requires -Version 5.1
<#
.SYNOPSIS
    Deploiement machine des logiciels NETPLUS : Chrome, Firefox FR, Acrobat Reader,
    Microsoft 365 Apps, nouveau Teams, FortiClient VPN et TeamViewer QuickSupport.

.DESCRIPTION
    A executer dans Windows PowerShell 5.1 en tant qu'administrateur.
    Les applications sont installees/mises a jour au niveau machine pour etre accessibles
    a tous les utilisateurs du poste. TeamViewer QuickSupport est un executable portable
    place dans C:\teamviewer, avec raccourcis communs.

    Les journaux sont conserves dans C:\ProgramData\Install-Logiciels.

.PARAMETER Only
    Ne traite que les logiciels indiques : chrome, firefox, acrobat, office, teams,
    forticlient, teamviewer.
.PARAMETER Skip
    Exclut les logiciels indiques.
.PARAMETER Force
    Force la reexecution des actions meme si une installation est deja detectee.
.PARAMETER NoPause
    Ne demande pas d'appuyer sur Entree a la fin.
.PARAMETER FirefoxLang
    Code de langue Firefox. Valeur par defaut : fr.
.PARAMETER OfficeProductId
    O365ProPlusRetail (Microsoft 365 Apps pour grandes entreprises) ou O365BusinessRetail.
.PARAMETER OfficeLanguage
    Langue Office. Valeur par defaut : fr-fr.

.EXAMPLE
    .\Install-Logiciels.ps1
.EXAMPLE
    .\Install-Logiciels.ps1 -Only chrome,firefox
.EXAMPLE
    .\Install-Logiciels.ps1 -Skip teamviewer -NoPause
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$Force,
    [switch]$NoPause,
    [ValidateNotNullOrEmpty()][string]$FirefoxLang = 'fr',
    [ValidateNotNullOrEmpty()][string]$OfficeProductId = 'O365ProPlusRetail',
    [ValidateNotNullOrEmpty()][string]$OfficeLanguage = 'fr-fr'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Liens repris du ZIP fourni. Firefox est volontairement passe en francais.
$Urls = @{
    Chrome     = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    Firefox    = "https://download.mozilla.org/?product=firefox-msi-latest-ssl&os=win64&lang=$FirefoxLang"
    Teams      = 'https://go.microsoft.com/fwlink/?linkid=2243204'
    Forti      = 'https://links.fortinet.com/forticlient/win/vpnagent'
    OfficeODT  = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20430-20146.exe'
    TeamViewer = 'https://download.teamviewer.com/download/TeamViewerQS_x64.exe'
}

$LogDir  = 'C:\ProgramData\Install-Logiciels'
$WorkDir = Join-Path $env:TEMP 'Install-Logiciels'
$null = New-Item -ItemType Directory -Path $LogDir, $WorkDir -Force
$TranscriptPath = Join-Path $LogDir ("install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$TranscriptStarted = $false
$Results = New-Object 'System.Collections.Generic.List[object]'
$script:RebootNeeded = $false

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $Results.Add([pscustomobject]@{ Logiciel = $Name; Statut = $Status; Detail = $Detail })
}

function Test-Installed {
    param([string[]]$NamePattern)
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = @(foreach ($path in $paths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    })
    foreach ($pattern in $NamePattern) {
        if ($apps | Where-Object { $_.DisplayName -and $_.DisplayName -like $pattern }) {
            return $true
        }
    }
    return $false
}

function Wait-ForInstalled {
    param(
        [string[]]$NamePattern,
        [string[]]$Paths = @(),
        [int]$TimeoutMinutes = 10
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        if ($NamePattern -and (Test-Installed -NamePattern $NamePattern)) { return $true }
        foreach ($path in $Paths) {
            if (Test-Path -LiteralPath $path) { return $true }
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-RemoteFile {
    param([string]$Url, [string]$OutFile, [long]$MinimumBytes = 100KB, [int]$Retries = 3)
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            if (Test-Path -LiteralPath $OutFile) {
                Remove-Item -LiteralPath $OutFile -Force
            }
            Write-Host "Telechargement : $Url"
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -MaximumRedirection 10 `
                -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            if (-not (Test-Path -LiteralPath $OutFile)) { throw 'Le fichier telecharge est introuvable.' }
            $file = Get-Item -LiteralPath $OutFile
            if ($file.Length -lt $MinimumBytes) {
                throw "Fichier trop petit ($($file.Length) octets), probablement une page d'erreur."
            }
            return $OutFile
        }
        catch {
            if ($attempt -ge $Retries) { throw }
            Write-Warning "Echec du telechargement (tentative $attempt/$Retries) : $($_.Exception.Message)"
            Start-Sleep -Seconds (3 * $attempt)
        }
    }
}

function Assert-Authenticode {
    param([string]$Path, [string]$ExpectedPublisher)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        throw "Signature numerique invalide ou absente pour '$Path' (etat : $($sig.Status))."
    }
    $subject = [string]$sig.SignerCertificate.Subject
    if ($subject -notmatch $ExpectedPublisher) {
        throw "Editeur inattendu pour '$Path'. Certificat : $subject ; attendu : $ExpectedPublisher"
    }
    Write-Host "Signature valide : $subject" -ForegroundColor DarkGreen
}

function Invoke-MsiInstall {
    param([string]$Name, [string]$Url, [string]$FileName, [string]$PublisherPattern)
    $msi = Join-Path $WorkDir $FileName
    $null = Get-RemoteFile -Url $Url -OutFile $msi -MinimumBytes 500KB
    Assert-Authenticode -Path $msi -ExpectedPublisher $PublisherPattern
    $log = Join-Path $LogDir "$Name-msi.log"
    Write-Host "Installation / mise a jour de $Name pour la machine..."
    $arguments = "/i `"$msi`" /qn /norestart /L*v `"$log`""
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -eq 3010) {
        $script:RebootNeeded = $true
    }
    elseif ($process.ExitCode -eq 1641) {
        $script:RebootNeeded = $true
    }
    elseif ($process.ExitCode -ne 0) {
        throw "msiexec a retourne le code $($process.ExitCode). Journal : $log"
    }
    return $log
}

function Invoke-Winget {
    param([string[]]$Arguments, [string]$LogName)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $candidate) {
            $wingetPath = $candidate
        }
        else {
            throw 'winget est introuvable. Installez ou mettez a jour App Installer (Microsoft Store), puis relancez le script.'
        }
    }
    else {
        $wingetPath = $winget.Source
    }
    $log = Join-Path $LogDir $LogName
    Write-Host "Commande : winget $($Arguments -join ' ')"
    & $wingetPath @Arguments *> $log
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "winget a retourne le code $code. Journal : $log"
    }
    return $log
}

function New-CommonShortcut {
    param([string]$Path, [string]$Target, [string]$Description)
    $parent = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $parent -Force
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.WorkingDirectory = Split-Path -Parent $Target
    $shortcut.IconLocation = "$Target,0"
    $shortcut.Description = $Description
    $shortcut.Save()
    if (-not (Test-Path -LiteralPath $Path)) { throw "Raccourci non cree : $Path" }
}

function Invoke-Step {
    param([string]$Key, [string]$Label, [scriptblock]$Action)
    if ($Only -and ($Only -notcontains $Key)) { return }
    if ($Skip -and ($Skip -contains $Key)) {
        Add-Result -Name $Label -Status 'IGNORE' -Detail 'Exclu par -Skip'
        return
    }
    Write-Host "`n========== $Label ==========" -ForegroundColor Cyan
    try {
        $detail = & $Action | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$detail)) { $detail = 'Action terminee ; voir les controles et journaux.' }
        Add-Result -Name $Label -Status 'OK' -Detail ([string]$detail)
        Write-Host "OK : $detail" -ForegroundColor Green
    }
    catch {
        $message = $_.Exception.Message
        Add-Result -Name $Label -Status 'ECHEC' -Detail $message
        Write-Host "ECHEC : $message" -ForegroundColor Red
    }
}

# Verification des parametres et droits avant de commencer.
$validKeys = @('chrome','firefox','acrobat','office','teams','forticlient','teamviewer')
foreach ($value in @($Only) + @($Skip)) {
    if ($value -and ($validKeys -notcontains $value.ToLowerInvariant())) {
        Write-Host "Option inconnue : $value. Valeurs autorisees : $($validKeys -join ', ')" -ForegroundColor Red
        if (-not $NoPause) { Read-Host 'Appuyez sur Entree pour fermer' | Out-Null }
        exit 2
    }
}
if ($OfficeProductId -notin @('O365ProPlusRetail','O365BusinessRetail')) {
    Write-Host 'OfficeProductId doit etre O365ProPlusRetail ou O365BusinessRetail.' -ForegroundColor Red
    exit 2
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    Write-Host 'Ce script doit etre lance avec Windows PowerShell 64 bits sur Windows 64 bits.' -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Appuyez sur Entree pour fermer' | Out-Null }
    exit 1
}
if (-not $isAdmin) {
    Write-Host 'Ce script doit etre lance en administrateur.' -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Appuyez sur Entree pour fermer' | Out-Null }
    exit 1
}

try {
    Start-Transcript -Path $TranscriptPath -ErrorAction Stop | Out-Null
    $TranscriptStarted = $true

    Write-Host 'Deploiement machine : les applications installees seront accessibles a tous les utilisateurs.' -ForegroundColor Cyan
    Write-Host "Journaux : $LogDir"

    # Chrome : MSI Enterprise installe au niveau systeme. La strategie machine impose l'interface FR.
    Invoke-Step 'chrome' 'Google Chrome (francais, tous utilisateurs)' {
        $null = Invoke-MsiInstall -Name 'Chrome' -Url $Urls.Chrome -FileName 'chrome-enterprise-x64.msi' -PublisherPattern 'Google LLC'
        $policy = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
        $null = New-Item -Path $policy -Force
        $null = New-ItemProperty -Path $policy -Name 'ApplicationLocaleValue' -Value 'fr' -PropertyType String -Force
        if (-not (Wait-ForInstalled -NamePattern @('Google Chrome*') -Paths @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        ) -TimeoutMinutes 5)) { throw 'Chrome ne figure pas dans les emplacements/cles de verification apres installation.' }
        'MSI Enterprise installe au niveau machine ; politique de langue fr appliquee (redemarrer Chrome pour prise en compte).'
    }

    # Firefox : l'URL Mozilla est explicitement demandee en francais ; MSI machine-wide.
    Invoke-Step 'firefox' 'Mozilla Firefox (francais, tous utilisateurs)' {
        $null = Invoke-MsiInstall -Name 'Firefox' -Url $Urls.Firefox -FileName 'firefox-x64-fr.msi' -PublisherPattern 'Mozilla Corporation'
        if (-not (Wait-ForInstalled -NamePattern @('Mozilla Firefox*') -Paths @(
            "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
            "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
        ) -TimeoutMinutes 5)) { throw 'Firefox ne figure pas dans les emplacements/cles de verification apres installation.' }
        'MSI Mozilla en langue fr installe au niveau machine.'
    }

    # Acrobat : la source du raccourci fourni est winget ; on utilise l'identifiant exact.
    Invoke-Step 'acrobat' 'Adobe Acrobat Reader (derniere version, tous utilisateurs)' {
        $patterns = @('Adobe Acrobat*','Adobe Reader*')
        if (Test-Installed -NamePattern $patterns) {
            $wingetArgs = @('upgrade','--id','Adobe.Acrobat.Reader.64-bit','-e','--scope','machine','--silent','--accept-package-agreements','--accept-source-agreements','--include-unknown')
            if ($Force) { $wingetArgs += '--force' }
            $null = Invoke-Winget -Arguments $wingetArgs -LogName 'Acrobat-winget-upgrade.log'
            $action = 'mise a jour'
        }
        else {
            $wingetArgs = @('install','--id','Adobe.Acrobat.Reader.64-bit','-e','--scope','machine','--silent','--accept-package-agreements','--accept-source-agreements')
            if ($Force) { $wingetArgs += '--force' }
            $null = Invoke-Winget -Arguments $wingetArgs -LogName 'Acrobat-winget-install.log'
            $action = 'installation'
        }
        if (-not (Wait-ForInstalled -NamePattern $patterns -TimeoutMinutes 10)) { throw 'Adobe Acrobat Reader non detecte apres la commande winget.' }
        "Adobe Acrobat Reader : $action via winget, portee machine."
    }

    # Office avant Teams : prerequis conseille par Microsoft pour le deploiement en masse de Teams.
    Invoke-Step 'office' 'Microsoft 365 Apps (64 bits, francais, tous utilisateurs)' {
        $odt = Join-Path $WorkDir 'officedeploymenttool.exe'
        $odtDir = Join-Path $WorkDir 'odt'
        $null = Get-RemoteFile -Url $Urls.OfficeODT -OutFile $odt -MinimumBytes 1MB
        Assert-Authenticode -Path $odt -ExpectedPublisher 'Microsoft Corporation'
        if (Test-Path -LiteralPath $odtDir) { Remove-Item -LiteralPath $odtDir -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $odtDir -Force
        $extract = Start-Process -FilePath $odt -ArgumentList "/quiet /extract:`"$odtDir`"" -Wait -PassThru
        if ($extract.ExitCode -ne 0) { throw "Extraction ODT en echec (code $($extract.ExitCode))." }
        $setup = Join-Path $odtDir 'setup.exe'
        if (-not (Test-Path -LiteralPath $setup)) { throw 'setup.exe introuvable apres extraction de l’ODT.' }
        $config = Join-Path $odtDir 'configuration.xml'
        $odtLogDir = Join-Path $LogDir 'Office-ODT'
        $null = New-Item -ItemType Directory -Path $odtLogDir -Force
        @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="$OfficeProductId">
      <Language ID="$OfficeLanguage" />
    </Product>
  </Add>
  <Updates Enabled="TRUE" Channel="Current" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Logging Level="Standard" Path="$odtLogDir" />
</Configuration>
"@ | Set-Content -Path $config -Encoding ASCII
        Write-Host 'ODT installe ou met a jour Microsoft 365 Apps ; le telechargement peut durer plusieurs minutes.'
        $process = Start-Process -FilePath $setup -ArgumentList "/configure `"$config`"" -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Office Deployment Tool a retourne le code $($process.ExitCode). Voir $odtLogDir." }
        $deadline = (Get-Date).AddMinutes(45)
        $officeReady = $false
        do {
            $ctr = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
            if ($ctr -and ([string]$ctr.ProductReleaseIds -match [regex]::Escape($OfficeProductId))) { $officeReady = $true; break }
            Start-Sleep -Seconds 10
        } while ((Get-Date) -lt $deadline)
        if (-not $officeReady) { throw "Microsoft 365 Apps non detecte apres ODT. Voir les journaux : $odtLogDir" }
        "Produit $OfficeProductId, 64 bits, langue $OfficeLanguage, canal Current ; installation/mise a jour machine terminee. Activation selon licence de l'entreprise."
    }

    # Teams : le bootstrapper -p est la methode Microsoft de provisionnement pour tous les utilisateurs.
    Invoke-Step 'teams' 'Nouveau Microsoft Teams (tous utilisateurs)' {
        $bootstrapper = Join-Path $WorkDir 'teamsbootstrapper.exe'
        $null = Get-RemoteFile -Url $Urls.Teams -OutFile $bootstrapper -MinimumBytes 500KB
        Assert-Authenticode -Path $bootstrapper -ExpectedPublisher 'Microsoft Corporation'
        Write-Host 'Provisionnement de la derniere version de Teams pour tous les utilisateurs...'
        $output = @(& $bootstrapper -p 2>&1)
        $exitCode = $LASTEXITCODE
        $outputText = ($output | Out-String).Trim()
        if ($outputText) { Write-Host $outputText }
        if ($exitCode -ne 0) { throw "TeamsBootstrapper a retourne le code $exitCode. Sortie : $outputText" }
        $deadline = (Get-Date).AddMinutes(10)
        $provisioned = $false
        do {
            $packages = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -like '*MSTeams*' -or $_.PackageName -like '*MSTeams*'
            })
            if ($packages.Count -gt 0) { $provisioned = $true; break }
            Start-Sleep -Seconds 5
        } while ((Get-Date) -lt $deadline)
        if (-not $provisioned) { throw 'TeamsBootstrapper s''est termine sans paquet MSTeams provisionne.' }
        'Nouvelle version Teams provisionnee au niveau machine pour les utilisateurs existants et futurs ; disponible a leur prochaine ouverture de session.'
    }

    # FortiClient VPN : installateur officiel fourni ; verification de signature, code retour et presence.
    Invoke-Step 'forticlient' 'FortiClient VPN (tous utilisateurs)' {
        $installer = Join-Path $WorkDir 'FortiClientVPNOnlineInstaller.exe'
        $null = Get-RemoteFile -Url $Urls.Forti -OutFile $installer -MinimumBytes 500KB
        Assert-Authenticode -Path $installer -ExpectedPublisher 'Fortinet'
        $log = Join-Path $LogDir 'FortiClientVPN-install.log'
        Write-Host 'Installation / mise a jour FortiClient VPN...'
        $process = Start-Process -FilePath $installer -ArgumentList "/quiet /norestart /log `"$log`"" -Wait -PassThru
        if ($process.ExitCode -eq 3010 -or $process.ExitCode -eq 1641) { $script:RebootNeeded = $true }
        elseif ($process.ExitCode -ne 0) { throw "Installateur FortiClient : code $($process.ExitCode). Voir $log" }
        if (-not (Wait-ForInstalled -NamePattern @('FortiClient*','Fortinet FortiClient*') -TimeoutMinutes 15)) {
            throw "FortiClient VPN non detecte apres 15 minutes. Voir $log"
        }
        'FortiClient VPN detecte dans les entrees machine apres installation.'
    }

    # TeamViewer QuickSupport : executable portable partage, pas une installation MSI.
    Invoke-Step 'teamviewer' 'TeamViewer QuickSupport (C:\teamviewer + raccourcis communs)' {
        $directory = 'C:\teamviewer'
        $exe = Join-Path $directory 'TeamViewerQS.exe'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $null = Get-RemoteFile -Url $Urls.TeamViewer -OutFile $exe -MinimumBytes 500KB
        Assert-Authenticode -Path $exe -ExpectedPublisher 'TeamViewer'
        $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
        $commonPrograms = [Environment]::GetFolderPath('CommonPrograms')
        if ([string]::IsNullOrWhiteSpace($publicDesktop)) { $publicDesktop = 'C:\Users\Public\Desktop' }
        if ([string]::IsNullOrWhiteSpace($commonPrograms)) { $commonPrograms = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs' }
        New-CommonShortcut -Path (Join-Path $publicDesktop 'TeamViewer QuickSupport.lnk') -Target $exe -Description 'TeamViewer QuickSupport'
        New-CommonShortcut -Path (Join-Path $commonPrograms 'TeamViewer QuickSupport.lnk') -Target $exe -Description 'TeamViewer QuickSupport'
        'Executable dans C:\teamviewer ; raccourcis crees sur le Bureau public et dans le menu Demarrer commun.'
    }

    Write-Host "`n================ BILAN FINAL ================" -ForegroundColor Cyan
    $Results | Format-Table -AutoSize -Wrap | Out-Host
    if ($script:RebootNeeded) {
        Write-Host 'Un redemarrage de Windows est necessaire ou recommande pour finaliser certains composants.' -ForegroundColor Yellow
    }
    Write-Host "Journaux : $LogDir"
}
catch {
    Write-Host "ERREUR GENERALE : $($_.Exception.Message)" -ForegroundColor Red
    Add-Result -Name 'Script' -Status 'ECHEC' -Detail $_.Exception.Message
}
finally {
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
    # On conserve les journaux, mais on nettoie les installateurs temporaires.
    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Results | Where-Object { $_.Statut -eq 'ECHEC' }) {
    if (-not $NoPause) { Read-Host 'Termine avec des erreurs. Appuyez sur Entree pour fermer' | Out-Null }
    exit 1
}
if (-not $NoPause) { Read-Host 'Termine. Appuyez sur Entree pour fermer' | Out-Null }
exit 0
