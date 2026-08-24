param(
    [Alias("DownloadVersion")]
    [string]$Version,
    [string]$EditorRoot,
    [string]$SetupExe,
    [string[]]$Modules,
    [string]$ConfigJson,
    [switch]$SkipEditor,
    [switch]$ListOnly,
    [switch]$DownloadOnly
)

$ErrorActionPreference = "Stop"
$PackageRoot = $PSScriptRoot

$script:PreparedDestinations = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

function Get-UnitySetupExe {
    param([string]$Explicit)

    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        $path = Join-Path $PackageRoot ([System.IO.Path]::GetFileName($Explicit))
        if (-not (Test-Path -LiteralPath $path)) {
            $path = [System.IO.Path]::GetFullPath($Explicit)
        }
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Setup exe not found: $Explicit"
        }
        return (Get-Item -LiteralPath $path)
    }

    $candidates = @(Get-ChildItem -LiteralPath $PackageRoot -Filter "UnitySetup64-*.exe" -File |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        throw "UnitySetup64-*.exe not found in $PackageRoot"
    }
    return $candidates[0]
}

function Get-UnityVersionFromSetup {
    param($SetupItem)

    if ($SetupItem.BaseName -match '^UnitySetup64-(.+)$') {
        return $Matches[1]
    }

    $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($SetupItem.FullName)
    if ($info.ProductName -match 'Unity\s+(\d+\.\d+\.\d+\w*)') {
        return $Matches[1]
    }
    if ($info.FileDescription -match 'Unity\s+(\d+\.\d+\.\d+\w*)') {
        return $Matches[1]
    }

    throw "Unable to determine Unity version from $($SetupItem.Name)"
}

function Get-InstalledEditorRoot {
    param([string]$Version)

    $installerKey = "HKLM:\SOFTWARE\Unity Technologies\Installer\Unity $Version"
    if (Test-Path -LiteralPath $installerKey) {
        $props = Get-ItemProperty -LiteralPath $installerKey
        $location = $props."Location x64"
        if (-not [string]::IsNullOrWhiteSpace($location)) {
            $candidate = [Environment]::ExpandEnvironmentVariables($location.Trim('"'))
            if (Test-Path -LiteralPath (Join-Path $candidate "Editor\Unity.exe")) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }
    }

    $uninstallRoots = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($root in $uninstallRoots) {
        $key = Join-Path $root "Unity $Version"
        if (-not (Test-Path -LiteralPath $key)) {
            continue
        }

        $props = Get-ItemProperty -LiteralPath $key
        foreach ($value in @($props.DisplayIcon, $props.UninstallString)) {
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $path = [Environment]::ExpandEnvironmentVariables($value.Trim('"'))
            $marker = "\Editor\"
            $index = $path.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
            if ($index -lt 0) {
                continue
            }

            $candidate = $path.Substring(0, $index)
            if (Test-Path -LiteralPath (Join-Path $candidate "Editor\Unity.exe")) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }
    }

    return $null
}

function Wait-InstalledEditorRoot {
    param(
        [string]$Version,
        [int]$TimeoutSeconds = 1800
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $found = Get-InstalledEditorRoot -Version $Version
        if (-not [string]::IsNullOrWhiteSpace($found)) {
            return $found
        }
        Start-Sleep -Seconds 2
    }

    throw "Timed out waiting for Unity $Version install path after interactive editor setup."
}

function Resolve-EditorRoot {
    param(
        [string]$Version,
        [string]$ExplicitRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRoot)) {
        $candidate = [System.IO.Path]::GetFullPath($ExplicitRoot)
        if (-not (Test-Path -LiteralPath (Join-Path $candidate "Editor\Unity.exe"))) {
            throw "EditorRoot does not contain Editor\Unity.exe: $candidate"
        }
        return $candidate
    }

    $found = Get-InstalledEditorRoot -Version $Version
    if ([string]::IsNullOrWhiteSpace($found)) {
        throw "Unity $Version install path not found. Complete interactive editor setup first, or pass -EditorRoot."
    }
    return $found
}

