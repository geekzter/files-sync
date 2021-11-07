#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Syncs a pre-configured list of directory pairs
.DESCRIPTION 
    Update rsync-settings.jsonc or use the SYNC_SETTINGS_FILE environment variable to point to a settings file in an alternate location
#>
#Requires -Version 7
param ( 
    [parameter(Mandatory=$false)][string]$SettingsFile=$env:GEEKZTER_RSYNC_SETTINGS_FILE ?? (Join-Path $PSScriptRoot rsync-settings.jsonc),
    [parameter(Mandatory=$false)][switch]$Delete=$false,
    [parameter(Mandatory=$false)][switch]$DryRun=$false
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

$logFile = (New-TemporaryFile).FullName
$settings = Get-Settings -SettingsFile $SettingsFile -LogFile logFile

try {
    foreach ($directoryPair in $settings.syncPairs) {
        Sync-DirectoryToAzure -Source $directoryPair.source -Target $directoryPair.target -Delete:$($directoryPair.delete -eq $true) -DryRun:$DryRun -LogFile $logFile
    }
} finally {
    Write-Host " "
    List-StoredWarnings
    Write-Host "Configuration file: '$SettingsFile'"
    Write-Host "Log file: '$logFile'"
    Write-Host " "
}