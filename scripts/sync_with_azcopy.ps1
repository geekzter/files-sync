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
    [parameter(Mandatory=$false)][switch]$SkipLogin,
    [parameter(Mandatory=$false)][int]$SasTokenValidityDays=7
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

$logFile = Create-LogFile
$settings = Get-Settings -SettingsFile $SettingsFile -LogFile logFile

if (!(Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Output "Azure CLI not found, exiting" | Tee-Object -FilePath $LogFile -Append | Write-Warning
    exit
}
if (!$SkipLogin) {
    $tenantId = $settings.tenantId ?? $env:AZCOPY_TENANT_ID ?? $env:ARM_TENANT_ID
    if (!$tenantId) {
        # With Tenant ID we can retrieve other data with resource graph, without it we're toast
        Write-Output "Azure Active Directory Tenant ID not set, script cannot continue" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Warning
        exit
    }
    Login-Az -TenantId $tenantId -SkipAzCopy # Rely on SAS tokens for AzCopy
}

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
        $storageAccount = Get-StorageAccount $storageAccountName

        # Add firewall rule on storage account
        Open-Firewall -StorageAccountName $storageAccountName `
                      -ResourceGroupName $storageAccount.resourceGroup `
                      -SubscriptionId $storageAccount.subscriptionId

        # Generate SAS
        Write-Information "Generating SAS token for '$storageAccountName'..."
        $delete = ($AllowDelete -and ($directoryPair.delete -eq $true))
        $sasPermissions = "aclruw"
        if ($delete) {
            $sasPermissions += "d"
        }
        az storage account generate-sas --account-key $(az storage account keys list -n $storageAccountName -g $storageAccount.resourceGroup --subscription $storageAccount.subscriptionId --query "[0].value" -o tsv) `
                                        --expiry "$([DateTime]::UtcNow.AddDays($SasTokenValidityDays).ToString('s'))Z" `
                                        --id $storageAccount.id `
                                        --permissions $sasPermissions `
                                        --resource-types co `
                                        --services b `
                                        --start "$([DateTime]::UtcNow.AddDays(-30).ToString('s'))Z" `
                                        -o tsv | Set-Variable storageAccountToken
        $storageAccount | Add-Member -NotePropertyName Token -NotePropertyValue $storageAccountToken
        $storageAccounts.add($storageAccountName,$storageAccount)
        Write-Verbose "Generated SAS token for '$storageAccountName'"
    }

    # Data plane access
    foreach ($directoryPair in $settings.syncPairs) {
        if (-not ($directoryPair.target -match "https://(?<name>\w+)\.blob.core.windows.net/(?<container>\w+)/?[\w|/]*")) {
            Write-Output "Target '$Target' is not a storage URL, skipping" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Warning
            continue
        }
        $storageAccountName = $matches["name"]
        $storageAccount = Get-StorageAccount $storageAccountName

        # Start syncing
        $delete = ($AllowDelete -and ($directoryPair.delete -eq $true))
        $storageAccountToken = $storageAccounts[$storageAccountName].Token
        Sync-DirectoryToAzure -Source $directoryPair.source `
                              -Target $directoryPair.target `
                              -Token $storageAccountToken `
                              -Delete:$delete `
                              -DryRun:$DryRun `
                              -LogFile $logFile
    }
} catch {
    Write-Warning "Script ended prematurely"
} finally {
    # Close firewall (remove all rules)
    foreach ($storageAccount in $storageAccounts.Values) {
        Close-Firewall -StorageAccountName $storageAccount.name `
                       -ResourceGroupName $storageAccount.resourceGroup `
                       -SubscriptionId $storageAccount.subscriptionId        
    }

    Write-Host " "
    List-StoredWarnings
    Write-Host "Settings file used is located at: '$SettingsFile'"
    Write-Host "Script log file is located at: '$logFile'"
    Write-Host " "
}