function Get-ReleaseConfig {
    param(
        [string]$Version,
        [string]$ExplicitConfig
    )

    $cacheCandidates = @(
        (Join-Path $PackageRoot "unity-release-$Version-windows-x86_64.json"),
        (Join-Path $PackageRoot "unity-$Version-windows-x86_64.json")
    )
    $cachePath = $cacheCandidates[0]

    if (-not [string]::IsNullOrWhiteSpace($ExplicitConfig)) {
        if (-not (Test-Path -LiteralPath $ExplicitConfig)) {
            throw "ConfigJson not found: $ExplicitConfig"
        }
        return (Get-Content -LiteralPath $ExplicitConfig -Raw -Encoding UTF8 | ConvertFrom-Json)
    }

    foreach ($candidate in $cacheCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            Write-Host "Using cached release config: $candidate"
            $cached = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cached.PSObject.Properties.Name -contains "downloadUrl") {
                return $cached
            }
            Write-Host "Cached config has no editor download URL; refreshing it."
        }
    }

    $apiUrl = "https://services.api.unity.com/unity/editor/release/v1/releases?version=$Version"
    try {
        Write-Host "Fetching release config: $apiUrl"
        $response = Invoke-RestMethod -Uri $apiUrl -Method Get
        if (-not $response.results -or $response.results.Count -eq 0) {
            throw "No release found for version $Version"
        }

        $release = $response.results[0]
        $download = $release.downloads |
            Where-Object { $_.platform -eq "WINDOWS" -and $_.architecture -eq "X86_64" } |
            Select-Object -First 1
        if (-not $download) {
            throw "Windows x86_64 download entry not found for $Version"
        }

        $payload = [pscustomobject]@{
            version     = $release.version
            revision    = ([uri]$download.url).Segments[-3].TrimEnd('/')
            downloadUrl = $download.url
            downloadType = $download.type
            editorIntegrity = $download.integrity
            downloadSize = $download.downloadSize.value
            modules     = $download.modules
            fetchedAt   = (Get-Date).ToString("o")
            sourceUrl   = $apiUrl
        }

        $payload | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $cachePath -Encoding UTF8
        Write-Host "Cached config: $cachePath"
        return $payload
    }
    catch {
        throw
    }
}

function Get-DownloadFileName {
    param(
        [string]$Url,
        [string]$PreferredName,
        [string]$ModuleId,
        [string]$FallbackName
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredName)) {
        return [System.IO.Path]::GetFileName($PreferredName)
    }

    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        $fileName = [System.IO.Path]::GetFileName(([uri]$Url).LocalPath)
        if (-not [string]::IsNullOrWhiteSpace($fileName) -and $fileName -notmatch '^[^\.]+$') {
            return $fileName
        }

        if ($ModuleId -match '^language-(.+)$') {
            return "$($Matches[1]).po"
        }

        if (-not [string]::IsNullOrWhiteSpace($fileName)) {
            return $fileName
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackName)) {
        return [System.IO.Path]::GetFileName($FallbackName)
    }

    throw "Unable to determine local file name for download: $Url"
}

function Ensure-LocalDownload {
    param(
        [string]$Url,
        [string]$PreferredName,
        [string]$ModuleId,
        [string]$FallbackName,
        $ExpectedSize
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "Download URL is empty for $ModuleId"
    }

    $name = Get-DownloadFileName -Url $Url -PreferredName $PreferredName -ModuleId $ModuleId -FallbackName $FallbackName
    $target = Join-Path $PackageRoot $name
    $existing = if (Test-Path -LiteralPath $target) { Get-Item -LiteralPath $target } else { $null }
    if ($existing -and (Test-SizeMatch -FileItem $existing -ExpectedSize $ExpectedSize)) {
        Write-Host "Already present: $name"
        return $existing
    }

    if ($existing) {
        Write-Host "Replacing incomplete file: $name ($($existing.Length) bytes)"
    }
    else {
        Write-Host "Downloading: $name"
    }

    $temporary = "$target.download"
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $temporary -UseBasicParsing
        $downloaded = Get-Item -LiteralPath $temporary
        if (-not (Test-SizeMatch -FileItem $downloaded -ExpectedSize $ExpectedSize)) {
            throw "Downloaded size mismatch for ${name}: expected $ExpectedSize, got $($downloaded.Length)"
        }
        Move-Item -LiteralPath $temporary -Destination $target -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }

    return (Get-Item -LiteralPath $target)
}

