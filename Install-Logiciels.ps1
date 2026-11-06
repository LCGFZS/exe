#requires -Version 5.1
<#
.SYNOPSIS
    Deploiement machine NETPLUS : Chrome, Firefox FR, Acrobat Reader,
    Microsoft 365, nouveau Teams, FortiClient VPN et TeamViewer QuickSupport.
.DESCRIPTION
    Windows PowerShell 5.1 64 bits, lance en administrateur.
    Installe pour tous les utilisateurs lorsque l'editeur le permet.
    Les journaux sont conserves dans C:\ProgramData\Install-Logiciels.
.PARAMETER Only
    Liste facultative : chrome, firefox, acrobat, office, teams, forticlient, teamviewer.
.PARAMETER Skip
    Logiciels a exclure.
.PARAMETER Force
    Force la reinstallation/reexecution lorsque l'installateur ou WinGet le permet.
    Les installateurs qui gerent eux-memes la mise a niveau sont relances a chaque execution.
.PARAMETER NoPause
    Ne demande pas de confirmation a la fin.
.PARAMETER FirefoxLang
    Langue du MSI Firefox (fr par defaut).
.PARAMETER OfficeProductId
    O365ProPlusRetail ou O365BusinessRetail.
.PARAMETER OfficeLanguage
    Langue Office (fr-fr par defaut).
.NOTES
    Le script ne configure pas les profils VPN, les comptes Microsoft 365,
    les licences ou les parametres propres a NETPLUS.
#>

[CmdletBinding()]
param(
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$Force,
    [switch]$NoPause,
    [ValidateNotNullOrEmpty()][string]$FirefoxLang = 'fr',
    [ValidateSet('O365ProPlusRetail','O365BusinessRetail')][string]$OfficeProductId = 'O365ProPlusRetail',
    [ValidateNotNullOrEmpty()][string]$OfficeLanguage = 'fr-fr'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$LogDir = 'C:\ProgramData\Install-Logiciels'
$WorkDir = Join-Path $env:TEMP ('Install-Logiciels-' + [guid]::NewGuid().ToString('N'))
$TranscriptPath = Join-Path $LogDir ("install-{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date),([guid]::NewGuid().ToString('N').Substring(0,8)))
$TranscriptStarted = $false
$Results = New-Object 'System.Collections.Generic.List[object]'
$script:RebootNeeded = $false
$script:Failures = 0

$Urls = @{
    Chrome     = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    Firefox    = "https://download.mozilla.org/?product=firefox-msi-latest-ssl&os=win64&lang=$FirefoxLang"
    Teams      = 'https://go.microsoft.com/fwlink/?linkid=2243204'
    Forti      = 'https://links.fortinet.com/forticlient/win/vpnagent'
    OfficeODT  = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20430-20146.exe'
    TeamViewer = 'https://download.teamviewer.com/download/TeamViewerQS_x64.exe'
}

function Add-Result {
    param([string]$Name,[string]$Status,[string]$Detail = '')
    $Results.Add([pscustomobject]@{ Logiciel=$Name; Statut=$Status; Detail=$Detail })
    if ($Status -eq 'ECHEC') { $script:Failures++ }
}

function Get-UninstallEntries {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $roots) {
        Get-ItemProperty -Path $root -ErrorAction SilentlyContinue
    }
}

function Test-Installed {
    param([string[]]$NamePattern,[string[]]$Paths = @())
    foreach ($pattern in $NamePattern) {
        $match = Get-UninstallEntries | Where-Object {
            $_.DisplayName -and $_.DisplayName -like $pattern
        } | Select-Object -First 1
        if ($match) { return $true }
    }
    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $true }
    }
    return $false
}

