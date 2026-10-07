<#
.SYNOPSIS
    Update 7-Zip geforceerd naar de nieuwste versie. Geschikt voor NinjaOne (SYSTEM, non-interactive).

.DESCRIPTION
    - Doet niets (exit 0) als 7-Zip niet op het apparaat staat; er wordt dan ook niets gedownload
    - Bepaalt de nieuwste versie via GitHub (ip7z/7zip) met 7-zip.org als fallback; hoogste versie wint
    - Installeert nooit een oudere versie dan de huidige
    - Installeert dezelfde architectuur als de bestaande installatie (x86 / x64 / arm64)
    - Herinstalleert ook als de nieuwste versie al aanwezig is (geforceerd)
    - Bij een mislukte installatie wordt diagnose-informatie getoond (exitcode, vergrendelde bestanden)
    - Met -UninstallFirst wordt bij een mislukte installatie 7-Zip eerst verwijderd en daarna opnieuw geinstalleerd

    Exitcode 0 = gelukt of niet van toepassing, 1 = mislukt

.PARAMETER UninstallFirst
    Laatste redmiddel: als de gewone (over-)installatie faalt, eerst 7-Zip stil verwijderen en dan opnieuw installeren.
#>

param(
    [switch]$UninstallFirst
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-PEArchitecture([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Seek(0x3C, 'Begin') | Out-Null
        $peOffset = $br.ReadInt32()
        $fs.Seek($peOffset + 4, 'Begin') | Out-Null
        switch ($br.ReadUInt16()) {
            0x8664  { 'x64' }
            0xAA64  { 'arm64' }
            default { 'x86' }
        }
    } finally { $fs.Close() }
}

function Get-7ZipInstalls {
    foreach ($view in 'Registry64', 'Registry32') {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
        $key  = $base.OpenSubKey('SOFTWARE\7-Zip')
        if ($key) {
            $dir = $key.GetValue('Path')
            if (-not $dir) { $dir = $key.GetValue('Path64') }
            $exe = if ($dir) { Join-Path $dir '7z.exe' }
            if ($exe -and (Test-Path $exe)) {
                [pscustomobject]@{
                    Dir     = $dir.TrimEnd('\')
                    Exe     = $exe
                    Version = (Get-Item $exe).VersionInfo.ProductVersion
                    Arch    = Get-PEArchitecture $exe
                }
            }
            $key.Close()
        }
        $base.Close()
    }
}

function ConvertTo-7ZipVersion([string]$Digits) {
    [version]('{0}.{1}' -f $Digits.Substring(0, $Digits.Length - 2), $Digits.Substring($Digits.Length - 2))
}

function Get-LatestInstaller([string]$Arch) {
    $namePattern = if ($Arch -eq 'x86') { '^7z(\d{3,4})\.exe$' } else { "^7z(\d{3,4})-$Arch\.exe$" }
    $candidates  = @()

    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/ip7z/7zip/releases/latest' `
               -Headers @{ 'User-Agent' = 'Update-7Zip' } -TimeoutSec 60
        foreach ($a in $rel.assets) {
            $m = [regex]::Match($a.name, $namePattern)
            if ($m.Success) {
                $candidates += [pscustomobject]@{ Version = ConvertTo-7ZipVersion $m.Groups[1].Value; Url = $a.browser_download_url }
            }
        }
    } catch { Write-Output "Let op: GitHub-bron niet beschikbaar ($($_.Exception.Message))" }

    try {
        $page = Invoke-WebRequest -Uri 'https://www.7-zip.org/download.html' -UseBasicParsing -TimeoutSec 60
        foreach ($m in [regex]::Matches($page.Content, '(?:^|[/"''])(7z(\d{3,4})(?:-[a-z0-9]+)?\.exe)')) {
            $file = $m.Groups[1].Value
            $n    = [regex]::Match($file, $namePattern)
            if ($n.Success) {
                $candidates += [pscustomobject]@{ Version = ConvertTo-7ZipVersion $n.Groups[1].Value; Url = "https://www.7-zip.org/a/$file" }
            }
        }
    } catch { Write-Output "Let op: 7-zip.org niet beschikbaar ($($_.Exception.Message))" }

    $candidates | Sort-Object Version -Descending | Select-Object -First 1
}

function Stop-7ZipProcesses([string]$Dir) {
    Get-Process -Name '7zFM', '7zG', '7z' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$Dir\*" } | Stop-Process -Force
    Start-Sleep -Seconds 1
}

function Write-LockDiagnostics([string]$Dir) {
    # Welke processen hebben bestanden uit de 7-Zip-map geladen (bv. explorer.exe met de shell-extensie)?
    $holders = foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        try {
            $hit = $p.Modules | Where-Object { $_.FileName -like "$Dir\*" } | Select-Object -First 1
            if ($hit) { "$($p.ProcessName) (PID $($p.Id)) -> $(Split-Path $hit.FileName -Leaf)" }
        } catch { }
    }
    if ($holders) { Write-Output "Processen die 7-Zip-bestanden in gebruik hebben:"; $holders | ForEach-Object { Write-Output "  $_" } }
    else          { Write-Output "Geen processen gevonden die 7-Zip-bestanden in gebruik hebben." }
}