function Get-LocalPackagePath {
    param(
        [string]$Url,
        [string]$PreferredName
    )

    $names = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($PreferredName)) {
        $names.Add($PreferredName)
    }

    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        $fileName = [System.IO.Path]::GetFileName(([uri]$Url).LocalPath)
        if (-not [string]::IsNullOrWhiteSpace($fileName) -and -not $names.Contains($fileName)) {
            $names.Add($fileName)
        }

        # language packs often saved as zh-hans.po while URL has no extension
        if ($Url -match '/([^/]+)$' -and $Matches[1] -notmatch '\.') {
            $langName = "$($Matches[1]).po"
            if (-not $names.Contains($langName)) {
                $names.Add($langName)
            }
        }
    }

    foreach ($name in $names) {
        $path = Join-Path $PackageRoot $name
        if (Test-Path -LiteralPath $path) {
            return (Get-Item -LiteralPath $path)
        }
    }

    return $null
}

function Expand-ModuleTree {
    param($Modules)

    $list = New-Object System.Collections.Generic.List[object]
    function Walk($node, $parentId) {
        if ($null -eq $node) { return }
        $list.Add([pscustomobject]@{
            Node     = $node
            ParentId = $parentId
        })
        foreach ($child in @($node.subModules)) {
            Walk $child $node.id
        }
    }

    foreach ($module in @($Modules)) {
        Walk $module $null
    }
    return $list
}

function Resolve-UnityPath {
    param(
        [string]$Template,
        [string]$UnityPath
    )

    if ([string]::IsNullOrWhiteSpace($Template)) {
        return $UnityPath
    }
    return $Template.Replace("{UNITY_PATH}", $UnityPath)
}

function Assert-UnderPath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe target path: $pathFull"
    }
}

function Reset-Directory {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-DownloadSizeBytes {
    param($SizeInfo)

    if ($null -eq $SizeInfo) {
        return $null
    }
    if ($SizeInfo -is [ValueType]) {
        return [int64]$SizeInfo
    }
    if ($SizeInfo.PSObject.Properties.Name -contains "value") {
        return [int64]$SizeInfo.value
    }
    return $null
}

function Ensure-Destination {
    param(
        [string]$Destination,
        [string]$UnityPath
    )

    Assert-UnderPath -Root $UnityPath -Path $Destination

    $full = [System.IO.Path]::GetFullPath($Destination)
    $sdkRoot = [System.IO.Path]::GetFullPath((Join-Path $UnityPath "Editor\Data\PlaybackEngines\AndroidPlayer\SDK"))
    $isSdkRoot = $full.Equals($sdkRoot, [StringComparison]::OrdinalIgnoreCase)

    if ($script:PreparedDestinations.Contains($full)) {
        if (-not (Test-Path -LiteralPath $Destination)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
        return
    }

    if ($isSdkRoot) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    else {
        Reset-Directory $Destination
    }

    [void]$script:PreparedDestinations.Add($full)
}

function Rename-ExtractedPath {
    param(
        [string]$From,
        [string]$To,
        [string]$UnityPath
    )

    Assert-UnderPath -Root $UnityPath -Path $From
    Assert-UnderPath -Root $UnityPath -Path $To

    if (-not (Test-Path -LiteralPath $From)) {
        throw "Extracted path not found for rename: $From"
    }

    $fromFull = [System.IO.Path]::GetFullPath($From)
    $toFull = [System.IO.Path]::GetFullPath($To)

    if ($fromFull.Equals($toFull, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $prefix = $toFull.TrimEnd('\') + '\'
    $isNested = $fromFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)

    if ($isNested) {
        Get-ChildItem -LiteralPath $From -Force | ForEach-Object {
            $target = Join-Path $To $_.Name
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force
            }
            Move-Item -LiteralPath $_.FullName -Destination $To
        }
        Remove-Item -LiteralPath $From -Recurse -Force
        return
    }

    $toParent = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $toParent)) {
        New-Item -ItemType Directory -Path $toParent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $To) {
        Remove-Item -LiteralPath $To -Recurse -Force
    }
    Move-Item -LiteralPath $From -Destination $To
}

function Install-ExePackage {
    param(
        [string]$ExePath,
        [string]$Destination,
        [string]$Label
    )

    Write-Host "Installing $Label"
    Write-Host "  $ExePath"
    Write-Host "  -> $Destination"

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    # NSIS /D= must be last and unquoted. ProcessStartInfo.Arguments preserves that.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = "/S /D=$Destination"
    $psi.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process) {
        throw "Failed to start installer: $ExePath"
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "Installer failed ($($process.ExitCode)): $ExePath"
    }
}

