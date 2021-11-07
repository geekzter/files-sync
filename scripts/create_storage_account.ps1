#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Syncs a pre-configured list of directory pairs
.DESCRIPTION 
    Update rsync-settings.jsonc os use the SYNC_SETTINGS_FILE environment variable to point to a settings file in an alternate location
#>
#Requires -Version 7
param ( 
    [parameter(Mandatory=$true)][string]$Name,
    [parameter(Mandatory=$true)][string]$ResourceGroup,
    [parameter(Mandatory=$false)][string]$Location="westeurope",
    [parameter(Mandatory=$false)][string[]]$Container,
    [parameter(Mandatory=$false)][string]$SubscriptionId=$env:ARM_SUBSCRIPTION_ID,
    [parameter(Mandatory=$false)][int]$RetentionDays=30
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

if ($Subscription) {
    az account set -s $SubscriptionId
} else {
    $SubscriptionId=$(az account show --query id -o tsv)
}
Write-Information "Using subscription '$(az account list --query "[?id=='${SubscriptionId}'].name" -o tsv)'"

$signedInObjectId=$(az ad signed-in-user show --query objectId -o tsv)
$tags=@("application=files-sync","provisioner=azure-cli","provisoner-object-id=${signedInObjectId}")

# Create or update resource group
Write-Verbose "Creating resource group '$ResourceGroup'..."
az group create -n $Name -g $ResourceGroup -l $Location --subscription $SubscriptionId --tags $tags --query id -o tsv | Set-Variable resourceGroupId
Write-Information "Created/updated resource group $resourceGroupId"                        

# Assign ourselves data plane access
$role = "Storage Blob Data Contributor"
Write-Verbose "Assigning role '$role' on '$resourceGroupId' to '$signedInObjectId'..."
az role assignment create --role $role `
                          --assignee-object-id $signedInObjectId `
                          --assignee-principal-type $(az account show --query user.type -o tsv) `
                          -g $ResourceGroup --subscription $SubscriptionId `
                          -o none

# Create or update Storage Account
Write-Verbose "Creating storage account '$Name'..."
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
Write-Information "Created/updated storage account $storageAccountId"                        

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
    Write-Verbose "Creating container '$cont' in storage account '$Name'..."
    az storage container create -n $cont `
                                --account-name $Name `
                                --auth-mode login `
                                --public-access off `
                                --resource-group $ResourceGroup `
                                --subscription $SubscriptionId `
                                -o none
    Write-Information "Created container '$cont' in storage account '$Name'..."
}

# Get urls to storage containers
$blobBaseUrl = $(az storage account show -n $Name -g $ResourceGroup --subscription $SubscriptionId --query "primaryEndpoints.blob" -o tsv)
az storage container list --account-name $Name `
                          --auth-mode login `
                          --subscription $SubscriptionId `
                          --query "[].name" `
                          -o json | ConvertFrom-Json | Set-Variable existingContainers
Write-Host "`nStorage container URL's:"
foreach ($cont in $existingContainers) {
    Write-Host "${blobBaseUrl}${cont}"
}
