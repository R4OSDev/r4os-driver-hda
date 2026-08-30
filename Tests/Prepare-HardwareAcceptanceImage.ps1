[CmdletBinding()]
param(
    [string]$OutputDirectory,

    [switch]$IsolationNoHda,

    [switch]$IsolationNoUpdSvc
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$buildScript = Join-Path $workspaceRoot 'Tools/Build.ps1'
$artifactsRoot = Join-Path $workspaceRoot 'Artifacts/Distribution'
$privateOverlay = Join-Path $artifactsRoot 'PrivateInjection'
$baseProfile = 'Full'
$profileRoot = Join-Path $artifactsRoot ('Profiles/' + $baseProfile)
$tempRoot = Join-Path $workspaceRoot 'Temp'
$lockPath = Join-Path $tempRoot 'HDA-0.71.10-image.lock'
$baseConfigPath = Join-Path $workspaceRoot 'Repositories/Distribution/Injection/CONFIG.R4S'
$baseServicesPath = Join-Path $workspaceRoot 'Repositories/Distribution/Injection/R4OS/CONFIG/SERVICES.R4S'
$versionPath = Join-Path $workspaceRoot 'Repositories/Distribution/Injection/R4OS/CONFIG/VERSION.R4S'
$observationTemplate = Join-Path $PSScriptRoot 'HARDWARE-OBSERVATIONS.txt'
$hdaRepository = Join-Path $workspaceRoot 'Repositories/Drivers/HDA'
$hdaManifest = Join-Path $hdaRepository 'module.R4MF'
$hdaArtifact = Join-Path $workspaceRoot 'Artifacts/Modules/HDA/HDA.R4D'
$kernelRepository = Join-Path $workspaceRoot 'Repositories/Kernel'
$kernelArtifact = Join-Path $kernelRepository 'zig-out/bin/r4os.elf'
$sshRepository = Join-Path $workspaceRoot 'Repositories/Services/SshService'
$sshManifest = Join-Path $sshRepository 'module.R4MF'
$sshArtifact = Join-Path $workspaceRoot 'Artifacts/Modules/SshService/SSHD.R4X'
$audioDiagRepository = Join-Path $workspaceRoot 'Repositories/Diagnostics/AudioDiag'
$audioDiagManifest = Join-Path $audioDiagRepository 'module.R4MF'
$audioDiagArtifact = Join-Path $workspaceRoot 'Artifacts/Modules/AudioDiag/AUDIOD.R4X'
$hardwareDiagRepository = Join-Path $workspaceRoot 'Repositories/Diagnostics/HardwareDiag'
$hardwareDiagManifest = Join-Path $hardwareDiagRepository 'module.R4MF'
$hardwareDiagArtifact = Join-Path $workspaceRoot 'Artifacts/Modules/HardwareDiag/HWDIAG.R4X'
$pwshPath = (Get-Process -Id $PID).Path

if ($IsolationNoHda -and $IsolationNoUpdSvc) {
    throw 'IsolationNoHda und IsolationNoUpdSvc duerfen nicht kombiniert werden.'
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = if ($IsolationNoHda) {
        Join-Path $artifactsRoot 'Hardware/HDA-0.71.10/Isolation-NoHda'
    } elseif ($IsolationNoUpdSvc) {
        Join-Path $artifactsRoot 'Hardware/HDA-0.71.10/Isolation-NoUpdSvc'
    } else {
        Join-Path $artifactsRoot 'Hardware/HDA-0.71.10'
    }
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

foreach ($required in @($buildScript, $baseConfigPath, $baseServicesPath, $versionPath, $observationTemplate, $hdaManifest, $sshManifest, $audioDiagManifest, $hardwareDiagManifest)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw ('Erforderliche Datei fehlt: ' + $required)
    }
}

function Invoke-WorkspaceBuild([string[]]$BuildArguments) {
    & $pwshPath -NoLogo -NoProfile -File $buildScript @BuildArguments
    if ($LASTEXITCODE -ne 0) {
        throw ('Workspace-Build fehlgeschlagen: ' + ($BuildArguments -join ' '))
    }
}

function Get-RepositoryHead([string]$Path) {
    $head = (& git -C $Path rev-parse HEAD 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) {
        throw ('Git-HEAD konnte nicht gelesen werden: ' + $Path)
    }
    return $head.Trim()
}

function Get-RepositoryDirty([string]$Path) {
    $changes = @(& git -C $Path status --porcelain --untracked-files=normal 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw ('Git-Status konnte nicht gelesen werden: ' + $Path)
    }
    return $(if ($changes.Count -eq 0) { 'false' } else { 'true' })
}

function Get-ModuleVersion([string]$Path) {
    $versionLines = @(Get-Content -LiteralPath $Path | Where-Object { $_ -match '^VERSION=' })
    if ($versionLines.Count -ne 1) { throw ('VERSION ist nicht eindeutig: ' + $Path) }
    return ($versionLines[0] -split '=', 2)[1].Trim()
}

function Remove-EmptyDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -eq 0) {
        Remove-Item -LiteralPath $Path -Force
    }
}