function Install-EditorInteractive {
    param(
        [string]$ExePath,
        [string]$Label
    )

    Write-Host "Launching interactive editor setup: $Label"
    Write-Host "  $ExePath"
    Write-Host "Choose the install path in the installer UI. Modules will follow that path."

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.UseShellExecute = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process) {
        throw "Failed to start interactive installer: $ExePath"
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "Interactive editor setup failed ($($process.ExitCode)): $ExePath"
    }
}

function Install-ZipPackage {
    param(
        $Module,
        [string]$ZipPath,
        [string]$UnityPath
    )

    $destination = Resolve-UnityPath -Template $Module.destination -UnityPath $UnityPath

    $size = (Get-Item -LiteralPath $ZipPath).Length
    if ($size -le 256) {
        Write-Host "Skipping empty stub package: $(Split-Path $ZipPath -Leaf)"
        return
    }

    Write-Host "Extracting $($Module.id)"
    Write-Host "  $ZipPath"
    Write-Host "  -> $destination"

    Ensure-Destination -Destination $destination -UnityPath $UnityPath
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $destination)

    if ($Module.extractedPathRename) {
        $from = Resolve-UnityPath -Template $Module.extractedPathRename.from -UnityPath $UnityPath
        $to = Resolve-UnityPath -Template $Module.extractedPathRename.to -UnityPath $UnityPath
        Rename-ExtractedPath -From $from -To $to -UnityPath $UnityPath
    }
}

function Install-PoPackage {
    param(
        $Module,
        [string]$PoPath,
        [string]$UnityPath
    )

    $destination = Resolve-UnityPath -Template $Module.destination -UnityPath $UnityPath
    Assert-UnderPath -Root $UnityPath -Path $destination
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    $fileName = [System.IO.Path]::GetFileName($PoPath)
    if ($Module.id -match '^language-(.+)$') {
        $fileName = "$($Matches[1]).po"
    }

    $target = Join-Path $destination $fileName
    Write-Host "Installing language pack $($Module.id)"
    Write-Host "  $PoPath"
    Write-Host "  -> $target"
    Copy-Item -LiteralPath $PoPath -Destination $target -Force
}

function Test-SizeMatch {
    param(
        $FileItem,
        $ExpectedSize
    )

    if ($null -eq $ExpectedSize -or $ExpectedSize -le 0) {
        return $true
    }
    return ($FileItem.Length -eq [int64]$ExpectedSize)
}

# ---- main ----
$downloadVersionMode = -not [string]::IsNullOrWhiteSpace($Version)
$setup = $null
if (-not $downloadVersionMode) {
    $setup = Get-UnitySetupExe -Explicit $SetupExe
    $version = Get-UnityVersionFromSetup -SetupItem $setup
}
Write-Host "Detected Unity version: $version"

$config = Get-ReleaseConfig -Version $version -ExplicitConfig $ConfigJson
if ($downloadVersionMode -and $config.version -and $config.version -ne $version) {
    throw "Release config version mismatch: requested $version, received $($config.version)"
}

