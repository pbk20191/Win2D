<#
.SYNOPSIS
  Builds Win2D as static libraries (winrt.lib + win2dmod.lib) for one platform.

.DESCRIPTION
  1. Restores winrt\lib\packages.config from the public feed in nuget.config.
  2. Builds winrt\lib\winrt.lib.uap.vcxproj (already a StaticLibrary) Release|<Platform> against
     Windows SDK 10.0.22621.0 with whole-program optimisation off (so the .lib holds plain COFF
     objects that any linker of the same or newer MSVC can consume).
  3. Compiles static\module_static.cpp (the replacement for winrt\dll\module.cpp) with the same
     MSVC toolset and target, and packs it into win2dmod.lib.
  4. Stages winrt.lib, win2dmod.lib and BUILDINFO.txt into -OutDir.

  The MSVC toolset is pinned to the newest installed version that is not newer than -MaxMsvc
  (default 14.44), because consumers link with MSVC 14.44.x and a .lib compiled by a newer
  compiler can require a newer linker.

.EXAMPLE
  pwsh static\build-static.ps1 -Platform x64 -OutDir out\x64
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform = 'x64',
    [string]$OutDir,
    [string]$MaxMsvc = '14.44',
    [string]$SdkVersion = '10.0.22621.0',
    # Upstream Win2D commit this branch is based on (Win2D-WinUI 1.4.0). Update when rebasing.
    [string]$Win2DSourceSha = '25680382dd2136779e10ea6084f0c5ba437ae288',
    # Optional drive letter (e.g. 'W') to subst onto the repo root, to work around MAX_PATH
    # failures in winmdidl/abi.exe when the checkout path is long.
    [string]$SubstDrive,
    [switch]$SkipRestore
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutDir) { $OutDir = Join-Path $repo "static\out\$Platform" }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)

$substed = $false
if ($SubstDrive) {
    $drive = $SubstDrive.TrimEnd(':') + ':'
    subst $drive $repo
    if ($LASTEXITCODE -ne 0) { throw "subst $drive failed" }
    $substed = $true
    $repo = "$drive\"
}

function Invoke-Checked([string]$what, [scriptblock]$block) {
    Write-Host "==> $what"
    & $block
    if ($LASTEXITCODE -ne 0) { throw "$what failed with exit code $LASTEXITCODE" }
}