function Wait-ForInstalled {
    param([string[]]$NamePattern,[string[]]$Paths = @(),[int]$TimeoutMinutes = 10)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        if (Test-Installed -NamePattern $NamePattern -Paths $Paths) { return $true }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-RemoteFile {
    param([string]$Url,[string]$OutFile,[long]$MinimumBytes = 100KB,[int]$Retries = 3)
    for ($attempt=1; $attempt -le $Retries; $attempt++) {
        try {
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
            Write-Host "Telechargement : $Url"
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -MaximumRedirection 10 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            if (-not (Test-Path -LiteralPath $OutFile)) { throw 'Fichier telecharge introuvable.' }
            $file = Get-Item -LiteralPath $OutFile
            if ($file.Length -lt $MinimumBytes) { throw "Fichier trop petit ($($file.Length) octets) : reponse possiblement HTML ou incomplete." }
            return $OutFile
        }
        catch {
            if ($attempt -ge $Retries) {
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
                throw
            }
            Write-Warning "Echec telechargement $attempt/$Retries : $($_.Exception.Message)"
            Start-Sleep -Seconds (3 * $attempt)
        }
    }
}

function Assert-Authenticode {
    param([string]$Path,[string]$ExpectedPublisher)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') { throw "Signature absente ou invalide pour $Path (etat : $($sig.Status))." }
    $subject = [string]$sig.SignerCertificate.Subject
    if ($subject -notmatch $ExpectedPublisher) { throw "Editeur inattendu : $subject ; attendu : $ExpectedPublisher." }
    Write-Host "Signature valide : $subject" -ForegroundColor Green
}

function Invoke-MsiInstall {
    param([string]$Name,[string]$Url,[string]$FileName,[string]$PublisherPattern,[string[]]$DetectNames,[string[]]$DetectPaths)
    # Le MSI Enterprise courant est relance meme si le logiciel existe deja :
    # cela permet d'appliquer la version courante disponible chez l'editeur.
    $msi = Join-Path $WorkDir $FileName
    Get-RemoteFile -Url $Url -OutFile $msi -MinimumBytes 500KB | Out-Null
    Assert-Authenticode -Path $msi -ExpectedPublisher $PublisherPattern
    $log = Join-Path $LogDir "$Name-msi.log"
    $args = "/i `"$msi`" /qn /norestart /L*v `"$log`""
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru
    if ($proc.ExitCode -in @(3010,1641)) { $script:RebootNeeded = $true }
    elseif ($proc.ExitCode -ne 0) { throw "msiexec a retourne $($proc.ExitCode). Journal : $log" }
    if (-not (Wait-ForInstalled -NamePattern $DetectNames -Paths $DetectPaths -TimeoutMinutes 5)) {
        throw "$Name n'est pas detecte apres l'installation. Journal : $log"
    }
    return "$Name installe ; journal : $log"
}

function Get-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    throw 'Winget introuvable pour le compte qui execute le script. Installer/mettre a jour App Installer, puis relancer avec le meme compte administrateur.'
}

function Invoke-Winget {
    param([string[]]$Arguments,[string]$LogName)
    $winget = Get-WingetPath
    $log = Join-Path $LogDir $LogName
    Write-Host "Commande : winget $($Arguments -join ' ')"
    & $winget @Arguments *> $log
    $code = $LASTEXITCODE
    # WinGet renvoie 0x8A15002B lorsqu'aucune mise a niveau applicable n'existe.
    # Ce cas n'est pas fatal pour une commande upgrade ; le journal reste disponible.
    if (($code -eq -1978335189 -or $code -eq 0x8A15002B) -and $LogName -like '*upgrade*') {
        Write-Warning 'Aucune mise a niveau WinGet applicable (logiciel possiblement deja a jour ou installation non gerable par WinGet).'
        return $log
    }
    if ($code -ne 0) { throw "Winget a retourne le code $code. Journal : $log" }
    return $log
}