$editorLocal = $setup
if ($downloadVersionMode -and -not $SkipEditor) {
    if (-not [string]::IsNullOrWhiteSpace($SetupExe)) {
        try {
            $editorLocal = Get-UnitySetupExe -Explicit $SetupExe
            $setupVersion = Get-UnityVersionFromSetup -SetupItem $editorLocal
            if ($setupVersion -ne $version) {
                throw "Setup exe version mismatch: requested $version, got $setupVersion"
            }
        }
        catch {
            Write-Host "Specified setup exe is unavailable for $version; using the release download."
            $editorLocal = $null
        }
    }

    $editorExpectedSize = Get-DownloadSizeBytes $config.downloadSize
    if (-not $editorLocal -and -not $ListOnly) {
        $editorLocal = Ensure-LocalDownload `
            -Url $config.downloadUrl `
            -ModuleId "editor" `
            -FallbackName "UnitySetup64-$version.exe" `
            -ExpectedSize $editorExpectedSize
    }
    if (-not $editorLocal) {
        $editorLocal = Get-LocalPackagePath -Url $config.downloadUrl -PreferredName "UnitySetup64-$version.exe"
    }
}

if (-not $SkipEditor -and -not $editorLocal -and -not $ListOnly) {
    throw "Editor package is missing. Pass -Version to download it or place UnitySetup64-$version.exe in $PackageRoot."
}

if ($editorLocal) {
    Write-Host "Setup: $($editorLocal.FullName)"
}

$knownRoot = $null
if (-not [string]::IsNullOrWhiteSpace($EditorRoot)) {
    $candidate = [System.IO.Path]::GetFullPath($EditorRoot)
    if (Test-Path -LiteralPath (Join-Path $candidate "Editor\Unity.exe")) {
        $knownRoot = $candidate
    }
}
if ([string]::IsNullOrWhiteSpace($knownRoot)) {
    $knownRoot = Get-InstalledEditorRoot -Version $version
}

$moduleNodes = Expand-ModuleTree -Modules $config.modules
$knownModuleIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $moduleNodes) { [void]$knownModuleIds.Add($entry.Node.id) }

$selectedIds = $null
if ($Modules -and $Modules.Count -gt 0) {
    $selectedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $Modules) {
        if (-not $knownModuleIds.Contains($id)) {
            throw "Requested module is not published for ${version}: $id"
        }
        [void]$selectedIds.Add($id)
    }
}
elseif ($downloadVersionMode) {
    $selectedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @("android", "linux-il2cpp", "windows-mono", "windows-il2cpp")) {
        [void]$selectedIds.Add($id)
    }

    # Selecting Android includes its SDK/NDK tree and the bundled JDK.
    do {
        $expanded = $false
        foreach ($entry in $moduleNodes) {
            if ($entry.ParentId -and $selectedIds.Contains($entry.ParentId) -and $selectedIds.Add($entry.Node.id)) {
                $expanded = $true
            }
        }
    } while ($expanded)

    foreach ($id in @("android", "linux-il2cpp", "windows-mono", "windows-il2cpp")) {
        if (-not $knownModuleIds.Contains($id)) {
            if ($id -eq "windows-mono") {
                Write-Warning "This Unity release has no separate Windows Mono package; Mono is included with the Editor."
            }
            else {
                throw "Required module is not published for ${version}: $id"
            }
        }
    }
}

$plan = New-Object System.Collections.Generic.List[object]

# editor
if (-not $SkipEditor) {
    $plan.Add([pscustomobject]@{
        Kind         = "editor"
        Id           = "editor"
        Name         = "Unity Editor $version"
        Type         = "EXE"
        LocalPath    = if ($editorLocal) { $editorLocal.FullName } else { $null }
        ExpectedSize = Get-DownloadSizeBytes $config.downloadSize
        Module       = $null
        Available    = $null -ne $editorLocal
    })
}

