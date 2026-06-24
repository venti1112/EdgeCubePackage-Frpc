#!/usr/bin/env pwsh
#
# Build frpc as Android c-shared libraries (libfrpc.so), one per ABI, and
# package them as EdgeCube .ecpkg runtime packages.
#
# This is the Windows-native PowerShell equivalent of build.sh.
#
# Usage:
#   .\scripts\build.ps1 [abi ...]
#
# Environment overrides:
#   FRP_VERSION       frp module version to build (default: latest).
#                     Set to a tag like v0.69.1 to pin; set to "keep" to use
#                     whatever is already pinned in go.mod.
#   ANDROID_NDK_HOME  NDK path (default: D:\AndroidSDK\ndk\28.2.13676358).
#   ANDROID_API       min API level (default: 24).
#   ECPKG_ID          runtime id in edgecube-package.json (default: frpc).
#   ECPKG_NAME        display name in edgecube-package.json (default: FRP Client).
#   ECPKG_AUTHOR      package author (default: EdgeCube).
#   ECPKG_MIN_APP_VERSION
#                     minimum EdgeCube versionCode (default: 6).

param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Abis
)

# Handle comma-separated arguments (e.g., "arm64-v8a,armeabi-v7a,x86_64")
$expandedAbis = @()
foreach ($abi in $Abis) {
    if ($abi -match ',') {
        $expandedAbis += $abi -split ','
    } else {
        $expandedAbis += $abi
    }
}
$Abis = $expandedAbis

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir
Set-Location $Root

# ── Configuration ────────────────────────────────────────────────────────────

$Env:FRP_VERSION = if ($Env:FRP_VERSION) { $Env:FRP_VERSION } else { "latest" }
$AndroidNdkHome = if ($Env:ANDROID_NDK_HOME) { $Env:ANDROID_NDK_HOME } else { "D:\AndroidSDK\ndk\28.2.13676358" }
$Api = if ($Env:ANDROID_API) { $Env:ANDROID_API } else { "24" }
$EcpkgId = if ($Env:ECPKG_ID) { $Env:ECPKG_ID } else { "frpc" }
$EcpkgName = if ($Env:ECPKG_NAME) { $Env:ECPKG_NAME } else { "FRP Client" }
$EcpkgAuthor = if ($Env:ECPKG_AUTHOR) { $Env:ECPKG_AUTHOR } else { "EdgeCube" }
$EcpkgHomepage = if ($Env:ECPKG_HOMEPAGE) { $Env:ECPKG_HOMEPAGE } else { "https://github.com/fatedier/frp" }
$EcpkgRepository = if ($Env:ECPKG_REPOSITORY) { $Env:ECPKG_REPOSITORY } else { "https://github.com/venti1112/EdgeCubePackage-Frpc" }
$EcpkgMinAppVersion = if ($Env:ECPKG_MIN_APP_VERSION) { $Env:ECPKG_MIN_APP_VERSION } else { "6" }

# ── Validation ───────────────────────────────────────────────────────────────

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    Write-Error "error: go not found in PATH"
    exit 1
}

if ($EcpkgId -notmatch '^[A-Za-z0-9._-]+$' -or $EcpkgId.StartsWith('.')) {
    Write-Error "error: ECPKG_ID must match ^[A-Za-z0-9._-]+$ and must not start with '.'"
    exit 1
}

if ($EcpkgMinAppVersion -notmatch '^[0-9]+$') {
    Write-Error "error: ECPKG_MIN_APP_VERSION must be an integer"
    exit 1
}

# ── Helper functions ─────────────────────────────────────────────────────────

function Write-Manifest {
    param(
        [string]$ManifestPath,
        [string[]]$Archs
    )

    $VersionJson = $script:Version -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", '\r'
    $NameJson = $script:EcpkgName -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", '\r'
    $AuthorJson = $script:EcpkgAuthor -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", '\r'
    $HomepageJson = $script:EcpkgHomepage -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", '\r'
    $RepositoryJson = $script:EcpkgRepository -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", '\r'

    $archEntries = @()
    for ($i = 0; $i -lt $Archs.Count; $i++) {
        $arch = $Archs[$i]
        $comma = if ($i -lt $Archs.Count - 1) { "," } else { "" }
        $archEntries += "    `"$arch`": { `"dir`": `"$arch`" }$comma"
    }
    $archBlock = $archEntries -join "`n"

    $manifest = @"
{
  "formatVersion": 1,
  "type": "frpc",
  "id": "$EcpkgId",
  "name": "$NameJson",
  "version": "$VersionJson",
  "description": "frp client runtime for EdgeCube.",
  "author": "$AuthorJson",
  "homepage": "$HomepageJson",
  "repository": "$RepositoryJson",
  "arch": {
$archBlock
  },
  "launcher": {
    "type": "frpc",
    "lib": "lib/libfrpc.so"
  },
  "minAppVersion": $EcpkgMinAppVersion
}
"@

    Set-Content -Path $ManifestPath -Value $manifest -Encoding UTF8
}