function New-CommonShortcut {
    param([string]$Path,[string]$Target,[string]$Description)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
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
    param([string]$Key,[string]$Label,[scriptblock]$Action)
    if ($Only -and ($Only -notcontains $Key)) {
        Add-Result -Name $Label -Status 'NON SELECTIONNE' -Detail 'Exclu par -Only'
        return
    }
    if ($Skip -and ($Skip -contains $Key)) {
        Add-Result -Name $Label -Status 'IGNORE' -Detail 'Exclu par -Skip'
        return
    }
    Write-Host "`n========== $Label ==========" -ForegroundColor Cyan
    try {
        $detail = & $Action | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$detail)) { $detail = 'Action terminee ; consulter les journaux.' }
        Add-Result -Name $Label -Status 'OK' -Detail ([string]$detail)
        Write-Host "OK : $detail" -ForegroundColor Green
    }
    catch {
        Add-Result -Name $Label -Status 'ECHEC' -Detail $_.Exception.Message
        Write-Host "ECHEC : $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Validation des parametres avant toute modification du poste.
$validKeys = @('chrome','firefox','acrobat','office','teams','forticlient','teamviewer')
if ($Only) { $Only = @($Only | ForEach-Object { $_.Trim().ToLowerInvariant() }) }
if ($Skip) { $Skip = @($Skip | ForEach-Object { $_.Trim().ToLowerInvariant() }) }
if ($FirefoxLang -notmatch '^[a-z]{2}(-[A-Z]{2})?$') { throw "FirefoxLang invalide : $FirefoxLang" }
if ($OfficeLanguage -notmatch '^[a-z]{2}-[a-z]{2}$') { throw "OfficeLanguage invalide : $OfficeLanguage (exemple : fr-fr)." }
foreach ($value in (@($Only) + @($Skip))) {
    if ($value -and ($validKeys -notcontains $value)) { throw "Option inconnue : $value. Valeurs : $($validKeys -join ', ')" }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) { throw 'Lancer Windows PowerShell 5.1 en 64 bits.' }
if (-not $isAdmin) { throw 'Ce script doit etre lance en administrateur.' }
$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ([version]$os.Version -lt [version]'10.0.19041') { throw "Version Windows trop ancienne : $($os.Version). Windows 10 2004 / build 19041 minimum est requis par ce script." }

try {
    New-Item -ItemType Directory -Path $LogDir,$WorkDir -Force | Out-Null
    Start-Transcript -Path $TranscriptPath -ErrorAction Stop | Out-Null
    $TranscriptStarted = $true
    Write-Host 'DEPLOIEMENT MACHINE NETPLUS - execution sequentielle' -ForegroundColor Cyan
    Write-Host "Journaux : $LogDir"

    Invoke-Step 'chrome' 'Google Chrome 64 bits' {
        $paths = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
        $detail = Invoke-MsiInstall -Name 'Chrome' -Url $Urls.Chrome -FileName 'chrome-enterprise-x64.msi' -PublisherPattern 'Google LLC' -DetectNames @('Google Chrome*') -DetectPaths $paths
        $policy = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
        New-Item -Path $policy -Force | Out-Null
        New-ItemProperty -Path $policy -Name 'ApplicationLocaleValue' -Value 'fr' -PropertyType String -Force | Out-Null
        return "$detail ; politique de langue fr appliquee (verifier chrome://policy)."
    }

    Invoke-Step 'firefox' 'Mozilla Firefox francais 64 bits' {
        $paths = @("$env:ProgramFiles\Mozilla Firefox\firefox.exe", "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe")
        Invoke-MsiInstall -Name 'Firefox' -Url $Urls.Firefox -FileName 'firefox-x64-fr.msi' -PublisherPattern 'Mozilla Corporation' -DetectNames @('Mozilla Firefox*') -DetectPaths $paths
    }

    Invoke-Step 'acrobat' 'Adobe Acrobat Reader 64 bits' {
        # Le manifeste WinGet Adobe utilise le package Reader 64 bits et une portee machine.
        # Le code produit Reader est plus precis qu'une recherche generique "Adobe Acrobat*".
        $readerProductCode = '{AC76BA86-1033-FF00-7760-BC15014EA700}'
        $readerKeyPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$readerProductCode",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$readerProductCode"
        )
        $readerInstalled = $false
        foreach ($key in $readerKeyPaths) { if (Test-Path $key) { $readerInstalled = $true } }
        if ($readerInstalled) {
            $args = @('upgrade','--id','Adobe.Acrobat.Reader.64-bit','--exact','--scope','machine','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity','--include-unknown')
            if ($Force) { $args += '--force' }
            $logName = 'Acrobat-winget-upgrade.log'
            $action = 'mise a jour (ou deja a jour)'
        }
        else {
            $args = @('install','--id','Adobe.Acrobat.Reader.64-bit','--exact','--scope','machine','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
            if ($Force) { $args += '--force' }
            $logName = 'Acrobat-winget-install.log'
            $action = 'installation/actualisation'
        }
        $log = Invoke-Winget -Arguments $args -LogName $logName
        $deadline = (Get-Date).AddMinutes(10)
        $readerDetected = $false
        do {
            foreach ($key in $readerKeyPaths) { if (Test-Path -LiteralPath $key) { $readerDetected = $true } }
            if ($readerDetected) { break }
            Start-Sleep -Seconds 5
        } while ((Get-Date) -lt $deadline)
        if (-not $readerDetected) { throw "Reader non detecte apres WinGet. Verifier le code produit $readerProductCode et le journal $log." }
        "Adobe Acrobat Reader : $action via WinGet ; journal : $log. La langue d'interface depend du package MUI et de la configuration Adobe."
    }

    Invoke-Step 'office' 'Microsoft 365 Apps 64 bits francais' {
        $officeKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
        # ODT est relance pour maintenir le produit sur le canal Current et appliquer
        # les mises a jour disponibles, y compris si Microsoft 365 est deja installe.
        $odt = Join-Path $WorkDir 'officedeploymenttool.exe'
        $odtDir = Join-Path $WorkDir 'odt'
        Get-RemoteFile -Url $Urls.OfficeODT -OutFile $odt -MinimumBytes 1MB | Out-Null
        Assert-Authenticode -Path $odt -ExpectedPublisher 'Microsoft Corporation'
        New-Item -ItemType Directory -Path $odtDir -Force | Out-Null
        $extract = Start-Process -FilePath $odt -ArgumentList "/quiet /extract:`"$odtDir`"" -Wait -PassThru
        if ($extract.ExitCode -ne 0) { throw "Extraction ODT impossible : $($extract.ExitCode)" }
        $setup = Join-Path $odtDir 'setup.exe'
        if (-not (Test-Path $setup)) { throw 'setup.exe introuvable apres extraction ODT.' }
        $config = Join-Path $odtDir 'configuration.xml'
        $odtLogDir = Join-Path $LogDir 'Office-ODT'
        New-Item -ItemType Directory -Path $odtLogDir -Force | Out-Null
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
        $proc = Start-Process -FilePath $setup -ArgumentList "/configure `"$config`"" -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "ODT a retourne $($proc.ExitCode). Journaux : $odtLogDir" }
        $deadline = (Get-Date).AddMinutes(45)
        do {
            $ctr = Get-ItemProperty -Path $officeKey -ErrorAction SilentlyContinue
            if ($ctr -and (([string]$ctr.ProductReleaseIds -split ',') -contains $OfficeProductId)) { return "Microsoft 365 installe ; produit $OfficeProductId, 64 bits, $OfficeLanguage, canal Current." }
            Start-Sleep -Seconds 10
        } while ((Get-Date) -lt $deadline)
        throw 'Microsoft 365 non detecte apres ODT. Consulter les journaux Office-ODT.'
    }

    Invoke-Step 'teams' 'Nouveau Microsoft Teams machine-wide' {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*MSTeams*' -or $_.PackageName -like '*MSTeams*' })
        # Le bootstrapper officiel est relance pour verifier/appliquer la version courante.
        $bootstrapper = Join-Path $WorkDir 'teamsbootstrapper.exe'
        Get-RemoteFile -Url $Urls.Teams -OutFile $bootstrapper -MinimumBytes 500KB | Out-Null
        Assert-Authenticode -Path $bootstrapper -ExpectedPublisher 'Microsoft Corporation'
        $output = @(& $bootstrapper -p 2>&1)
        $code = $LASTEXITCODE
        $outputText = ($output | Out-String).Trim()
        if ($outputText) { Write-Host $outputText }
        if ($code -ne 0) { throw "Teams Bootstrapper a retourne $code." }
        $deadline = (Get-Date).AddMinutes(15)
        do {
            $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*MSTeams*' -or $_.PackageName -like '*MSTeams*' })
            if ($provisioned.Count -gt 0) { return 'Nouveau Teams provisionne au niveau machine pour les utilisateurs actuels et futurs.' }
            Start-Sleep -Seconds 5
        } while ((Get-Date) -lt $deadline)
        throw 'Le Bootstrapper a termine mais Teams ne figure pas dans les packages provisionnes.'
    }

    Invoke-Step 'forticlient' 'FortiClient VPN' {
        $paths = @('C:\Program Files\Fortinet\FortiClient\FortiClient.exe','C:\Program Files\Fortinet\FortiClient\FortiClientConsole.exe')
        $names = @('FortiClient VPN*','Fortinet FortiClient VPN*','FortiClient*')

        # Le lien public Fortinet fournit le downloader en ligne, pas le paquet complet.
        # Le downloader extrait FortiClientVPN.exe dans le Temp de l'utilisateur.
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA est indisponible : impossible de localiser le paquet FortiClient extrait.'
        }
        $downloader = Join-Path $WorkDir 'FortiClientVPNOnlineInstaller.exe'
        $payload = Join-Path $env:LOCALAPPDATA 'Temp\FortiClientVPN.exe'
        $log = Join-Path $LogDir 'FortiClientVPN-install.log'

        # Evite de supprimer un paquet qui serait deja utilise par une autre installation.
        $existingPayloadProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $payload) })
        if ($existingPayloadProcesses.Count -gt 0) {
            throw 'FortiClientVPN.exe est deja en cours d execution. Fermer cette installation avant de relancer le script.'
        }
        if (Test-Path -LiteralPath $payload) {
            Remove-Item -LiteralPath $payload -Force -ErrorAction Stop
        }

        Get-RemoteFile -Url $Urls.Forti -OutFile $downloader -MinimumBytes 500KB | Out-Null
        Assert-Authenticode -Path $downloader -ExpectedPublisher 'Fortinet'

        Write-Host 'Lancement du downloader Fortinet pour recuperer le paquet complet...' -ForegroundColor Cyan
        $downloaderProcess = Start-Process -FilePath $downloader -WindowStyle Hidden -PassThru
        $deadline = (Get-Date).AddMinutes(15)
        $lastLength = -1L
        $stableCount = 0
        $payloadReady = $false

        # Attend la fin de l'extraction : taille superieure a 50 Mo et stable
        # pendant plusieurs controles successifs.
        do {
            if (Test-Path -LiteralPath $payload) {
                $payloadInfo = Get-Item -LiteralPath $payload -ErrorAction SilentlyContinue
                if ($payloadInfo -and $payloadInfo.Length -ge 50MB) {
                    if ($payloadInfo.Length -eq $lastLength) { $stableCount++ }
                    else { $stableCount = 0; $lastLength = $payloadInfo.Length }
                    if ($stableCount -ge 3) { $payloadReady = $true; break }
                }
            }
            Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $deadline)

        if (-not $payloadReady) {
            if ($downloaderProcess -and -not $downloaderProcess.HasExited) {
                Stop-Process -Id $downloaderProcess.Id -Force -ErrorAction SilentlyContinue
            }
            throw 'Le downloader Fortinet n a pas extrait FortiClientVPN.exe dans le delai de 15 minutes. Aucune installation interactive ne sera lancee.'
        }

        # Le downloader peut avoir demarre son propre assistant apres extraction.
        # On arrete uniquement les processus issus de ce nouveau paquet, puis on
        # relance le meme executable avec les options silencieuses confirmees par son aide.
        $processSnapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $newPayloadProcesses = @($processSnapshot | Where-Object {
            $_.ExecutablePath -and ($_.ExecutablePath -ieq $payload)
        })
        $rootProcessIds = @([int]$downloaderProcess.Id) + @($newPayloadProcesses | ForEach-Object { [int]$_.ProcessId })
        $descendantIds = @()
        $frontierIds = @($rootProcessIds)
        while ($frontierIds.Count -gt 0) {
            $nextIds = @($processSnapshot | Where-Object {
                $frontierIds -contains [int]$_.ParentProcessId
            } | ForEach-Object { [int]$_.ProcessId })
            foreach ($processId in $nextIds) {
                if ($descendantIds -notcontains $processId) { $descendantIds += $processId }
            }
            $frontierIds = @($nextIds)
        }
        foreach ($processId in ($descendantIds | Select-Object -Unique)) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
        foreach ($processId in ($rootProcessIds | Select-Object -Unique)) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2

        if (-not (Test-Path -LiteralPath $payload)) { throw 'Le paquet FortiClient a disparu apres l arret du downloader.' }
        Assert-Authenticode -Path $payload -ExpectedPublisher 'Fortinet'

        Write-Host 'Installation silencieuse du paquet FortiClient VPN...' -ForegroundColor Cyan
        $proc = Start-Process -FilePath $payload -ArgumentList "-quiet -norestart -log `"$log`"" -Wait -PassThru
        Add-Content -Path $log -Value "`r`nCode de sortie : $($proc.ExitCode)" -Encoding UTF8
        if ($proc.ExitCode -in @(3010,1641)) { $script:RebootNeeded = $true }
        elseif ($proc.ExitCode -ne 0) { throw "FortiClient a retourne $($proc.ExitCode). Journal : $log" }
        if (-not (Wait-ForInstalled -NamePattern $names -Paths $paths -TimeoutMinutes 15)) { throw "FortiClient non detecte apres installation. Journal : $log" }
        "FortiClient VPN detecte apres installation silencieuse ; journal : $log."
    }

    Invoke-Step 'teamviewer' 'TeamViewer QuickSupport' {
        $directory = 'C:\teamviewer'
        $exe = Join-Path $directory 'TeamViewerQS.exe'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $download = Join-Path $WorkDir 'TeamViewerQS.exe'
        Get-RemoteFile -Url $Urls.TeamViewer -OutFile $download -MinimumBytes 500KB | Out-Null
        Assert-Authenticode -Path $download -ExpectedPublisher 'TeamViewer'
        # Remplacement atomique autant que possible : on conserve l'ancien fichier si le telechargement echoue.
        Copy-Item -LiteralPath $download -Destination $exe -Force
        $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
        $commonPrograms = [Environment]::GetFolderPath('CommonPrograms')
        if ([string]::IsNullOrWhiteSpace($publicDesktop)) { $publicDesktop = 'C:\Users\Public\Desktop' }
        if ([string]::IsNullOrWhiteSpace($commonPrograms)) { $commonPrograms = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs' }
        New-CommonShortcut -Path (Join-Path $publicDesktop 'TeamViewer QuickSupport.lnk') -Target $exe -Description 'TeamViewer QuickSupport'
        New-CommonShortcut -Path (Join-Path $commonPrograms 'TeamViewer QuickSupport.lnk') -Target $exe -Description 'TeamViewer QuickSupport'
        'TeamViewer QuickSupport copie dans C:\teamviewer ; raccourcis crees sur le bureau public et dans le menu Demarrer commun.'
    }

    Write-Host "`n================ BILAN FINAL ================" -ForegroundColor Cyan
    $Results | Format-Table -AutoSize -Wrap | Out-Host
    if ($script:RebootNeeded) { Write-Host 'Un redemarrage est necessaire ou recommande.' -ForegroundColor Yellow }
    Write-Host "Journaux : $LogDir"
}
catch {
    Write-Host "ERREUR GENERALE : $($_.Exception.Message)" -ForegroundColor Red
    Add-Result -Name 'Script' -Status 'ECHEC' -Detail $_.Exception.Message
}
finally {
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:Failures -gt 0) {
    if (-not $NoPause) { Read-Host 'Termine avec des erreurs. Appuyez sur Entree' | Out-Null }
    exit 1
}
if (-not $NoPause) { Read-Host 'Termine. Appuyez sur Entree' | Out-Null }
exit 0
