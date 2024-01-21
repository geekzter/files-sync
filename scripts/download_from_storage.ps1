#!/usr/bin/env pwsh
<#
.SYNOPSIS 
    Download from Azure storage account
#>
#Requires -Version 7.2
param ( 
    [parameter(Mandatory=$true)][string]$Source,
    [parameter(Mandatory=$true)][string]$Destination,
    [parameter(Mandatory=$false)][switch]$DryRun,
    [parameter(Mandatory=$false,ParameterSetName="Sas",HelpMessage="Use SAS token instead of Azure RBAC")][switch]$UseSasToken=$false,
    [parameter(Mandatory=$false,ParameterSetName="Sas")][int]$SasTokenValidityDays=7,
    [parameter(Mandatory=$false)][string]$TenantId=$env:AZCOPY_TENANT_ID) 

Write-Debug $MyInvocation.line

. (Join-Path $PSScriptRoot functions.ps1)

$logFile = Create-LogFile
$tempDirectory = (Get-TempDirectory) -replace "\$([IO.Path]::DirectorySeparatorChar)$",""
$env:AZCOPY_LOG_LOCATION ??= $tempDirectory
$env:AZCOPY_JOB_PLAN_LOCATION ??= $tempDirectory

if (-not (Test-Path $Destination)) {
    Write-Output "Destination '$Destination' does not exist, skipping" | Tee-Object -FilePath $logFile -Append | Add-Message -Passthru | Write-Warning
    return
}
if ($Source -match "https://(?<name>\w+)\.blob.core.windows.net/(?<container>\w+)/?[\w|/]*") {
    $storageAccountName = $matches["name"]
} else {
    Write-Output "'$Source' is not a valid storage url, skipping" | Tee-Object -FilePath $logFile -Append | Add-Message -Passthru | Write-Warning
}

# Control plane access
if (!(Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Output "$($PSStyle.Formatting.Error)Azure CLI not found, exiting$($PSStyle.Reset)" | Tee-Object -FilePath $LogFile -Append | Write-Warning
    exit
}
if (!(az extension list --query "[?name=='storage-preview'].version" -o tsv)) {
    Write-Host "Adding Azure CLI extension 'storage-preview'..."
    az extension add -n storage-preview -y
}
if (!$TenantId) {
    # With Tenant ID we can retrieve other data with resource graph, without it we're toast
    Write-Output "$($PSStyle.Formatting.Error)Azure Active Directory Tenant ID not set, which is required for Azure Resource Graph access. Script cannot continue$($PSStyle.Reset)" | Tee-Object -FilePath $LogFile -Append | Write-Warning
    exit
}
Login-Az -TenantId ([ref]$TenantID) -LogFile $logFile

$storageAccount = Get-StorageAccount $storageAccountName
if (!$storageAccount) {
    Write-Output "Unable to retrieve resource id/group and subscription for '$storageAccountName' using Azure resource graph. Make sure you're logged into the right Azure Active Directory tenant (current: $SourceTenantId). Exiting" | Tee-Object -FilePath $LogFile -Append | Write-Error -Category ResourceUnavailable
    exit
}
if ($UseSasToken) {
    $storageAccountToken = Create-SasToken -StorageAccountName $storageAccountName `
                                           -ResourceGroupName $storageAccount.resourceGroup `
                                           -SubscriptionId $storageAccount.subscriptionId `
                                           -SasTokenValidityDays $SasTokenValidityDays
}

# Add firewall rule on storage account
Open-Firewall -StorageAccountName $storageAccountName `
              -ResourceGroupName $storageAccount.resourceGroup `
              -SubscriptionId $storageAccount.subscriptionId

# Data plane access
$azcopyArgs = "--recursive --log-level $(Get-AzCopyLogLevel) --overwrite prompt"
if ($DryRun) {
    $azcopyArgs += " --dry-run"
}

$azCopySource = $UseSasToken ? "${Source}?${storageAccountToken}" : "${Source}"
$Destination = (Resolve-Path $Destination).Path
$previousJobId = Get-AzCopyLatestJobId # Get latest Job ID, so we can detect whether a job was created later
$azcopyCommand = "azcopy copy '$azCopySource' '$Destination' $azcopyArgs"
$backOffMessage = "azcopy command '$azcopyCommand' did not execute (could not find azcopy job ID)"
do {
    Wait-BackOff

    try {
        Write-Output "`n$($PSStyle.Bold)Downloading '$Source' -> '$Destination'$($PSStyle.Reset)" | Tee-Object -FilePath $logFile -Append | Write-Host -ForegroundColor Blue
        Write-Debug "AZCOPY_AUTO_LOGIN_TYPE: '${env:AZCOPY_AUTO_LOGIN_TYPE}'"
        Write-Output $azcopyCommand | Tee-Object -FilePath $logFile -Append | Write-Debug
        Invoke-Expression $azcopyCommand

        # Fetch Job ID, so we can find azcopy log and append it to the script log file
        $jobId = Get-AzCopyLatestJobId
        if ($jobId -and ($jobId -ne $previousJobId)) {
            $jobLogFile = ((Join-Path $env:AZCOPY_LOG_LOCATION "${jobId}.log") -replace "\$([IO.Path]::DirectorySeparatorChar)+","\$([IO.Path]::DirectorySeparatorChar)")
            if (Test-Path $jobLogFile) {
                if (($WarningPreference -inotmatch "SilentlyContinue|Ignore") -or ($ErrorActionPreference -inotmatch "SilentlyContinue|Ignore")) {
                    Select-String -Pattern FAILED -CaseSensitive -Path $jobLogFile | Write-Warning
                }
                Get-Content $jobLogFile | Add-Content -Path $logFile # Append job log to script log
            } else {
                Write-Output "Could not find azcopy log file '${jobLogFile}' for job '$jobId'" | Tee-Object -FilePath $logFile -Append | Add-Message -Passthru | Write-Warning
            }
            # Determine job status
            $jobStatus = Get-AzCopyJobStatus -JobId $jobId
            if ($jobStatus -ieq "Completed") {
                Reset-BackOff
                Remove-Message $backOffMessage # Clear previous failures now we have been successful
                Write-Output "$($PSStyle.Formatting.FormatAccent)Completed$($PSStyle.Reset) '$Source' -> '$Destination'" | Tee-Object -FilePath $logFile -Append | Write-Host
            } else {
                Write-Output "azcopy job '$jobId' status is '$($PSStyle.Formatting.Error)$jobStatus$($PSStyle.Reset)'" | Tee-Object -FilePath $logFile -Append | Add-Message -Passthru | Write-Warning
                Reset-BackOff # Back off will not help if azcopy completed unsuccessfully, the issue is most likely fatal
                Remove-Message $backOffMessage # Back off message superseeded by job result
            }
        } else {
            Calculate-BackOff
            Write-Output $backOffMessage | Tee-Object -FilePath $logFile -Append | Add-Message
            if (Get-BackOff -le 60) {
                Write-Host $backOffMessage
            } else {
                Write-Warning $backOffMessage
            }
        }
        
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-Output "azcopy command '$azcopyCommand' exited with status $exitCode, exiting $($MyInvocation.MyCommand.Name)" | Tee-Object -FilePath $logFile -Append | Add-Message -Passthru | Write-Error -ErrorId $exitCode
            exit $exitCode
        }
        Write-Host " "
    } catch {
        Calculate-BackOff
        if ($DebugPreference -ieq "Continue") {
            $_.Exception | Format-List -Force
            $_ | Format-List -Force
        }
        Write-Output "$_ $($_.ScriptStackTrace)" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Error
    }

} while ($(Continue-BackOff))
