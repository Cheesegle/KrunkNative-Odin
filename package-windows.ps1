# Builds the tester zip: dist\Krodin-Testing-<VERSION>-<sha>.zip
#
#   .\package-windows.ps1              build release binaries, then package
#   .\package-windows.ps1 -SkipBuild   package the binaries already in bin\
#
# The asset list is not maintained by hand. The client's --asset-sweep mode
# loads every map, class, weapon, icon and sound through the normal loaders and
# records each file it opened; only those files are packaged. The zip is then
# unpacked into a temp folder and swept again to prove nothing went missing.
param([switch]$SkipBuild)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$root = (Resolve-Path $PSScriptRoot).Path
$version = (Get-Content -LiteralPath (Join-Path $root "VERSION") -Raw).Trim()
$sha = (& git -C $root rev-parse --short HEAD).Trim()
if (-not $version -or -not $sha) { throw "Could not read VERSION or the git commit." }
$name = "Krodin-Testing-$version-$sha"
$dist = Join-Path $root "dist"
$zip = Join-Path $dist "$name.zip"
$work = Join-Path ([IO.Path]::GetTempPath()) ("krodin-package-" + [guid]::NewGuid().ToString("N"))
$stage = Join-Path $work $name

$binaries = @("krodin_client.exe", "krodin_server.exe", "krodin_browser.exe",
    "WebView2Loader.dll", "WebView2-LICENSE.txt", "WebView2-NOTICE.txt")
$extras = @("VERSION", "assets/css/fonts/Rajdhani-OFL.txt", "assets/hrtf/LICENSE-MIT-KEMAR.txt")
# Only game data may come from the sweep manifest; anything else is a bug.
$allowedRoots = @("assets/", "krunker-configs/")
# User-specific, secret or test files that must never ship.
$forbidden = @(".env", "client-settings.json", "audio-settings.json", "mod.zip", "*_tests.exe", "*_dev.exe", "*.ppm", "*.pdb")

$readme = @"
Krodin $version ($sha) - tester build

1. Unzip this folder anywhere and keep the files together.
2. Run krodin_client.exe.
3. To join live lobbies, press Login first and sign in. If Join asks for
   Microsoft Edge WebView2, install the Evergreen Runtime from
   https://developer.microsoft.com/microsoft-edge/webview2/ and try again.
4. If something goes wrong, send us logs\krunker-network.log from this
   folder. It is created next to krodin_client.exe when you join a lobby.

krodin_server.exe is an optional local server; you do not need it to play.
"@

function Read-List([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() })
}

# Runs the client's asset sweep with $Directory as the working directory.
function Invoke-AssetSweep([string]$Directory, [string]$Client, [string]$Manifest) {
    $log = "$Manifest.log"
    $process = Start-Process -FilePath $Client -ArgumentList @("--asset-sweep", "`"$Manifest`"") `
        -WorkingDirectory $Directory -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    Get-Content -LiteralPath $log, "$log.err" | Where-Object { $_.StartsWith("[Sweep]") } | ForEach-Object { Write-Host "  $_" }
    # 0 = complete, 2 = some required files are missing (the caller decides).
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 2) {
        throw "The asset sweep in $Directory failed with exit code $($process.ExitCode)."
    }
    $base = $Manifest -replace "\.txt$", ""
    return @{
        Used = Read-List $Manifest
        Missing = Read-List "$base-missing.txt"
        Optional = Read-List "$base-optional-missing.txt"
    }
}

function Copy-ToStage([string]$Relative) {
    $destination = Join-Path $stage $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $Relative) -Destination $destination
}

Push-Location $root
try {
    if (-not $SkipBuild) {
        Write-Host "Building release binaries..."
        & cmd.exe /c (Join-Path $root "build.bat") all aggressive
        if ($LASTEXITCODE -ne 0) { throw "build.bat all failed with exit code $LASTEXITCODE." }
    }
    foreach ($file in $binaries) {
        if (-not (Test-Path -LiteralPath (Join-Path $root "bin\$file"))) { throw "Missing bin\$file; build first." }
    }
    # Hybrid-GPU laptops pick the dedicated GPU only if the client exports
    # NvOptimusEnablement / AmdPowerXpressRequestHighPerformance.
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        & $python.Source -I (Join-Path $root "tools\check_gpu_exports.py") (Join-Path $root "bin\krodin_client.exe")
        if ($LASTEXITCODE -ne 0) { throw "krodin_client.exe is missing the dedicated-GPU exports." }
    } else {
        Write-Warning "Python not found; skipped the dedicated-GPU export check (tools\check_gpu_exports.py)."
    }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    Write-Host "Sweeping assets in the repository..."
    $repo = Invoke-AssetSweep $root (Join-Path $root "bin\krodin_client.exe") (Join-Path $work "repo-assets.txt")
    foreach ($path in $repo.Missing) { Write-Warning "Missing in the repository: $path" }

    foreach ($file in $binaries) { Copy-Item -LiteralPath (Join-Path $root "bin\$file") -Destination $stage }
    foreach ($path in @($repo.Used) + $extras) {
        if ($path -ne "VERSION" -and -not ($allowedRoots | Where-Object { $path.StartsWith($_) })) {
            throw "Refusing to package unexpected path from the sweep: $path"
        }
        Copy-ToStage $path
    }
    Set-Content -LiteralPath (Join-Path $stage "README-TESTERS.txt") -Value $readme -Encoding UTF8

    foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File -Force) {
        $relative = $file.FullName.Substring($stage.Length + 1)
        if ($relative -like "logs\*" -or ($forbidden | Where-Object { $file.Name -like $_ })) {
            throw "Refusing to package user-specific file: $relative"
        }
    }

    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
    # Name entries with "/" ourselves; Windows PowerShell's CreateFromDirectory
    # writes "\", which other unzip tools turn into literal file names.
    $writer = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) {
            $entry = "$name/" + $file.FullName.Substring($stage.Length + 1).Replace("\", "/")
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($writer, $file.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally { $writer.Dispose() }

    Write-Host "Verifying the zip in a clean folder..."
    $verify = Join-Path $work "verify"
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $verify)
    $unpacked = Join-Path $verify $name
    $package = Invoke-AssetSweep $unpacked (Join-Path $unpacked "krodin_client.exe") (Join-Path $work "package-assets.txt")
    $lost = @(@($package.Missing) + @($package.Optional) | Where-Object { $repo.Used -contains $_ })
    if ($lost.Count -gt 0) {
        throw "The zip is missing assets the repository has:`n  " + ($lost -join "`n  ")
    }
    foreach ($path in $package.Missing) { Write-Warning "Missing in the zip and the repository: $path" }

    $archive = Get-Item -LiteralPath $zip
    $reader = [IO.Compression.ZipFile]::OpenRead($zip)
    try { $count = @($reader.Entries | Where-Object { $_.Name }).Count } finally { $reader.Dispose() }
    Write-Host ("Created {0} ({1:N1} MB, {2} files, {3} assets)" -f $archive.FullName, ($archive.Length / 1MB), $count, $repo.Used.Count)
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
