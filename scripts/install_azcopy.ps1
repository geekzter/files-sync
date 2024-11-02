#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Installs AzCopy locally
.DESCRIPTION 
    Installs AzCopy locally in the bin subdirectory
.EXAMPLE
    ./install_azcopy.ps1 -Version 10.27
.EXAMPLE
    ./install_azcopy.ps1 -ExcludeVersion 10.25,10.26.0
#> 
[CmdLetBinding(DefaultParameterSetName="Specify")]
param ( 
    [parameter(Mandatory=$false,ParameterSetName="Specify")][string]$Version,
    [parameter(Mandatory=$false,ParameterSetName="Exclude")][string[]]$ExcludeVersion
) 

. (Join-Path $PSScriptRoot functions.ps1)

Join-Path $PSScriptRoot .. bin | Set-Variable binDirectory
New-Item $binDirectory -ItemType "directory" -Force | Write-Debug

$azCopy = (Get-Command azcopy -ErrorAction SilentlyContinue)
if ($azCopy -and ($azCopy.CommandType -ne "Alias")) {
    Write-Host "AzCopy already installed at $($azCopy.Path)"
    azcopy -v
}

$packageUrl = Get-AzCopyPackageUrl -Version $Version -ExcludeVersion $ExcludeVersion
$packageFile = $packageUrl | Split-Path -Leaf
$packagePath = Join-Path $binDirectory $packageFile
$localAzCopyFile = $IsWindows ? "azcopy.exe" : "azcopy"
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