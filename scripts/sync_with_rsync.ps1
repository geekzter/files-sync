#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Syncs a pre-configured list of directory pairs
.DESCRIPTION 
    Update rsync-settings.jsonc or use the GEEKZTER_RSYNC_SETTINGS_FILE environment variable to point to a settings file in an alternate location
#>
#Requires -Version 7
param ( 
    [parameter(Mandatory=$false)][string]$SettingsFile=$env:GEEKZTER_RSYNC_SETTINGS_FILE ?? (Join-Path $PSScriptRoot rsync-settings.jsonc),
    [parameter(Mandatory=$false)][switch]$AllowDelete,
    [parameter(Mandatory=$false)][switch]$DryRun
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

$logFile = Create-LogFile
$settings = Get-Settings -SettingsFile $SettingsFile -LogFile logFile

try {
    foreach ($directoryPair in $settings.syncPairs) {
        $delete = ($AllowDelete -and ($directoryPair.delete -eq $true))
        Set-Variable -Name pattern -Value $directoryPair.pattern -ErrorAction SilentlyContinue
        Sync-Directories -Source $directoryPair.source -Pattern $pattern -Target $directoryPair.target -Delete:$delete -DryRun:$DryRun -LogFile $logFile
    }
} finally {
    Write-Host " "
    List-StoredWarnings
    Write-Host "Settings file used is located at: '$SettingsFile'"
    Write-Host "Script log file is located at: '$logFile'"
    Write-Host " "
}