foreach ($entry in $moduleNodes) {
    $module = $entry.Node
    if ($selectedIds -and -not $selectedIds.Contains($module.id)) {
        # Explicit selections are intentionally limited to the requested IDs.
        continue
    }

    $expected = Get-DownloadSizeBytes $module.downloadSize
    $local = Get-LocalPackagePath -Url $module.url -PreferredName $null
    if ($downloadVersionMode -and -not $ListOnly) {
        $local = Ensure-LocalDownload `
            -Url $module.url `
            -ModuleId $module.id `
            -ExpectedSize $expected
    }
    $available = $null -ne $local

    # Legacy auto mode only installs files already present in the package directory.
    if (-not $selectedIds -and -not $available) {
        continue
    }

    $plan.Add([pscustomobject]@{
        Kind         = "module"
        Id           = $module.id
        Name         = $module.name
        Type         = $module.type
        LocalPath    = if ($local) { $local.FullName } else { $null }
        ExpectedSize = $expected
        Module       = $module
        Available    = $available
    })
}

Write-Host ""
$pathHint = if (-not [string]::IsNullOrWhiteSpace($knownRoot)) {
    $knownRoot
} elseif ($SkipEditor) {
    "(pass -EditorRoot or install editor first)"
} else {
    "(resolve after interactive editor setup)"
}
Write-Host "Install plan ($($plan.Count) items) -> $pathHint"
$plan | ForEach-Object {
    $mark = if ($_.Available) { "OK" } else { "MISSING" }
    $file = if ($_.LocalPath) { Split-Path $_.LocalPath -Leaf } else { "-" }
    "{0,-10} {1,-40} {2,-8} {3}" -f $mark, $_.Id, $_.Type, $file
} | Write-Host

if ($ListOnly) {
    return
}

# validate sizes for available packages
foreach ($item in $plan) {
    if (-not $item.Available) {
        if ($item.Kind -eq "editor") {
            throw "Editor package is missing for $version"
        }
        if ($selectedIds) {
            throw "Selected module missing locally: $($item.Id)"
        }
        continue
    }
    $file = Get-Item -LiteralPath $item.LocalPath
    if (-not (Test-SizeMatch -FileItem $file -ExpectedSize $item.ExpectedSize)) {
        throw "Size mismatch for $($item.Id): expected $($item.ExpectedSize), got $($file.Length)"
    }
}

if ($DownloadOnly) {
    Write-Host "Download complete. Files are ready in $PackageRoot"
    return
}

# install editor interactively, then resolve the chosen path for modules
$editorItem = $plan | Where-Object { $_.Kind -eq "editor" } | Select-Object -First 1
if ($editorItem) {
    if (-not [string]::IsNullOrWhiteSpace($knownRoot)) {
        Write-Host "Editor already present: $knownRoot"
        $unityPath = $knownRoot
    }
    else {
        Install-EditorInteractive -ExePath $editorItem.LocalPath -Label $editorItem.Name
        Write-Host "Waiting for registry install path..."
        $unityPath = Wait-InstalledEditorRoot -Version $version
    }
}
else {
    $unityPath = Resolve-EditorRoot -Version $version -ExplicitRoot $EditorRoot
}

$editorExe = Join-Path $unityPath "Editor\Unity.exe"
if (-not (Test-Path -LiteralPath $editorExe)) {
    throw "Unity.exe not found after editor install: $editorExe"
}
Write-Host "Using editor root: $unityPath"

# install modules: EXE platforms first, then ZIP/PO (Android deps need AndroidPlayer)
$ordered = @()
$ordered += @($plan | Where-Object { $_.Kind -eq "module" -and $_.Type -eq "EXE" -and $_.Available })
$ordered += @($plan | Where-Object { $_.Kind -eq "module" -and $_.Type -ne "EXE" -and $_.Available })

foreach ($item in $ordered) {
    switch ($item.Type) {
        "EXE" {
            $dest = Resolve-UnityPath -Template $item.Module.destination -UnityPath $unityPath
            Install-ExePackage -ExePath $item.LocalPath -Destination $dest -Label $item.Name
        }
        "ZIP" {
            Install-ZipPackage -Module $item.Module -ZipPath $item.LocalPath -UnityPath $unityPath
        }
        "PO" {
            Install-PoPackage -Module $item.Module -PoPath $item.LocalPath -UnityPath $unityPath
        }
        default {
            Write-Warning "Unsupported package type $($item.Type) for $($item.Id), skipped."
        }
    }
}

Write-Host ""
Write-Host "Done. Unity $version installed at $unityPath"