try {
    # ---- Visual Studio, MSVC toolset, Windows SDK ---------------------------------------------
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = & $vswhere -latest -products * -version '[17.0,18.0)' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'Visual Studio 2022 with the C++ x64 tools was not found.' }
    Write-Host "Visual Studio: $vs"

    $max = [version]$MaxMsvc
    $msvc = Get-ChildItem (Join-Path $vs 'VC\Tools\MSVC') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        ForEach-Object { [version]$_.Name } |
        Where-Object { [version]"$($_.Major).$($_.Minor)" -le $max } |
        Sort-Object -Descending | Select-Object -First 1
    if (-not $msvc) { throw "No MSVC toolset <= $MaxMsvc is installed under $vs." }
    $msvcVer = $msvc.ToString()
    $msvcShort = "$($msvc.Major).$($msvc.Minor)"
    $targetLib = Join-Path $vs "VC\Tools\MSVC\$msvcVer\lib\$($Platform.ToLower())"
    if (-not (Test-Path $targetLib)) { throw "MSVC $msvcVer has no $Platform libraries ($targetLib)." }
    Write-Host "MSVC toolset: $msvcVer"

    $sdkRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -Name KitsRoot10).KitsRoot10
    if (-not (Test-Path (Join-Path $sdkRoot "Include\$SdkVersion\um\windows.h"))) {
        throw "Windows SDK $SdkVersion is not installed under $sdkRoot."
    }
    if (-not (Test-Path (Join-Path $sdkRoot "Lib\$SdkVersion\um\$($Platform.ToLower())"))) {
        throw "Windows SDK $SdkVersion has no $Platform libraries."
    }
    Write-Host "Windows SDK: $SdkVersion ($sdkRoot)"

    $msbuild = Join-Path $vs 'MSBuild\Current\Bin\amd64\MSBuild.exe'
    $vcvarsall = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
    $vcArch = if ($Platform -eq 'x64') { 'x64' } else { 'x64_arm64' }

    # ---- Restore -------------------------------------------------------------------------------
    if (-not $SkipRestore) {
        $nuget = (Get-Command nuget.exe -ErrorAction SilentlyContinue).Source
        if (-not $nuget) {
            $nuget = Join-Path $env:TEMP 'nuget.exe'
            Invoke-WebRequest 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $nuget
        }
        Invoke-Checked 'nuget restore' {
            & $nuget restore (Join-Path $repo 'winrt\lib\packages.config') `
                -PackagesDirectory (Join-Path $repo 'packages') -ConfigFile (Join-Path $repo 'nuget.config') -NonInteractive
        }
    }

    # ---- winrt.lib -----------------------------------------------------------------------------
    $logDir = Join-Path $repo 'static\logs'
    New-Item -ItemType Directory -Force $logDir | Out-Null
    Invoke-Checked "MSBuild winrt.lib Release|$Platform" {
        & $msbuild (Join-Path $repo 'winrt\lib\winrt.lib.uap.vcxproj') /nologo /m /v:m `
            /p:Configuration=Release "/p:Platform=$Platform" `
            "/p:WindowsTargetPlatformVersion=$SdkVersion" `
            "/p:VCToolsVersion=$msvcVer" `
            /p:WholeProgramOptimization=false `
            "/flp:logfile=$logDir\winrt.lib-$Platform.log;verbosity=normal"
    }

    $winrtLib = Get-ChildItem (Join-Path $repo 'bin') -Recurse -Filter winrt.lib |
        Where-Object { $_.FullName -match "\\uap$($Platform.ToLower())\\release\\winrt\.lib\.uap\\" } |
        Select-Object -First 1
    if (-not $winrtLib) { throw "winrt.lib for $Platform not found under bin\." }
    $etwHeader = Get-ChildItem (Join-Path $repo 'obj\etw') -Recurse -Filter win2d.etw.h |
        Where-Object { $_.FullName -match "\\uap$($Platform.ToLower())\\release\\" } |
        Select-Object -First 1
    if (-not $etwHeader) { throw "win2d.etw.h for $Platform not found under obj\etw\." }

    # ---- win2dmod.lib (the shim) ---------------------------------------------------------------
    $shimObj = Join-Path $repo "static\obj\$Platform"
    New-Item -ItemType Directory -Force $shimObj | Out-Null
    $src = Join-Path $repo 'static\module_static.cpp'
    $clFlags = "/nologo /c /MT /O1 /EHsc /std:c++17 /GR- /Qspectre /guard:cf /W4 /WX /DNDEBUG /DUNICODE /D_UNICODE /DWINUI3"
    $cmd = "call `"$vcvarsall`" $vcArch $SdkVersion -vcvars_ver=$msvcVer >nul " +
           "&& cl $clFlags /I `"$($etwHeader.DirectoryName)`" /Fo`"$shimObj\module_static.obj`" `"$src`" " +
           "&& lib /nologo /out:`"$shimObj\win2dmod.lib`" `"$shimObj\module_static.obj`" " +
           "&& cl 2>&1 | findstr /C:`"Version`""
    Write-Host "==> win2dmod.lib ($vcArch, MSVC $msvcVer)"
    $clOut = cmd /d /c $cmd
    if ($LASTEXITCODE -ne 0) { $clOut | Write-Host; throw "win2dmod.lib build failed with exit code $LASTEXITCODE" }
    $clBanner = ($clOut | Where-Object { $_ -match 'Version' } | Select-Object -Last 1).Trim()
    Write-Host $clBanner

    # ---- Stage ---------------------------------------------------------------------------------
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    Copy-Item $winrtLib.FullName (Join-Path $OutDir 'winrt.lib') -Force
    Copy-Item "$shimObj\win2dmod.lib" (Join-Path $OutDir 'win2dmod.lib') -Force

    $branchSha = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { (git -C $repo rev-parse HEAD) }
    $image = if ($env:ImageOS) { "$env:ImageOS $env:ImageVersion" } else { 'local' }
    @(
        "Win2D static libraries ($Platform)"
        "Win2D source SHA:   $Win2DSourceSha (microsoft/Win2D winappsdk/main, Win2D-WinUI 1.4.0)"
        "Branch SHA:         $branchSha (pbk20191/Win2D static-lib)"
        "Platform:           $Platform (Release)"
        "MSVC toolset:       $msvcVer"
        "Compiler:           $clBanner"
        "Windows SDK:        $SdkVersion"
        "CRT model:          hybrid - /MT (MultiThreaded, LIBCMT/libcpmt), _ITERATOR_DEBUG_LEVEL=0; link ucrt.lib dynamically (/NODEFAULTLIB:libucrt.lib /DEFAULTLIB:ucrt.lib), as NativeAOT does"
        "WholeProgramOpt:    false"
        "Build date (UTC):   $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        "Runner image:       $image"
        "Files:              winrt.lib ($((Get-Item (Join-Path $OutDir 'winrt.lib')).Length) bytes), win2dmod.lib ($((Get-Item (Join-Path $OutDir 'win2dmod.lib')).Length) bytes)"
    ) | Set-Content -Encoding utf8 (Join-Path $OutDir 'BUILDINFO.txt')
    Get-Content (Join-Path $OutDir 'BUILDINFO.txt') | Write-Host
}
finally {
    if ($substed) { subst $drive /D | Out-Null }
}