$autoexecLines = @(
    '@ECHO OFF',
    'SET TEMP=C:\TEMP',
    'SET BLASTER=A220 I5 D1',
    'PROMPT $P$G',
    'PATH /P C:\R4OS\SOFTWARE\TERMINAL;C:\R4OS\SOFTWARE\TERMINAL\DIAG',
    'ECHO [HDA07110] Interaktives Hardware-Abnahmeimage',
    'VER',
    'C:\R4OS\SOFTWARE\TERMINAL\SERVMAN.R4X BOOT',
    'SLEEP 2000',
    'SERVMAN STATUS AUDSVC',
    'SERVMAN STATUS SSHD',
    'IPCONFIG /ALL',
    'HWDIAG /EXPORT',
    'COPY C:\HWDIAG.TXT C:\TEMP\HDA-BOOT-HWDIAG.TXT',
    'C:\R4OS\SOFTWARE\DESKTOP\LOGCENTER.R4X /EXPORT /CONSOLE /SOURCE=BOOTLOG /MIN=DEBUG /OUT=C:\TEMP\HDA-BOOT-BOOTLOG.TXT',
    'ECHO [HDA07110] Snapshot erstellt. Physische Hoerabnahme noch NICHT bestanden.',
    'ECHO [HDA07110] Host-Anleitung: Docs\Drivers\HdaHardwareAcceptance07110.txt'
)
if ($IsolationNoHda) {
    $autoexecLines[5] = 'ECHO [HDA07110-NOHDA] Boot-Isolation ohne HDA-Treiber'
    $autoexecLines[15] = 'ECHO [HDA07110-NOHDA] Desktop erreicht. HDA-Ursache noch NICHT behoben.'
} elseif ($IsolationNoUpdSvc) {
    $autoexecLines[5] = 'ECHO [BOOT07111-NOUPD] Boot-Isolation mit manuellem UPDSVC'
    $autoexecLines[15] = 'ECHO [BOOT07111-NOUPD] Desktop erreicht. UPDSVC noch NICHT gestartet.'
}
$basicLines = @(
    'CLS',
    'PRINT "HDA 0.71.10 R4BASIC BEEP"',
    'BEEP',
    'PRINT "HDA 0.71.10 R4BASIC PLAY"',
    'PLAY "MFT160O4L8CDEFGAB>C"',
    'PRINT "BEEP/PLAY beendet - Taste druecken"',
    'SLEEP',
    'END'
)
$coldBatchLines = @(
    '@ECHO OFF',
    'ECHO [HDA07110] Kaltstart-Diagnose beginnt',
    'VER',
    'SYSINFO',
    'IPCONFIG /ALL',
    'HWDIAG /EXPORT',
    'SET',
    'COPY C:\HWDIAG.TXT C:\TEMP\HDA-COLD-HWDIAG.TXT',
    'SET',
    'C:\R4OS\SOFTWARE\DESKTOP\LOGCENTER.R4X /EXPORT /CONSOLE /SOURCE=BOOTLOG /MIN=DEBUG /OUT=C:\TEMP\HDA-COLD-BOOTLOG.TXT',
    'SET',
    'ECHO [HDA07110] Kaltstart-Diagnose abgeschlossen'
)
$longBatchLines = @(
    '@ECHO OFF',
    'ECHO [HDA07110] Langlauf 1/5',
    'AUDIOD /LONG /OUT=C:\TEMP\HDA-LONG-1-HDA.TXT',
    'SET',
    'ECHO [HDA07110] Langlauf 2/5',
    'AUDIOD /LONG /OUT=C:\TEMP\HDA-LONG-2-HDA.TXT',
    'SET',
    'ECHO [HDA07110] Langlauf 3/5',
    'AUDIOD /LONG /OUT=C:\TEMP\HDA-LONG-3-HDA.TXT',
    'SET',
    'ECHO [HDA07110] Langlauf 4/5',
    'AUDIOD /LONG /OUT=C:\TEMP\HDA-LONG-4-HDA.TXT',
    'SET',
    'ECHO [HDA07110] Langlauf 5/5',
    'AUDIOD /LONG /OUT=C:\TEMP\HDA-LONG-5-HDA.TXT',
    'SET',
    'COPY C:\TEMP\HDA-LONG-5-HDA.TXT C:\TEMP\HDA-COLD-FINAL-HDA.TXT',
    'SET',
    'HWDIAG /EXPORT',
    'SET',
    'COPY C:\HWDIAG.TXT C:\TEMP\HDA-COLD-FINAL-HWDIAG.TXT',
    'SET',
    'C:\R4OS\SOFTWARE\DESKTOP\LOGCENTER.R4X /EXPORT /CONSOLE /SOURCE=ALL /MIN=DEBUG /OUT=C:\TEMP\HDA-COLD-FINAL-LOGS.TXT',
    'SET',
    'ECHO [HDA07110] Langlauf beendet; alle fuenf Ergebnisse pruefen'
)
$warmBatchLines = @(
    '@ECHO OFF',
    'ECHO [HDA07110] Warmstart-Diagnose beginnt',
    'HWDIAG /EXPORT',
    'SET',
    'COPY C:\HWDIAG.TXT C:\TEMP\HDA-WARM-HWDIAG.TXT',
    'SET',
    'C:\R4OS\SOFTWARE\DESKTOP\LOGCENTER.R4X /EXPORT /CONSOLE /SOURCE=BOOTLOG /MIN=DEBUG /OUT=C:\TEMP\HDA-WARM-BOOTLOG.TXT',
    'SET',
    'C:\R4OS\SOFTWARE\DESKTOP\LOGCENTER.R4X /EXPORT /CONSOLE /SOURCE=ALL /MIN=DEBUG /OUT=C:\TEMP\HDA-WARM-LOGS.TXT',
    'SET',
    'ECHO [HDA07110] Warmstart-Diagnose abgeschlossen'
)

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$lockStream = $null
$primaryError = $null
$restoreRequired = $false
$overlayConfig = Join-Path $privateOverlay 'CONFIG.R4S'
$overlayAutoexec = Join-Path $privateOverlay 'AUTOEXEC.BAT'
$overlayTemp = Join-Path $privateOverlay 'Temp'
$overlayR4os = Join-Path $privateOverlay 'R4OS'
$overlayR4osConfig = Join-Path $overlayR4os 'CONFIG'
$overlayServices = Join-Path $overlayR4osConfig 'SERVICES.R4S'
$overlaySoftware = Join-Path $overlayR4os 'SOFTWARE'
$overlayTerminal = Join-Path $overlaySoftware 'TERMINAL'
$overlayDiag = Join-Path $overlayTerminal 'DIAG'
$overlayAudioDiag = Join-Path $overlayDiag 'AUDIOD.R4X'
$overlayHardwareDiag = Join-Path $overlayDiag 'HWDIAG.R4X'
$overlayBasic = Join-Path $overlayTemp 'HDA-AUDIO.BAS'
$overlayObservations = Join-Path $overlayTemp 'HDA-OBSERVATIONS.TXT'
$overlayColdBatch = Join-Path $overlayTemp 'HDA-COLD.BAT'
$overlayLongBatch = Join-Path $overlayTemp 'HDA-LONG.BAT'
$overlayWarmBatch = Join-Path $overlayTemp 'HDA-WARM.BAT'

