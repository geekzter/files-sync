#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Creates a storage account prepared for sync
.DESCRIPTION 
    Creates a storage account configured with: soft delete, firewall opened only to client ip address, and the 'Data Contributor' role configured for currently logged on user/principal
#>
#Requires -Version 7.2
param ( 
    [parameter(Mandatory=$true)][string]$Name,
    [parameter(Mandatory=$true)][string]$ResourceGroup,
    [parameter(Mandatory=$false)][string]$Location=$env:AZURE_DEFAULTS_LOCATION,
    [parameter(Mandatory=$false)][string[]]$Container,
    [parameter(Mandatory=$false)][string]$SubscriptionId,
    [parameter(Mandatory=$false)][string]$TenantId=$env:AZCOPY_TENANT_ID,
    [parameter(Mandatory=$false)][int]$RetentionDays=30,
    [parameter(Mandatory=$false)][int]$MaxSasExpirationDays=30,
    [parameter(Mandatory=$false)][switch]$CreateServicePrincipal
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

$logFile = Create-LogFile

Validate-AzCli $logFile
Login-Az -TenantId ([ref]$TenantID) -LogFile $logFile -SkipAzCopy

$principal = (Get-LoggedInPrincipal)
$signedInObjectId = $principal.objectId
[System.Collections.ArrayList]$tags=@("application=files-sync","provisioner=azure-cli","provisoner-object-id=${signedInObjectId}")
if ($env:GITHUB_RUN_ID) {
    # Used in CI to clean up resources
    $tags.Add("run-id=${env:GITHUB_RUN_ID}")
}

# Create or update resource group
Write-Verbose "Creating resource group '$ResourceGroup'..."
az group create -n $Name -g $ResourceGroup -l $Location --subscription $SubscriptionId --tags $tags --query id -o tsv | Set-Variable resourceGroupId
Write-Host "Created/updated resource group $resourceGroupId"

# Assign ourselves data plane access
$role = "Storage Blob Data Contributor"
Write-Verbose "Assigning role '$role' on '$resourceGroupId' to '$signedInObjectId'..."
az role assignment create --role $role `
                          --assignee-object-id $signedInObjectId `
                          --assignee-principal-type $(az account show --query user.type -o tsv) `
                          -g $ResourceGroup --subscription $SubscriptionId `
                          -o none

# Create Service Principal
if ($CreateServicePrincipal) {
    $servicePrincipalName = "${Name}-azcopy"
    Write-Verbose "Creating/updating Service Principal '$servicePrincipalName'..."
    az ad sp create-for-rbac -n $servicePrincipalName `
                            --scopes $resourceGroupId `
                            --role $role `
                            -o json | ConvertFrom-Json | Set-Variable servicePrincipal
    Write-Host "Created/updated Service Principal '$($servicePrincipal.displayName)'"
    $servicePrincipal | Format-List
}

# Create or update Storage Account
Write-Verbose "Creating/updating storage account '$Name'..."
az storage account create -n $Name -g $ResourceGroup -l $Location --subscription $SubscriptionId `
                          --access-tier hot `
                          --allow-blob-public-access false `
                          --bypass AzureServices Logging Metrics `
                          --default-action Deny `
                          --https-only true `
                          --kind StorageV2 `
                          --public-network-access Enabled `
                          --sku Standard_RAGRS `
                          --tags $tags `
                          --query id -o tsv | Set-Variable storageAccountId
Write-Host "Created/updated storage account $storageAccountId"

Write-Verbose "Creating SAS expiration policy for '$Name' ($MaxSasExpirationDays days)"
az storage account update --name $Name `
                          --resource-group $ResourceGroup `
                          --sas-expiration-period "${MaxSasExpirationDays}.00:00:00" `
                          --subscription $SubscriptionId `
                          -o none
Write-Host "Created SAS expiration policy for '$Name' ($MaxSasExpirationDays days)"

# Enable soft delete
Write-Verbose "Enabling soft delete ($RetentionDays days) for storage account '$Name'..."
az storage account blob-service-properties update `
                          --enable-delete-retention true `
                          --delete-retention-days $RetentionDays `
                          --enable-container-delete-retention true `
                          --container-delete-retention-days $RetentionDays `
                          --account-name $Name `
                          --resource-group $ResourceGroup `
                          --subscription $SubscriptionId `
                          -o none

# Add firewall rule on storage account
Open-Firewall -StorageAccountName $Name -ResourceGroupName $ResourceGroup -SubscriptionId $SubscriptionId

# Create / update storage containers                          
foreach ($cont in $Container) {
    Write-Verbose "Creating/updating container '$cont' in storage account '$Name'..."
    az storage container create -n $cont `
                                --account-name $Name `
                                --auth-mode login `
                                --public-access off `
                                --resource-group $ResourceGroup `
                                --subscription $SubscriptionId `
                                -o none
    Write-Host "Created container '$cont' in storage account '$Name'..."
}

# Add resource lock
Write-Verbose "Locking access to '$Name' so it can't be deleted..."
az lock create --lock-type CanNotDelete `
               --name "${Name}-lock" `
               --resource $Name `
               --resource-type "Microsoft.Storage/storageAccounts" `
               -g $ResourceGroup `
               --subscription $SubscriptionId `
               -o none
Write-Host "Locked access to '$Name' so it can't be deleted"

# Get urls to storage containers
$blobBaseUrl = $(az storage account show -n $Name -g $ResourceGroup --subscription $SubscriptionId --query "primaryEndpoints.blob" -o tsv)
az storage container list --account-name $Name `
                          --auth-mode login `
                          --subscription $SubscriptionId `
                          --query "[].name" `
                          -o json | ConvertFrom-Json | Set-Variable existingContainers
if ($existingContainers) {
    Write-Host "`nStorage container URL's:"
}
foreach ($cont in $existingContainers) {
    Write-Host "${blobBaseUrl}${cont}"
}