function New-Ecpkg {
    param(
        [string]$SourceDir,
        [string]$DestinationPath
    )

    if (Test-Path $DestinationPath) {
        Remove-Item $DestinationPath -Force
    }

    if (Get-Command zip -ErrorAction SilentlyContinue) {
        Push-Location $SourceDir
        try {
            & zip -qr $DestinationPath edgecube-package.json */
        } finally {
            Pop-Location
        }
        return
    }

    $py = $null
    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        $py = (Get-Command python3).Source
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
        $py = (Get-Command python).Source
    }

    if (-not $py) {
        Write-Error "error: zip or python is required to create .ecpkg packages"
        exit 1
    }

    $pythonScript = @"
import os
import sys
import zipfile

src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        files.sort()
        rel_root = os.path.relpath(root, src)
        if rel_root != ".":
            zf.write(root, rel_root.replace(os.sep, "/") + "/")
        for name in files:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, src).replace(os.sep, "/")
            zf.write(path, rel)
"@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "zip_ecpkg_$([System.IO.Path]::GetRandomFileName()).py"
    try {
        Set-Content -Path $tempScript -Value $pythonScript -Encoding UTF8
        & $py $tempScript $SourceDir $DestinationPath
        if ($LASTEXITCODE -ne 0) {
            Write-Error "error: Python zip script failed"
            exit 1
        }
    } finally {
        if (Test-Path $tempScript) {
            Remove-Item $tempScript -Force
        }
    }
}

# ── 1. Resolve the frp dependency ────────────────────────────────────────────