try {
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)

    if (Test-Path -LiteralPath $privateOverlay -PathType Container) {
        $existing = @(Get-ChildItem -LiteralPath $privateOverlay -Force)
        if ($existing.Count -ne 0) {
            throw ('PrivateInjection ist nicht leer; Hardwareimage wird nicht ueber fremde lokale Overlays gebaut: ' + $privateOverlay)
        }
    }

    Invoke-WorkspaceBuild @('-kernel')
    if (-not (Test-Path -LiteralPath $kernelArtifact -PathType Leaf)) {
        throw ('Gebautes Kernelartefakt fehlt: ' + $kernelArtifact)
    }
    Invoke-WorkspaceBuild @('-module', 'Services/SshService')
    Invoke-WorkspaceBuild @('-module', 'Diagnostics/AudioDiag')
    Invoke-WorkspaceBuild @('-module', 'Diagnostics/HardwareDiag')
    foreach ($required in @($sshArtifact, $audioDiagArtifact, $hardwareDiagArtifact)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw ('Gebautes Hardwareimage-Artefakt fehlt: ' + $required)
        }
    }

    New-Item -ItemType Directory -Path $overlayTemp -Force | Out-Null
    New-Item -ItemType Directory -Path $overlayDiag -Force | Out-Null
    if ($IsolationNoHda) {
        $configLines = @(Get-Content -LiteralPath $baseConfigPath | Where-Object {
            $_ -notmatch '^\s*DRIVER=HDA\s*$' -and $_ -notmatch '^\s*DISABLE=HDA\s*$'
        })
        $configLines += 'DISABLE=HDA'
        [IO.File]::WriteAllText($overlayConfig, (($configLines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($true))
    }
    if ($IsolationNoUpdSvc) {
        New-Item -ItemType Directory -Path $overlayR4osConfig -Force | Out-Null
        $serviceLines = @(Get-Content -LiteralPath $baseServicesPath)
        $matched = 0
        for ($index = 0; $index -lt $serviceLines.Count; $index++) {
            if ($serviceLines[$index] -match '^SERVICE;name=UPDSVC;') {
                $serviceLines[$index] = $serviceLines[$index] -replace ';start=auto;', ';start=manual;'
                $matched++
            }
        }
        if ($matched -ne 1) { throw 'UPDSVC-Autostarteintrag ist nicht eindeutig.' }
        [IO.File]::WriteAllText($overlayServices, (($serviceLines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($true))
    }
    [IO.File]::WriteAllText($overlayAutoexec, (($autoexecLines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($overlayBasic, (($basicLines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($overlayColdBatch, (($coldBatchLines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($overlayLongBatch, (($longBatchLines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($overlayWarmBatch, (($warmBatchLines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    Copy-Item -LiteralPath $observationTemplate -Destination $overlayObservations
    Copy-Item -LiteralPath $audioDiagArtifact -Destination $overlayAudioDiag
    Copy-Item -LiteralPath $hardwareDiagArtifact -Destination $overlayHardwareDiag
    $restoreRequired = $true

    Invoke-WorkspaceBuild @('-image', $baseProfile)
    Invoke-WorkspaceBuild @('-verify', $baseProfile)

    if (-not (Test-Path -LiteralPath $hdaArtifact -PathType Leaf)) {
        throw ('Gebautes HDA-Artefakt fehlt: ' + $hdaArtifact)
    }

    $sourceImage = Join-Path $profileRoot 'disk.img'
    $sourcePlan = Join-Path $profileRoot 'image-adds.txt'
    foreach ($required in @($sourceImage, $sourcePlan)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw ('Erzeugtes Hardwareartefakt fehlt: ' + $required)
        }
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $targetImageName = if ($IsolationNoHda) {
        'R4OS-0.71.10-HDA-Isolation-NoHDA-Full-x86_64.img'
    } elseif ($IsolationNoUpdSvc) {
        'R4OS-0.71.10-Boot-Isolation-NoUPDSVC-Full-x86_64.img'
    } else {
        'R4OS-0.71.10-HDA-Hardware-Full-x86_64.img'
    }
    $targetImage = Join-Path $OutputDirectory $targetImageName
    $targetPlan = Join-Path $OutputDirectory 'image-adds.txt'
    $targetAutoexec = Join-Path $OutputDirectory 'AUTOEXEC.BAT'
    $targetBasic = Join-Path $OutputDirectory 'HDA-AUDIO.BAS'
    $targetColdBatch = Join-Path $OutputDirectory 'HDA-COLD.BAT'
    $targetLongBatch = Join-Path $OutputDirectory 'HDA-LONG.BAT'
    $targetWarmBatch = Join-Path $OutputDirectory 'HDA-WARM.BAT'
    $targetObservations = Join-Path $OutputDirectory 'HARDWARE-OBSERVATIONS.txt'
    $targetConfig = Join-Path $OutputDirectory 'CONFIG.R4S'
    Copy-Item -LiteralPath $sourceImage -Destination $targetImage -Force
    Copy-Item -LiteralPath $sourcePlan -Destination $targetPlan -Force
    Copy-Item -LiteralPath $overlayAutoexec -Destination $targetAutoexec -Force
    Copy-Item -LiteralPath $overlayBasic -Destination $targetBasic -Force
    Copy-Item -LiteralPath $overlayColdBatch -Destination $targetColdBatch -Force
    Copy-Item -LiteralPath $overlayLongBatch -Destination $targetLongBatch -Force
    Copy-Item -LiteralPath $overlayWarmBatch -Destination $targetWarmBatch -Force
    Copy-Item -LiteralPath $observationTemplate -Destination $targetObservations -Force
    if ($IsolationNoHda) { Copy-Item -LiteralPath $overlayConfig -Destination $targetConfig -Force }

    $releaseLine = @(Get-Content -LiteralPath $versionPath | Where-Object { $_ -match 'RELEASE_VERSION=' })
    if ($releaseLine.Count -ne 1) { throw 'RELEASE_VERSION ist nicht eindeutig.' }
    $releaseVersion = ($releaseLine[0] -split '=', 2)[1].Trim()
    $imageInfo = Get-Item -LiteralPath $targetImage
    $imageHash = (Get-FileHash -LiteralPath $targetImage -Algorithm SHA256).Hash.ToLowerInvariant()
    $planHash = (Get-FileHash -LiteralPath $targetPlan -Algorithm SHA256).Hash.ToLowerInvariant()
    $createdUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $hdaHead = Get-RepositoryHead $hdaRepository
    $hdaDirty = Get-RepositoryDirty $hdaRepository
    $hdaVersion = Get-ModuleVersion $hdaManifest
    $hdaHash = (Get-FileHash -LiteralPath $hdaArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $kernelHead = Get-RepositoryHead $kernelRepository
    $kernelDirty = Get-RepositoryDirty $kernelRepository
    $kernelHash = (Get-FileHash -LiteralPath $kernelArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $distributionHead = Get-RepositoryHead (Join-Path $workspaceRoot 'Repositories/Distribution')
    $sshHead = Get-RepositoryHead $sshRepository
    $sshHash = (Get-FileHash -LiteralPath $sshArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $audioDiagHead = Get-RepositoryHead $audioDiagRepository
    $audioDiagDirty = Get-RepositoryDirty $audioDiagRepository
    $audioDiagVersion = Get-ModuleVersion $audioDiagManifest
    $audioDiagHash = (Get-FileHash -LiteralPath $audioDiagArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $hardwareDiagHead = Get-RepositoryHead $hardwareDiagRepository
    $hardwareDiagHash = (Get-FileHash -LiteralPath $hardwareDiagArtifact -Algorithm SHA256).Hash.ToLowerInvariant()

    $imageTitle = if ($IsolationNoHda) {
        'R4OS HDA 0.71.10 boot isolation image - HDA disabled'
    } elseif ($IsolationNoUpdSvc) {
        'R4OS 0.71.11 boot isolation image - UPDSVC manual'
    } else {
        'R4OS HDA 0.71.10 hardware acceptance image'
    }
    $titleUnderline = '=' * $imageTitle.Length
    $bootPolicy = if ($IsolationNoHda) {
        'HDA_DISABLED_ISOLATION'
    } elseif ($IsolationNoUpdSvc) {
        'UPDSVC_MANUAL_ISOLATION'
    } else {
        'HDA_ENABLED_ACCEPTANCE'
    }
    $evidenceState = if ($IsolationNoHda -or $IsolationNoUpdSvc) { 'ISOLATION_ONLY' } else { 'NOT_PERFORMED' }
    $manifestLines = @(
        $imageTitle,
        $titleUnderline,
        '',
        ('CreatedUtc=' + $createdUtc),
        ('EmbeddedRelease=' + $releaseVersion),
        ('HdaCommit=' + $hdaHead),
        ('HdaWorktreeDirty=' + $hdaDirty),
        ('HdaModuleVersion=' + $hdaVersion),
        ('HdaArtifactSha256=' + $hdaHash),
        ('KernelCommit=' + $kernelHead),
        ('KernelWorktreeDirty=' + $kernelDirty),
        ('KernelArtifactSha256=' + $kernelHash),
        ('DistributionCommit=' + $distributionHead),
        ('SshdCommit=' + $sshHead),
        ('SshdArtifactSha256=' + $sshHash),
        ('AudioDiagCommit=' + $audioDiagHead),
        ('AudioDiagWorktreeDirty=' + $audioDiagDirty),
        ('AudioDiagModuleVersion=' + $audioDiagVersion),
        ('AudioDiagArtifactSha256=' + $audioDiagHash),
        ('HardwareDiagCommit=' + $hardwareDiagHead),
        ('HardwareDiagArtifactSha256=' + $hardwareDiagHash),
        ('ImageFile=' + $imageInfo.Name),
        ('ImageBytes=' + $imageInfo.Length),
        ('ImageSha256=' + $imageHash),
        ('ImagePlanSha256=' + $planHash),
        ('Profile=' + $baseProfile + ' with temporary private interactive overlay'),
        ('BootPolicy=' + $bootPolicy),
        'OperatorBatches=HDA-COLD.BAT,HDA-LONG.BAT,HDA-WARM.BAT',
        ('HardwareEvidence=' + $evidenceState),
        '',
        'The script never writes to a removable device. Flashing and every',
        'listening observation remain explicit physical operator actions.',
        $(if ($IsolationNoHda) {
            'This image only decides whether boot completes with HDA disabled.'
        } elseif ($IsolationNoUpdSvc) {
            'This image only decides whether boot completes without automatic UPDSVC startup.'
        } else {
            'A successful QEMU boot is not Lenovo or listening evidence.'
        })
    )
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'MANIFEST.txt'), (($manifestLines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

    Write-Host ('Hardwareimage: ' + $targetImage)
    Write-Host ('SHA-256: ' + $imageHash)
}
catch {
    $primaryError = $_
}
finally {
    foreach ($path in @($overlayConfig, $overlayServices, $overlayAutoexec, $overlayBasic, $overlayObservations, $overlayColdBatch, $overlayLongBatch, $overlayWarmBatch, $overlayAudioDiag, $overlayHardwareDiag)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    Remove-EmptyDirectory $overlayTemp
    Remove-EmptyDirectory $overlayDiag
    Remove-EmptyDirectory $overlayTerminal
    Remove-EmptyDirectory $overlaySoftware
    Remove-EmptyDirectory $overlayR4osConfig
    Remove-EmptyDirectory $overlayR4os
    Remove-EmptyDirectory $privateOverlay

    if ($restoreRequired) {
        try {
            Invoke-WorkspaceBuild @('-image', $baseProfile)
            Invoke-WorkspaceBuild @('-verify', $baseProfile)
            Write-Host ('Normales ' + $baseProfile + '-Profil wiederhergestellt und verifiziert.')
        }
        catch {
            if ($null -eq $primaryError) { $primaryError = $_ }
            else { Write-Warning ('Zusaetzlich scheiterte die Wiederherstellung des ' + $baseProfile + '-Profils: ' + $_.Exception.Message) }
        }
    }

    if ($null -ne $lockStream) { $lockStream.Dispose() }
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) { Remove-Item -LiteralPath $lockPath -Force }
}

if ($null -ne $primaryError) { throw $primaryError }
