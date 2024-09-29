#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Syncs a pre-configured list of directory and Azure storage account container pairs
.DESCRIPTION 
    Update azcopy-settings.jsonc or use the FILES_SYNC_AZCOPY_SETTINGS environment variable to point to a settings file in an alternate location
#>
#Requires -Version 7.2
param ( 
    [parameter(Mandatory=$false)][string]$SettingsFile=$env:FILES_SYNC_AZCOPY_SETTINGS ?? (Join-Path $PSScriptRoot azcopy-settings.jsonc),
    [parameter(Mandatory=$false)][switch]$AllowDelete,
    [parameter(Mandatory=$false)][switch]$DryRun,
    [parameter(Mandatory=$false,ParameterSetName="Sas",HelpMessage="Use SAS token instead of Azure RBAC")][switch]$UseSasToken=$false,
    [parameter(Mandatory=$false,ParameterSetName="Sas")][int]$SasTokenValidityDays=7,
    [parameter(Mandatory=$false)][int]$MaxMbps=0
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

$logFile = Create-LogFile
$settings = Get-Settings -SettingsFile $SettingsFile -LogFile $logFile

Validate-AzCli $logFile

$tenantId = $settings.tenantId ?? $env:AZCOPY_TENANT_ID
Login-Az -TenantId ([ref]$tenantID) -LogFile $logFile

try {
    # Create list of storage accounts
    Write-Verbose "Creating list of target storage account(s)"
    [System.Collections.ArrayList]$storageAccountNames = @()
    foreach ($directoryPair in $settings.syncPairs) {
        # Parse storage account info
        if ($directoryPair.source -match "https://(?<name>\w+)\.blob.core.windows.net/(?<container>\w+)/?[\w|/]*") {
            $storageAccountName = $matches["name"]
            if (!$storageAccountNames.Contains($storageAccountName)) {
                $storageAccountNames.Add($storageAccountName) | Out-Null
            }
        }
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
            Write-Output "Unable to retrieve resource id/group and subscription for '$storageAccountName' using Azure resource graph. Make sure you're logged into the right Azure Active Directory tenant (current: $tenantId). Exiting" | Tee-Object -FilePath $LogFile -Append | Write-Error -Category ResourceUnavailable
            exit
        }
        Write-Verbose "'$storageAccountName' has resource id '$($storageAccount.id)'"

        # Add firewall rule on storage account
        Open-Firewall -StorageAccountName $storageAccountName `
                      -ResourceGroupName $storageAccount.resourceGroup `
                      -SubscriptionId $storageAccount.subscriptionId

        # Generate SAS
        if ($UseSasToken) {
            $delete = ($AllowDelete -and ($directoryPair.delete -eq $true))
            $storageAccountToken = Create-SasToken -StorageAccountName $storageAccountName `
                                                   -ResourceGroupName $storageAccount.resourceGroup `
                                                   -SubscriptionId $storageAccount.subscriptionId `
                                                   -SasTokenValidityDays $SasTokenValidityDays `
                                                   -Write `
                                                   -Delete:$delete
            $storageAccount | Add-Member -NotePropertyName Token -NotePropertyValue $storageAccountToken    
        }
        $storageAccounts.add($storageAccountName,$storageAccount) | Out-Null
    }

    # Data plane access
    foreach ($directoryPair in $settings.syncPairs) {
        if ($directoryPair.target -notmatch "https://(?<name>\w+)\.blob.core.windows.net/(?<container>\w+)/?[\w|/]*") {
            Write-Output "Target '$Target' is not a storage URL, skipping" | Tee-Object -FilePath $logFile -Append | Add-Message -Passthru | Write-Warning
            continue
        }
        $targetStorageAccountName = $matches["name"]
        $targetStorageAccount = $storageAccounts[$targetStorageAccountName]

        # Start syncing
        $delete = ($AllowDelete -and ($directoryPair.delete -eq $true))

        if ($($directoryPair.source) -match "https://(?<name>\w+)\.blob.core.windows.net/(?<container>\w+)/?[\w|/]*") {
            # Source is a storage account
            $sourceStorageAccountName = $matches["name"]
            $sourceStorageAccount = $storageAccounts[$sourceStorageAccountName]
            Sync-AzureToAzure -Source $directoryPair.source `
                              -SourceToken ($UseSasToken ? $sourceStorageAccount.Token : $null) `
                              -Target $directoryPair.target `
                              -TargetToken ($UseSasToken ? $targetStorageAccount.Token : $null) `
                              -Delete:$delete `
                              -DryRun:$DryRun `
                              -LogFile $logFile
        } elseif (Test-Path $($directoryPair.source)) {
            # Source is a directory
            Sync-DirectoryToAzure -Source $directoryPair.source `
                                  -Target $directoryPair.target `
                                  -Token ($UseSasToken ? $targetStorageAccount.Token : $null) `
                                  -Delete:$delete `
                                  -DryRun:$DryRun `
                                  -MaxMbps $MaxMbps `
                                  -LogFile $logFile
        } else {
            Write-Output "Source '$($directoryPair.source)' does not exist, skipping" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Warning
            continue
        }
    }
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