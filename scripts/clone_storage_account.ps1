#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Clones a storage account created by create_storage_account.ps1
.DESCRIPTION 
    Creates a copy of a storage account, creates blob containers with the same names as the source, and syncs all blobs from the source storage account. As azcopy copies these files within Azure, speeds are very high (~ 10Gb/s for standard storage)
#>
#Requires -Version 7.2
param ( 
    [parameter(Mandatory=$true)][string]$SourceName,
    [parameter(Mandatory=$false)][string]$SourceTenantId=$env:AZCOPY_TENANT_ID,
    [parameter(Mandatory=$true)][string]$TargetName,
    [parameter(Mandatory=$false)][string]$TargetResourceGroup,
    [parameter(Mandatory=$false)][string]$TargetLocation,
    [parameter(Mandatory=$false)][string]$TargetSubscriptionId,
    [parameter(Mandatory=$false)][string]$TargetTenantId,
    [parameter(Mandatory=$false)][switch]$DryRun,
    [parameter(Mandatory=$false)][int]$RetentionDays=30,
    [parameter(Mandatory=$false,ParameterSetName="Sas",HelpMessage="Use SAS token instead of Azure RBAC")][switch]$UseSasToken=$false,
    [parameter(Mandatory=$false,ParameterSetName="Sas")][int]$SasTokenValidityDays=7,
    [parameter(Mandatory=$false)][switch]$SkipResourceLock
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

$logFile = Create-LogFile

Validate-AzCli $logFile
Write-Output "Logging into source tenant..." | Tee-Object -FilePath $LogFile -Append | Write-Host
Login-Az -TenantId ([ref]$SourceTenantId) -LogFile $logFile

# Retrieve storage account details using resource graph
$sourceStorageAccount = Get-StorageAccount $SourceName
if (!$sourceStorageAccount) {
    Write-Output "Unable to retrieve resource id/group and subscription for '$SourceName' using Azure resource graph. Make sure you're logged into the right Azure Active Directory tenant (current: $SourceTenantId). Exiting" | Tee-Object -FilePath $LogFile -Append | Write-Error -Category ResourceUnavailable
    exit
}
$sourceStorageAccount | Format-List | Tee-Object -FilePath $LogFile -Append | Write-Debug

# Add firewall rule on source storage account
Open-Firewall -StorageAccountName $SourceName `
              -ResourceGroupName $sourceStorageAccount.resourceGroup `
              -SubscriptionId $sourceStorageAccount.subscriptionId

# Retrieve list of containers
az storage container list --account-name $SourceName `
                          --auth-mode login `
                          --subscription $sourceStorageAccount.subscriptionId `
                          --query "[].name" `
                          -o json | ConvertFrom-Json | Set-Variable sourceContainers

# Prepare source data plane operations
$sourceBlobBaseUrl = $(az storage account show -n $SourceName -g $sourceStorageAccount.resourceGroup --subscription $sourceStorageAccount.subscriptionId --query "primaryEndpoints.blob" -o tsv)
if ($UseSasToken) {
    $sourceAccountToken = Create-SasToken -StorageAccountName $SourceName `
                                          -ResourceGroupName $sourceStorageAccount.resourceGroup `
                                          -SubscriptionId $sourceStorageAccount.subscriptionId `
                                          -SasTokenValidityDays $SasTokenValidityDays
}

# Fill in missing target parameters with source values as default
# ??= doesn't work for parameters in pwsh 7.2
if (!$TargetLocation) {
    $TargetLocation       = $sourceStorageAccount.location
}
if (!$TargetResourceGroup) {
    $TargetResourceGroup  = $sourceStorageAccount.resourceGroup
}
if (!$TargetSubscriptionId) {
    $TargetSubscriptionId = $sourceStorageAccount.subscriptionId
}
if (!$TargetTenantId) {
    $TargetTenantId       = $SourceTenantId
}
Write-Output "`$TargetLocation: $TargetLocation"             | Tee-Object -FilePath $LogFile -Append | Out-String | Write-Debug
Write-Output "`$TargetResourceGroup: $TargetResourceGroup"   | Tee-Object -FilePath $LogFile -Append | Out-String | Write-Debug
Write-Output "`$TargetSubscriptionId: $TargetSubscriptionId" | Tee-Object -FilePath $LogFile -Append | Out-String | Write-Debug
Write-Output "`$TargetTenantId: $TargetTenantId"             | Tee-Object -FilePath $LogFile -Append | Out-String | Write-Debug

# Prepare target control plane operations
Write-Output "Logging into target tenant..." | Tee-Object -FilePath $LogFile -Append | Write-Host
Login-Az -TenantId ([ref]$TargetTenantId) -LogFile $logFile

# Create / update target storage account
& (Join-Path $PSScriptRoot create_storage_account.ps1) -Name $TargetName `
                                                       -ResourceGroup $TargetResourceGroup `
                                                       -Location $TargetLocation `
                                                       -Container $sourceContainers `
                                                       -SubscriptionId $TargetSubscriptionId `
                                                       -TenantId $TargetTenantId `
                                                       -RetentionDays $RetentionDays `
                                                       -SkipResourceLock:$SkipResourceLock

# Add firewall rule on target storage account
Open-Firewall -StorageAccountName $TargetName `
              -ResourceGroupName $TargetResourceGroup `
              -SubscriptionId $TargetSubscriptionId

# Prepare target data plane operations
$targetBlobBaseUrl = $(az storage account show -n $TargetName -g $TargetResourceGroup --subscription $TargetSubscriptionId --query "primaryEndpoints.blob" -o tsv)
$targetAccountToken = Create-SasToken -StorageAccountName $TargetName `
                                      -ResourceGroupName $TargetResourceGroup `
                                      -SubscriptionId $TargetSubscriptionId `
                                      -SasTokenValidityDays $SasTokenValidityDays `
                                      -Write

# Data plane operations
foreach ($container in $sourceContainers) {
    Sync-AzureToAzure -Source "${sourceBlobBaseUrl}${container}/" `
                      -SourceToken $sourceAccountToken `
                      -Target "${targetBlobBaseUrl}${container}/" `
                      -TargetToken $targetAccountToken `
                      -Delete:$delete `
                      -DryRun:$DryRun `
                      -LogFile $logFile
}