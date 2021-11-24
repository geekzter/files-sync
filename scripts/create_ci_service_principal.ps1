#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Creates a Service Principal for GitHub workflow
.DESCRIPTION 
    Creates a Service Principal with federated credentialss, so no Service Principal secrets have to maintained
#>
#Requires -Version 7.2
param ( 
    [parameter(Mandatory=$false)][string]$TenantId=$env:AZCOPY_TENANT_ID,
    [parameter(Mandatory=$false)][string]$SubscriptionId,
    [parameter(Mandatory=$false)][string]$ResourceGroup
) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)
$logFile = Create-LogFile

if (!(Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Output "$($PSStyle.Formatting.Error)Git not found, exiting$($PSStyle.Reset)" | Tee-Object -FilePath $LogFile -Append | Write-Warning
    exit
}

Push-location $PSScriptRoot

# Login to Azure CLI
Login-Az -Tenant ([ref]$TenantId) -SkipAzCopy -LogFile $logFile
if ($SubscriptionId) {
    az account set -s $SubscriptionId
} else {
    $SubscriptionId = $(az account show --query id -o tsv)
}

# Prepare federation subjects
$remoteRepoUrl = $(git config --get remote.origin.url)
if ($remoteRepoUrl -match "https://(?<host>[\w\.]+)/(?<repo>.+).git$") {
    $gitHost = $matches["host"]
    $repoName = $matches["repo"]
} else {
    Write-Warning "Could not determine repo name, exiting"
    exit
}
$currentBranch = $(git rev-parse --abbrev-ref HEAD)
$subjects = [System.Collections.ArrayList]@("repo:${repoName}:ref:refs/heads/main",`
            "repo:${repoName}:pull-request",`
            "repo:${repoName}:ref:refs/tags/azure"`
)
if ($currentBranch -ne "main") {
    $subjects.Add("repo:${repoName}:ref:refs/heads/${currentBranch}") | Out-Null
}

# Create Service Principal
$servicePrincipalName = "$($repoName -replace '/','-')-cicd"
$scope = "/subscriptions/${SubscriptionId}"
if ($ResourceGroup) {
    $scope += "/resourceGroups/${ResourceGroup}"
}
az ad sp create-for-rbac --name $servicePrincipalName `
                         --role Owner `
                         --scopes $scope | ConvertFrom-Json | Set-Variable servicePrincipal
$servicePrincipal | Format-List | Out-String | Write-Debug
$appId = $servicePrincipal.appId 
$appObjectId = $(az ad app show --id $appId --query objectId -o tsv)
Write-Debug "appId: $appId"
Write-Debug "appObjectId: $appObjectId"


$getUrl = "https://graph.microsoft.com/beta/applications/${appObjectId}/federatedIdentityCredentials"
Write-Debug "getUrl: $getUrl"
Write-information "Retrieving federations for application '${appObjectId}'..."
az rest --method GET `
        --headers '{\""Content-Type\"": \""application/json\""}' `
        --uri "$getUrl" `
        --body "@${requestBodyFile}" `
        --query "value[].subject" | ConvertFrom-Json | Set-Variable federatedSubjects

# Create federation subjects
foreach ($subject in $subjects) {
    if (!$federatedSubjects -or !$federatedSubjects.Contains($subject)) {
        $federationName = ($subject -replace ":|/","-")

        Get-Content (Join-Path $PSScriptRoot "federated-dentity-request-template.jsonc") | ConvertFrom-Json | Set-Variable request
        $request.name = $federationName
        $request.subject = $subject
        $request | Format-List | Out-String | Write-Debug

        # Pass JSON per file as per best practice 
        # https://github.com/Azure/azure-cli/blob/dev/doc/quoting-issues-with-powershell.md#double-quotes--are-lost
        $requestBodyFile = (New-TemporaryFile).FullName
        $request | ConvertTo-Json | Out-File $requestBodyFile
        Write-Debug "requestBodyFile: $requestBodyFile"

        $postUrl = "https://graph.microsoft.com/beta/applications/${appObjectId}/federatedIdentityCredentials"
        Write-Debug "postUrl: $postUrl"
        Write-Host "Adding federation for ${subject}..."
        az rest --method POST `
                --headers '{\""Content-Type\"": \""application/json\""}' `
                --uri "$postUrl" `
                --body "@${requestBodyFile}" | Set-Variable result
        if ($lastexitcode -ne 0) {
            Write-Error "Request to add subject '$subject' failed, exiting"
            exit
        }
    }
}
Write-Host "Created federation subjects for GitHub repo '${repoName}'"

if (Get-Command gh -ErrorAction SilentlyContinue) {
    Write-Host "Setting GitHub $repoName secrets ARM_CLIENT_ID, ARM_TENANT_ID & ARM_SUBSCRIPTION_ID..."
    gh auth login -h $gitHost
    Write-Debug "Setting GitHub workflow secret ARM_CLIENT_ID='$appId'..."
    gh secret set ARM_CLIENT_ID -b $appId --repo $repoName
    Write-Debug "Setting GitHub workflow secret ARM_TENANT_ID='$TenantId'..."
    gh secret set ARM_TENANT_ID -b $TenantId --repo $repoName
    Write-Debug "Setting GitHub workflow secret ARM_SUBSCRIPTION_ID='$SubscriptionId'..."
    gh secret set ARM_SUBSCRIPTION_ID -b $SubscriptionId --repo $repoName
} else {
    # Show workflow configuration information
    Write-Host "Set GitHub workflow secret ARM_CLIENT_ID='$appId' in $repoName"
    Write-Host "Set GitHub workflow secret ARM_TENANT_ID='$TenantId' in $repoName"
    Write-Host "Set GitHub workflow secret ARM_SUBSCRIPTION_ID='$SubscriptionId' in $repoName"
}