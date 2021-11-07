#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Syncs a pre-configured list of directory and Azure storage account container pairs
.DESCRIPTION 
    Update rsync-settings.jsonc or use the SYNC_SETTINGS_FILE environment variable to point to a settings file in an alternate location
#>
#Requires -Version 7
param ( 
    [parameter(Mandatory=$false)][string]$SettingsFile=$env:GEEKZTER_AZCOPY_SETTINGS_FILE ?? (Join-Path $PSScriptRoot azcopy-settings.jsonc),
    [parameter(Mandatory=$false)][switch]$DryRun,
    [parameter(Mandatory=$false)][switch]$SkipLogin
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

$logFile = (New-TemporaryFile).FullName
$settings = Get-Settings -SettingsFile $SettingsFile -LogFile logFile

if (!$SkipLogin) {
    $tenantId = $settings.tenantId ?? $env:AZCOPY_TENANT_ID ?? $env:ARM_TENANT_ID
    if (!$tenantId) {
        # With Tenant ID we can retrieve other data with resource graph, without it we're toast
        Write-Output "Azure Active Directory Tenant ID not set, script cannot continue" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
        exit
    }
    Login-Az -TenantId $tenantId
}

try {
    foreach ($directoryPair in $settings.syncPairs) {
        # Get storage account info (subscription, resource group) with resource graph
        if (-not ($directoryPair.target -match "https://(?<name>\w+)\.blob.core.windows.net/[\w|/]+")) {
            Write-Output "Target '$Target' is not a storage URL, skipping" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
            continue
        }
        $storageAccountName = $matches["name"]
        $storageAccount = Get-StorageAccount $storageAccountName

        # Add firewall rule on storage account
        Open-Firewall -StorageAccountName $storageAccountName -ResourceGroupName $storageAccount.resourceGroup -SubscriptionId $storageAccount.subscriptionId

        # Start syncing
        Sync-DirectoryToAzure -Source $directoryPair.source -Target $directoryPair.target -Delete:$($directoryPair.delete -eq $true) -DryRun:$DryRun -LogFile $logFile
    }
} finally {
    Write-Host " "
    List-StoredWarnings
    Write-Host "Configuration file: '$SettingsFile'"
    Write-Host "Log file: '$logFile'"
    Write-Host " "
}