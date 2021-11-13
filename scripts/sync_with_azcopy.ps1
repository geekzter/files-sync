#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Syncs a pre-configured list of directory and Azure storage account container pairs
.DESCRIPTION 
    Update azcopy-settings.jsonc or use the GEEKZTER_AZCOPY_SETTINGS_FILE environment variable to point to a settings file in an alternate location
#>
#Requires -Version 7
param ( 
    [parameter(Mandatory=$false)][string]$SettingsFile=$env:GEEKZTER_AZCOPY_SETTINGS_FILE ?? (Join-Path $PSScriptRoot azcopy-settings.jsonc),
    [parameter(Mandatory=$false)][switch]$AllowDelete,
    [parameter(Mandatory=$false)][switch]$DryRun,
    [parameter(Mandatory=$false)][int]$SasTokenValidityDays=7
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

$logFile = Create-LogFile
$settings = Get-Settings -SettingsFile $SettingsFile -LogFile logFile

if (!(Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Output "Azure CLI not found, exiting" | Tee-Object -FilePath $logFile -Append | Write-Error -Category ObjectNotFound
    exit
}
$tenantId = $settings.tenantId ?? $env:AZCOPY_TENANT_ID ?? $env:ARM_TENANT_ID
if (!$tenantId) {
    # With Tenant ID we can retrieve other data with resource graph, without it we're toast
    Write-Output "Azure Active Directory Tenant ID not set, script cannot continue" | Tee-Object -FilePath $logFile -Append | Add-Message -Passthru | Write-Error -Category InvalidData
    exit
}
Login-Az -TenantId $tenantId -SkipAzCopy # Rely on SAS tokens for AzCopy

try {
    # Create list of storage accounts
    Write-Verbose "Creating list of target storage account(s)"
    [System.Collections.ArrayList]$storageAccountNames = @()
    foreach ($directoryPair in $settings.syncPairs) {
        # Parse storage account info
        if ($directoryPair.target -match "https://(?<name>\w+)\.blob.core.windows.net/(?<container>\w+)/?[\w|/]*") {
            $storageAccountName = $matches["name"]
            if (!$storageAccountNames.Contains($storageAccountName)) {
                $storageAccountNames.Add($storageAccountName) | Out-Null
            }
        }
    }

    # Control plane access
    $storageAccounts = @{}
    foreach ($storageAccountName in $storageAccountNames) {
        # Get storage account info (subscription, resource group) with resource graph
        Write-Information "Retrieving resource id/group and subscription for '$storageAccountName' using Azure resource graph..."
        $storageAccount = Get-StorageAccount $storageAccountName
        if (!$storageAccount) {
            Write-Error -Category ResourceUnavailable `
                        -Message "Unable to retrieve resource id/group and subscription for '$storageAccountName' using Azure resource graph, exiting"
            exit
        }
        Write-Verbose "'$storageAccountName' has resource id '$($storageAccount.id)'"

        # Add firewall rule on storage account
        Open-Firewall -StorageAccountName $storageAccountName `
                      -ResourceGroupName $storageAccount.resourceGroup `
                      -SubscriptionId $storageAccount.subscriptionId

        # Generate SAS
        $delete = ($AllowDelete -and ($directoryPair.delete -eq $true))
        $storageAccountToken = Create-SasToken -StorageAccountName $storageAccountName `
                                               -ResourceGroupName $storageAccount.resourceGroup `
                                               -SubscriptionId $storageAccount.subscriptionId `
                                               -SasTokenValidityDays $SasTokenValidityDays `
                                               -Write `
                                               -Delete:$delete
        $storageAccount | Add-Member -NotePropertyName Token -NotePropertyValue $storageAccountToken
        $storageAccounts.add($storageAccountName,$storageAccount)
    }

    # Data plane access
    foreach ($directoryPair in $settings.syncPairs) {
        if (-not ($directoryPair.target -match "https://(?<name>\w+)\.blob.core.windows.net/(?<container>\w+)/?[\w|/]*")) {
            Write-Output "Target '$Target' is not a storage URL, skipping" | Tee-Object -FilePath $logFile -Append | Add-Message -Passthru | Write-Warning
            continue
        }
        $storageAccountName = $matches["name"]
        $storageAccount = $storageAccounts[$storageAccountName]

        # Start syncing
        $delete = ($AllowDelete -and ($directoryPair.delete -eq $true))
        Sync-DirectoryToAzure -Source $directoryPair.source `
                              -Target $directoryPair.target `
                              -Token $storageAccount.Token `
                              -Delete:$delete `
                              -Write `
                              -DryRun:$DryRun `
                              -LogFile $logFile
    }
} catch {
    Write-Warning "Script ended prematurely"
} finally {
    # Close firewall (remove all rules)
    if ($storageAccounts) {
        foreach ($storageAccount in $storageAccounts.Values) {
            Close-Firewall -StorageAccountName $storageAccount.name `
                        -ResourceGroupName $storageAccount.resourceGroup `
                        -SubscriptionId $storageAccount.subscriptionId        
        }
    }

    Write-Host " "
    List-StoredWarnings
    Write-Host "Settings file used is located at: '$SettingsFile'"
    Write-Host "Script log file is located at: '$logFile'"
    Write-Host " "
}