if ($Env:FRP_VERSION -eq "keep") {
    Write-Host ">>> using frp version already pinned in go.mod (no update)"
} else {
    Write-Host ">>> resolving frp@$Env:FRP_VERSION"
    & go get "github.com/fatedier/frp@$Env:FRP_VERSION"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$script:Version = (& go list -m github.com/fatedier/frp).Split(" ")[1]
Write-Host "    frp = $script:Version"

# Mirror frp's own replace directives into our go.mod
$Gomodcache = & go env GOMODCACHE
$Frpmod = Join-Path $Gomodcache "github.com/fatedier/frp@$script:Version\go.mod"

if (Test-Path $Frpmod) {
    $frpContent = Get-Content $Frpmod -Raw
    if ($frpContent -match '(?m)^replace\s*\(') {
        Write-Warning "frp go.mod uses block-form replace(...); verify replaces manually"
    }

    Get-Content $Frpmod | ForEach-Object {
        $line = $_.Trim()
        if (-not $line) { return }

        if ($line -match '(?m)^replace\s+(.+?)\s*=>\s*(.+?)(?:\s+(.+?))?$') {
            $old = $Matches[1].Trim()
            $new = $Matches[2].Trim()
            $ver = if ($Matches[3]) { $Matches[3].Trim() } else { $null }

            if ($old -and $new) {
                if ($ver) {
                    & go mod edit -replace "${old}=${new}@${ver}"
                } else {
                    & go mod edit -replace "${old}=${new}"
                }
                Write-Host "    mirrored replace: $old => $new ${ver}"
            }
        }
    }
}

& go mod tidy
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# ── 2. Cross-compile and package per ABI ─────────────────────────────────────

$Dist = Join-Path $Root "dist"
$Pkgs = Join-Path $Dist "packages"
$MultiStage = Join-Path $Dist "ecpkg-staging\multi"

New-Item -ItemType Directory -Path $Pkgs -Force | Out-Null
if (Test-Path (Join-Path $Dist "ecpkg-staging")) {
    Remove-Item (Join-Path $Dist "ecpkg-staging") -Recurse -Force
}

# Clean old packages
Get-ChildItem -Path $Pkgs -Filter "$EcpkgId-*.ecpkg" -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem -Path $Pkgs -Filter "bin_*.tgz" -ErrorAction SilentlyContinue | Remove-Item -Force
if (Test-Path (Join-Path $Pkgs "version")) {
    Remove-Item (Join-Path $Pkgs "version") -Force
}

if ($Abis.Count -eq 0) {
    $Abis = @("arm64-v8a", "armeabi-v7a", "x86_64")
}

$builtArchs = @()

foreach ($abi in $Abis) {
    $goarch = $null
    $ccname = $null
    $pkgarch = $null
    $armenv = $null

    switch ($abi) {
        "arm64-v8a" {
            $goarch = "arm64"
            $ccname = "aarch64-linux-android$Api"
            $pkgarch = "arm64"
        }
        "armeabi-v7a" {
            $goarch = "arm"
            $ccname = "armv7a-linux-androideabi$Api"
            $pkgarch = "arm"
            $armenv = "GOARM=7"
        }
        "x86_64" {
            $goarch = "amd64"
            $ccname = "x86_64-linux-android$Api"
            $pkgarch = "x86_64"
        }
        "x86" {
            Write-Warning "skip unsupported ecpkg abi: $abi (EdgeCube package spec supports arm64, arm, x86_64)"
            continue
        }
        default {
            Write-Warning "skip unknown abi: $abi"
            continue
        }
    }

    $tooldir = Join-Path $AndroidNdkHome "toolchains\llvm\prebuilt\windows-x86_64\bin"
    $cc = Join-Path $tooldir "$ccname-clang.cmd"

    if (-not (Test-Path $cc)) {
        Write-Error "error: compiler not found: $cc"
        exit 1
    }

    $out = Join-Path $Dist $abi
    New-Item -ItemType Directory -Path $out -Force | Out-Null

    Write-Host ">>> building $abi (GOARCH=$goarch) with $(Split-Path -Leaf $cc)"

    $env:CGO_ENABLED = "1"
    $env:GOOS = "android"
    $env:GOARCH = $goarch
    $env:CC = $cc

    if ($armenv) {
        $env:GOARM = "7"
    } else {
        Remove-Item Env:GOARM -ErrorAction SilentlyContinue
    }

    & go build -buildmode=c-shared -trimpath `
        -ldflags "-s -w -checklinkname=0" `
        -o (Join-Path $out "libfrpc.so") ./frplib

    if ($LASTEXITCODE -ne 0) {
        Write-Error "error: build failed for $abi"
        exit $LASTEXITCODE
    }

    Remove-Item Env:CGO_ENABLED
    Remove-Item Env:GOOS
    Remove-Item Env:GOARCH
    Remove-Item Env:CC
    Remove-Item Env:GOARM -ErrorAction SilentlyContinue

    $singleStage = Join-Path $Dist "ecpkg-staging\$pkgarch"
    New-Item -ItemType Directory -Path "$singleStage\$pkgarch\lib" -Force | Out-Null
    Copy-Item (Join-Path $out "libfrpc.so") -Destination "$singleStage\$pkgarch\lib\libfrpc.so"
    Write-Manifest -ManifestPath (Join-Path $singleStage "edgecube-package.json") -Archs @($pkgarch)
    New-Ecpkg -SourceDir $singleStage -DestinationPath (Join-Path $Pkgs "$EcpkgId-$pkgarch.ecpkg")

    New-Item -ItemType Directory -Path "$MultiStage\$pkgarch\lib" -Force | Out-Null
    Copy-Item (Join-Path $out "libfrpc.so") -Destination "$MultiStage\$pkgarch\lib\libfrpc.so"

    if ($builtArchs -notcontains $pkgarch) {
        $builtArchs += $pkgarch
    }

    Write-Host "    -> $(Join-Path $out 'libfrpc.so')"
    Write-Host "    -> $(Join-Path $Pkgs "$EcpkgId-$pkgarch.ecpkg")"
}

if ($builtArchs.Count -eq 0) {
    Write-Error "error: no supported ABIs were built"
    exit 1
}

if ($builtArchs.Count -gt 1) {
    Write-Manifest -ManifestPath (Join-Path $MultiStage "edgecube-package.json") -Archs $builtArchs
    New-Ecpkg -SourceDir $MultiStage -DestinationPath (Join-Path $Pkgs "$EcpkgId-multi.ecpkg")
    Write-Host "    -> $(Join-Path $Pkgs "$EcpkgId-multi.ecpkg")"
}

Write-Host ""
Write-Host "done. frp=$script:Version  ABIs=$($Abis -join ' ')"
Write-Host "packages: $Pkgs"
Write-Host "import ${EcpkgId}-<arch>.ecpkg or ${EcpkgId}-multi.ecpkg from EdgeCube's runtime page."