function Invoke-7ZipInstaller([string]$Installer) {
    # Bewust GEEN /D=: de installer pakt de bestaande installatiemap automatisch uit de registry
    $p = Start-Process -FilePath $Installer -ArgumentList '/S' -Wait -PassThru
    return $p.ExitCode
}

try {
    $installs = @(Get-7ZipInstalls | Sort-Object Dir -Unique)
    if ($installs.Count -eq 0) {
        Write-Output "7-Zip is niet geinstalleerd op dit apparaat. Geen actie nodig."
        exit 0
    }

    foreach ($inst in $installs) {
        Write-Output "Gevonden: 7-Zip $($inst.Version) ($($inst.Arch)) in $($inst.Dir)"

        $latest = Get-LatestInstaller $inst.Arch
        if (-not $latest) { throw "Kon geen installer vinden voor architectuur $($inst.Arch)." }

        $current = $null
        try { $current = [version]$inst.Version } catch { }
        if ($current -and $latest.Version -lt $current) {
            Write-Output "Nieuwste gevonden versie ($($latest.Version)) is ouder dan de geinstalleerde ($current). Overgeslagen."
            continue
        }

        Write-Output "Nieuwste versie: $($latest.Version) -> $($latest.Url)"
        $installer = Join-Path $env:TEMP (Split-Path $latest.Url -Leaf)

        Stop-7ZipProcesses $inst.Dir
        Invoke-WebRequest -Uri $latest.Url -OutFile $installer -UseBasicParsing -TimeoutSec 300
        Write-Output "Gedownload: $installer ($([math]::Round((Get-Item $installer).Length / 1KB)) KB)"

        try {
            Write-Output "Installeren (stil)..."
            $code = Invoke-7ZipInstaller $installer

            if ($code -ne 0) {
                Write-Output "Installer gaf exitcode $code."
                Write-LockDiagnostics $inst.Dir

                if (-not $UninstallFirst) {
                    throw "Installatie van $($latest.Version) mislukt met exitcode $code. Draai het script eventueel met -UninstallFirst."
                }

                # Laatste redmiddel: eerst verwijderen, dan opnieuw installeren
                $uninstaller = Join-Path $inst.Dir 'Uninstall.exe'
                if (-not (Test-Path $uninstaller)) { throw "Uninstall.exe niet gevonden in $($inst.Dir)." }
                Write-Output "Poging 2: 7-Zip eerst verwijderen..."
                Stop-7ZipProcesses $inst.Dir
                # _?= zorgt dat de uninstaller blijft wachten tot hij klaar is
                $u = Start-Process -FilePath $uninstaller -ArgumentList "/S _?=$($inst.Dir)" -Wait -PassThru
                Write-Output "Uninstaller exitcode: $($u.ExitCode)"
                Remove-Item $uninstaller -Force -ErrorAction SilentlyContinue
                if ((Test-Path $inst.Dir) -and -not (Get-ChildItem $inst.Dir -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item $inst.Dir -Force -ErrorAction SilentlyContinue
                }

                Write-Output "Opnieuw installeren..."
                $code = Invoke-7ZipInstaller $installer
                if ($code -ne 0) { throw "Installatie na verwijderen mislukt met exitcode $code. 7-Zip kan nu ONTBREKEN op dit apparaat." }
            }
        }
        finally {
            Remove-Item $installer -Force -ErrorAction SilentlyContinue
        }

        $newVersion = (Get-Item $inst.Exe).VersionInfo.ProductVersion
        Write-Output "Klaar: $($inst.Version) -> $newVersion ($($inst.Arch))"
    }
    exit 0
}
catch {
    Write-Output "FOUT: $($_.Exception.Message)"
    exit 1
}
