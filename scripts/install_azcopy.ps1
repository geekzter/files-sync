#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Installs AzCopy locally
.DESCRIPTION 
    Installs AzCopy locally in the bin subdirectory
#> 
param ( 
    [parameter(Mandatory=$False)][string]$PackageUrl
) 

. (Join-Path $PSScriptRoot functions.ps1)

Join-Path $PSScriptRoot .. bin | Set-Variable binDirectory
New-Item $binDirectory -ItemType "directory" -Force | Write-Debug

$azCopy = (Get-Command azcopy -ErrorAction SilentlyContinue)
if ($azCopy) {
    Write-Host "AzCopy already installed at $($azCopy.Path)"
    azcopy -v
}

if ($IsWindows) {
    $packageUrl = [Environment]::Is64BitProcess ? "https://aka.ms/downloadazcopy-v10-windows" : "https://aka.ms/downloadazcopy-v10-windows-32bit"
    $packageFile = "azcopy.zip"
    $localAzCopyFile = "azcopy.exe"
}
if ($IsLinux) {
    if ($arch -in @("arm", "arm64")) {
        $packageUrl = "https://aka.ms/downloadazcopy-v10-linux-arm64"
    } elseif ($arch -eq "x86_64") {
        $packageUrl = "https://aka.ms/downloadazcopy-v10-linux"
    } else {
        Write-Warning "Unknown architecture '${arch}', defaulting to x64"
        $packageUrl = "https://aka.ms/downloadazcopy-v10-linux"
    }
    $packageFile = "azcopy.tar.gz"
    $localAzCopyFile = "azcopy"
}
if ($IsMacOS) {
    $packageUrl = ($PSVersionTable.OS -imatch "ARM64") ? "https://aka.ms/downloadazcopy-v10-mac-arm64" : "https://aka.ms/downloadazcopy-v10-mac"
    $packageFile = "azcopy.zip"
    $localAzCopyFile = "azcopy"
}
$packagePath = Join-Path $binDirectory $packageFile
$localAzCopyPath = Join-Path $binDirectory $localAzCopyFile

Write-Host "Retrieving package to '${packageUrl}' from '${packagePath}'..."
Invoke-Webrequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing

Write-Host "Extracting ${packagePath} to ${binDirectory}..."
if ($packageFile -match "\.zip$") {
    Expand-Archive -Path $packagePath `
                   -DestinationPath $binDirectory `
                   -Force `
                   -PassThru `
                   | Move-Item -Destination $binDirectory -Force -PassThru
                   | Write-Verbose
} elseif ($packageFile -match "\.tar\.gz$") {
    tar -xzf $packagePath --strip-components=1 -C $binDirectory
} else {
    Write-Error "Unknown package format for '${packageFile}'"
    exit
}

if (!$IsWindows) {
    chmod +x $localAzCopyPath
}

$azCopy = (Get-Command $localAzCopyPath -ErrorAction SilentlyContinue)
if ($azCopy) {
    . $localAzCopyPath -v
} else {
    Write-Error "AzCopy not installed, please check the logs"
    exit
}