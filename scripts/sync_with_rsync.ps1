#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Syncs a pre-configured list of directory pairs
.DESCRIPTION 
    Update rsync-settings.jsonc os use the SYNC_SETTINGS_FILE environment variable to point to a settings file in an alternate location
#>
#Requires -Version 7
param ( 
    [parameter(Mandatory=$false)][string]$SettingsFile=$env:SYNC_SETTINGS_FILE ?? (Join-Path $PSScriptRoot rsync-settings.jsonc),
    [parameter(Mandatory=$false)][switch]$Delete=$false,
    [parameter(Mandatory=$false)][switch]$DryRun=$false
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

$logFile = (New-TemporaryFile).FullName

if (!$SettingsFile) {
    Write-Output "No settings file specified, exiting" | Tee-Object -FilePath $logFile -Append | Write-Warning
    exit
}
Write-Information "Using settings file '$SettingsFile'"
if (!(Test-Path $SettingsFile)) {
    Write-Output "Settings file '$SettingsFile' not found, exiting" | Tee-Object -FilePath $logFile -Append | Write-Warning
    exit
}
$settings = (Get-Content $SettingsFile | ConvertFrom-Json)
if (!$settings.syncPairs) {
    Write-Output "Settings file '$SettingsFile' does not contain any directory pairs to sync, exiting" | Tee-Object -FilePath $logFile -Append | Write-Warning
    exit
}

try {
    foreach ($directoryPair in $settings.syncPairs) {
        Sync-Directories -Source $directoryPair.source -Target $directoryPair.target -Delete:$($directoryPair.delete -eq $true) -DryRun:$DryRun -LogFile $logFile
    }
} finally {
    Write-Host " "
    List-StoredWarnings
    Write-Host "Log file: $logFile"
    Write-Host " "
}