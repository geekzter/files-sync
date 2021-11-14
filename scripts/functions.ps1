# Back off, up to a point
$script:backOffSeconds = 0
function Calculate-BackOff () {
    if ($script:backOffSeconds -gt 0) {
        $script:backOffSeconds = (2 * $script:backOffSeconds)
    } else {
        $script:backOffSeconds = 1
    }
    if ($script:backOffSeconds -gt 3600) { # 1 hour
        $script:backOffSeconds = 3600
    }

    Write-Debug "Calculate-BackOff: $script:backOffSeconds"
}
function Continue-BackOff {
    return ($script:backOffSeconds -gt 0)
}
function Get-BackOff {
    Write-Debug "Get-BackOff: $script:backOffSeconds"
    return $script:backOffSeconds
}
function Reset-BackOff () {
    $script:backOffSeconds = 0
}
function Wait-BackOff () {
    if ($script:backOffSeconds -gt 0) {
        Write-Warning "Backing off and waiting $script:backOffSeconds seconds (until $((Get-Date).AddSeconds($script:backOffSeconds).ToString("HH:mm:ss")))..."
        Start-Sleep -Seconds $script:backOffSeconds
    }
}

# Firewall
function Open-Firewall (
    [parameter(Mandatory=$true)][string]$StorageAccountName,   
    [parameter(Mandatory=$true)][string]$ResourceGroupName,   
    [parameter(Mandatory=$true)][string]$SubscriptionId
) {
    # Add firewall rule on storage account
    Write-Host "Opening firewall on Storage Account '$StorageAccountName'..."

    $ipAddress=$(Invoke-RestMethod -Uri https://ipinfo.io/ip -MaximumRetryCount 9).Trim()
    Write-Debug "Public IP address is $ipAddress"
    Write-Verbose "Adding rule for Storage Account '$StorageAccountName' to allow ip address '$ipAddress'..."
    if (az storage account network-rule list -n $StorageAccountName -g $ResourceGroupName --subscription $SubscriptionId --query "ipRules[?ipAddressOrRange=='$ipAddress'&&action=='Allow']" -o tsv) {
        Write-Information "Firewall rule to allow '$ipAddress' already exists on storage account '$StorageAccountName'"
    } else {
        az storage account network-rule add --account-name $StorageAccountName `
                                            -g $ResourceGroupName `
                                            --ip-address $ipAddress `
                                            --subscription $SubscriptionId `
                                            -o none
        Write-Information "Added firewall rule to allow '$ipAddress' on storage account '$StorageAccountName'"
    }
}

function Close-Firewall (
    [parameter(Mandatory=$true)][string]$StorageAccountName,   
    [parameter(Mandatory=$true)][string]$ResourceGroupName,   
    [parameter(Mandatory=$true)][string]$SubscriptionId
) {
    # Add firewall rule on storage account
    Write-Host "Closing firewall on Storage Account '$StorageAccountName'..."
    az storage account network-rule list -n $StorageAccountName `
                                         -g $ResourceGroupName `
                                         --subscription $SubscriptionId `
                                         --query "ipRules" `
                                         -o json | ConvertFrom-Json | Set-Variable rules
    Write-Debug "`$rules: $rules"
    Write-Verbose "Enumerating firewall rules for Storage Account '$StorageAccountName'..."
    foreach ($rule in $rules) {
        az storage account network-rule remove -n $StorageAccountName `
                                               -g $ResourceGroupName `
                                               --subscription $SubscriptionId `
                                               --ip-address $rule.ipAddressOrRange `
                                               -o none
        Write-Verbose "Removed firewall rule to allow '$($rule.ipAddressOrRange)' from storage account '$StorageAccountName'"
    }
    Write-Information "Cleared firewall rules from storage account '$StorageAccountName'"
}

function Create-SasToken (
    [parameter(Mandatory=$true)][string]$StorageAccountName,   
    [parameter(Mandatory=$true)][string]$ResourceGroupName,   
    [parameter(Mandatory=$true)][string]$SubscriptionId,
    [parameter(Mandatory=$false)][switch]$Write,
    [parameter(Mandatory=$false)][switch]$Delete,
    [parameter(Mandatory=$true)][int]$SasTokenValidityDays
) {
    # Add firewall rule on storage account
    Write-Information "Generating SAS token for '$StorageAccountName'..."
    $sasPermissions = "lr"
    if ($Write) {
        $sasPermissions += "acuw"
    }
    if ($Delete) {
        $sasPermissions += "d"
    }
    az storage account generate-sas --account-key $(az storage account keys list -n $StorageAccountName -g $ResourceGroupName --subscription $SubscriptionId --query "[0].value" -o tsv) `
                                    --expiry "$([DateTime]::UtcNow.AddDays($SasTokenValidityDays).ToString('s'))Z" `
                                    --id $storageAccount.id `
                                    --permissions $sasPermissions `
                                    --resource-types co `
                                    --services b `
                                    --start "$([DateTime]::UtcNow.AddDays(-30).ToString('s'))Z" `
                                    -o tsv | Set-Variable storageAccountToken
    Write-Debug "storageAccountToken: $storageAccountToken"
    Write-Verbose "Generated SAS token for '$StorageAccountName'"
    return $storageAccountToken
}

# AzCopy
function Get-AzCopyLatestJobId () {
    # Fetch Job ID in a way that does not generare errors in case there is none
    azcopy jobs list --output-type json | ConvertFrom-Json `
                                        | Select-Object -ExpandProperty MessageContent `
                                        | ConvertFrom-Json -AsHashtable `
                                        | Select-Object -ExpandProperty JobIDDetails `
                                        | Select-Object -First 1 `
                                        | Select-Object -ExpandProperty JobId    
}

function Get-AzCopyJobStatus (
    [parameter(Mandatory=$true)][string]$JobId
) {
    # Determine job status in a way that does not generare errors in case there is none
    azcopy jobs show $jobId --output-type json | ConvertFrom-Json `
                                               | Select-Object -ExpandProperty MessageContent `
                                               | ConvertFrom-Json `
                                               | Select-Object -ExpandProperty JobStatus
}

function Get-AzCopyLogLevel () {
    if (($DebugPreference -inotmatch "SilentlyContinue|Ignore") -or ($VerbosePreference -inotmatch "SilentlyContinue|Ignore") -or ($InformationPreference -inotmatch "SilentlyContinue|Ignore")) {
        return "INFO"
    }
    if ($WarningPreference -inotmatch "SilentlyContinue|Ignore") {
        return "WARNING"
    }
    if ($ErrorActionPreference -inotmatch "SilentlyContinue|Ignore") {
        return "ERROR"
    }
    return "NONE"
}

function Get-StorageAccount (
    [parameter(Mandatory=$true)][string]$StorageAccountName
) {
    az graph query -q "resources | where type =~ 'microsoft.storage/storageaccounts' and name == '$StorageAccountName'" `
                   --query "data" `
                   -o json | ConvertFrom-Json | Set-Variable storageAccount
    return $storageAccount
}

function Login-Az (
    [parameter(Mandatory=$false)][string]$TenantId=$env:AZCOPY_TENANT_ID,
    [parameter(Mandatory=$false)][switch]$SkipAzCopy
) {
    # Are we logged into the wrong tenant?
    Invoke-Command -ScriptBlock {
        $Private:ErrorActionPreference = "Continue"
        if ($TenantId) {
            $script:loggedInTenantId = $(az account show --query tenantId -o tsv 2>$null)
        }
    }
    if ($loggedInTenantId -and ($loggedInTenantId -ine $TenantId)) {
        Write-Warning "Logged into tenant $loggedInTenantId instead of $TenantId (`$TenantId), logging off az session"
        az logout -o none
    }

    # Are we logged in?
    Invoke-Command -ScriptBlock {
        $Private:ErrorActionPreference = "Continue"
        # Test whether we are logged in
        $script:loginError = $(az account show -o none 2>&1)
        if (!$loginError) {
            $Script:userType = $(az account show --query "user.type" -o tsv)
            if ($userType -ieq "user") {
                # Test whether credentials have expired
                $Script:userError = $(az ad signed-in-user show -o none 2>&1)
            } 
        }
    }
    $login = ($loginError -or $userError)
    if ($login) {
        if ($TenantId) {
            az login -t $TenantId -o none
        } else {
            az login -o none
        }
    }

    $SkipAzCopy = ($SkipAzCopy -or (Get-Item env:AZCOPY_AUTO_LOGIN_TYPE -ErrorAction SilentlyContinue))
    if (!$SkipAzCopy) {
        # There's no way to check whether we have a session, always (re-)authenticate
        Start-Process "https://microsoft.com/devicelogin"
        if ($TenantId) {
            azcopy login --tenant-id $tenantId
        } else {
            azcopy login
        }
    }
}

function Sync-DirectoryToAzure (
    [parameter(Mandatory=$true)][string]$Source,   
    [parameter(Mandatory=$true)][string]$Target,   
    [parameter(Mandatory=$false)][string]$Token,   
    [parameter(Mandatory=$false)][switch]$Delete,
    [parameter(Mandatory=$false)][switch]$DryRun,
    [parameter(Mandatory=$true)][string]$LogFile
) {
    # Redirect temporary files to the OS default location, if not already redirected
    $tempDirectory = (($env:TEMP ?? $env:TMP ?? $env:TMPDIR) -replace "\$([IO.Path]::DirectorySeparatorChar)$","")
    $env:AZCOPY_LOG_LOCATION ??= $tempDirectory
    $env:AZCOPY_JOB_PLAN_LOCATION ??= $tempDirectory

    if (!(Get-Command azcopy -ErrorAction SilentlyContinue)) {
        Write-Output "$($PSStyle.Foreground.Red)azcopy not found, exiting$($PSStyle.Reset)" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    if (-not (Test-Path $Source)) {
        Write-Output "Source '$Source' does not exist, skipping" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Warning
        return
    }
    if ($Target -notmatch "https://\w+\.blob.core.windows.net/[\w|/]+") {
        Write-Output "Target '$Target' is not a storage URL, skipping" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Warning
        return
    }

    # Get latest Job ID, so we can detect whether a job was created later
    $previousJobId = Get-AzCopyLatestJobId

    $excludePattern = (((Get-Content (Join-Path $PSScriptRoot exclude.txt) -Raw) -replace "`r","") -replace "`n","`;")
    $azcopyArgs = "--exclude-pattern=`"${excludePattern}`" --recursive"
    if ($Delete) {
        $azcopyArgs += " --delete-destination"
    }
    if ($DryRun) {
        $azcopyArgs += " --dry-run"
    }
    $azcopyArgs += " --log-level $(Get-AzCopyLogLevel)"

    if ($Token) {
        $azCopyTarget = "${Target}?${Token}"
    } else {
        $azCopyTarget = $Target
    }
    $Source = (Resolve-Path $Source).Path
    $azcopyCommand = "azcopy sync '$Source' '$azCopyTarget' $azcopyArgs"

    $backOffMessage = "azcopy command '$azcopyCommand' did not execute (could not find azcopy job ID)"
    do {
        Wait-BackOff

        try {
            Write-Output "`n$($PSStyle.Bold)Starting$($PSStyle.Reset) to sync '$Source' -> '$Target'" | Tee-Object -FilePath $LogFile -Append | Write-Host
            Write-Output $azcopyCommand | Tee-Object -FilePath $LogFile -Append | Write-Debug
            try {
                # Use try / finally, so we can gracefully intercept Ctrl-C
                Invoke-Expression $azcopyCommand
            } finally {
                # Fetch Job ID, so we can find azcopy log and append it to the script log file
                $jobId = Get-AzCopyLatestJobId
                if ($jobId -and ($jobId -ne $previousJobId)) {
                    $jobLogFile = ((Join-Path $env:AZCOPY_LOG_LOCATION "${jobId}.log") -replace "\$([IO.Path]::DirectorySeparatorChar)+","\$([IO.Path]::DirectorySeparatorChar)")
                    if (Test-Path $jobLogFile) {
                        if (($WarningPreference -inotmatch "SilentlyContinue|Ignore") -or ($ErrorActionPreference -inotmatch "SilentlyContinue|Ignore")) {
                            Select-String -Pattern FAILED -CaseSensitive -Path $jobLogFile | Write-Warning
                        }
                        Get-Content $jobLogFile | Add-Content -Path $LogFile # Append job log to script log
                    } else {
                        Write-Output "Could not find azcopy log file '${jobLogFile}' for job '$jobId'" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Warning
                    }
                    # Determine job status
                    $jobStatus = Get-AzCopyJobStatus -JobId $jobId
                    if ($jobStatus -ieq "Completed") {
                        Reset-BackOff
                        Remove-Message $backOffMessage # Clear previous failures now we have been successful
                        Write-Output "$($PSStyle.Foreground.Green)$($PSStyle.Bold)Completed$($PSStyle.Reset) '$Source' -> '$Target'" | Tee-Object -FilePath $logFile -Append | Write-Host
                    } else {
                        Reset-BackOff # Back off will not help if azcopy completed unsuccessfully, the issue is most likely fatal
                        Remove-Message $backOffMessage # Back off message superseded by job result
                        Write-Output "$($PSStyle.Foreground.Red)$($PSStyle.Bold)$jobStatus$($PSStyle.Reset) '$Source' -> '$Target' (job '$jobId')" | Tee-Object -FilePath $logFile -Append | Add-Message -Passthru | Write-Warning
                    }
                } else {
                    Calculate-BackOff
                    Write-Output $backOffMessage | Tee-Object -FilePath $LogFile -Append | Add-Message
                    if (Get-BackOff -le 60) {
                        Write-Host $backOffMessage
                    } else {
                        Write-Warning $backOffMessage
                    }
                }
                
                $exitCode = $LASTEXITCODE
                if ($exitCode -ne 0) {
                    Write-Output "azcopy command '$azcopyCommand' exited with status $exitCode, exiting $($MyInvocation.MyCommand.Name)" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Error -ErrorId $exitCode
                    exit $exitCode
                }
                Write-Host " "
            }
        } catch {
            Write-Output $_ | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Error
            Calculate-BackOff
        }

    } while ($(Continue-BackOff))
}

# rsync
function Sync-Directories (
    [parameter(Mandatory=$true)][string]$Source,   
    [parameter(Mandatory=$false)][string]$Pattern,   
    [parameter(Mandatory=$true)][string]$Target,   
    [parameter(Mandatory=$false)][switch]$Delete=$false,
    [parameter(Mandatory=$false)][switch]$DryRun,
    [parameter(Mandatory=$true)][string]$LogFile
) {
    if (!(Get-Command rsync -ErrorAction SilentlyContinue)) {
        Write-Output "$($PSStyle.Foreground.Red)rsync not found, exiting$($PSStyle.Reset)" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    if (!(Get-Command bash -ErrorAction SilentlyContinue)) {
        Write-Output "$($PSStyle.Foreground.Red)This script uses bash to invoke rsync and bash was not found, exiting$($PSStyle.Reset)" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    
    if ($Source -notmatch '\*') {
        if (!(Get-ChildItem $Source -Force -ErrorAction SilentlyContinue)) {
            Write-Output "Source '$Source' does not exist, skipping" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Warning
            return
        }
        $sourceExpanded = ((Resolve-Path $Source).Path + [IO.Path]::DirectorySeparatorChar)
    } else {
        $sourceExpanded = $Source
    }

    if (-not (Test-Path $Target)) {
        Write-Output "Target '$Target' does not exist, skipping" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Warning
        return
    }
    $targetExpanded = (Resolve-Path $Target).Path 
    
    $rsyncArgs = "-auz --modify-window=1 --exclude-from=$(Join-Path $PSScriptRoot exclude.txt)"
    if ($Pattern) {
        $rsyncArgs += " --include=$Pattern --exclude=*"
    }
    if ($Delete) {
        $rsyncArgs += " --delete"
    }
    if ($DryRun) {
        $rsyncArgs += " --dry-run"
    }
    if ($LogFile) {
        $rsyncArgs += " --log-file=$LogFile"
    }
    if (($DebugPreference -inotmatch "SilentlyContinue|Ignore") -or ($VerbosePreference -inotmatch "SilentlyContinue|Ignore")) {
        $rsyncArgs += " -vv"
    } elseif ($InformationPreference -inotmatch "SilentlyContinue|Ignore") {
        $rsyncArgs += " -v"
    }

    $sourceExpression = $sourceExpanded -match "\s" ? "'$sourceExpanded'" : $sourceExpanded # Don't quote wildcards
    $rsyncCommand = "rsync $rsyncArgs $sourceExpression '$targetExpanded'"
    Write-Output "`n$($PSStyle.Bold)Starting$($PSStyle.Reset) to sync '$sourceExpanded' -> '$targetExpanded'" | Tee-Object -FilePath $LogFile -Append
    Write-Output $rsyncCommand | Tee-Object -FilePath $LogFile -Append | Write-Debug
    bash -c "${rsyncCommand}" # Use bash to support certain wildcards e.g. .??*
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        Write-Output "$($PSStyle.Foreground.Green)$($PSStyle.Bold)Completed$($PSStyle.Reset) '$sourceExpanded' -> '$targetExpanded'" | Tee-Object -FilePath $logFile -Append
    } else {
        switch ($exitCode) {
            23 {
                Write-Output "Not all files were synced. You may have insufficient permissions to sync all files in '${sourceExpanded}' (status $exitCode)" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Warning
            }
            default {
                Write-Output "'$rsyncCommand' exited with status $exitCode, exiting" | Tee-Object -FilePath $LogFile -Append | Add-Message -Passthru | Write-Error -ErrorId $exitCode
                exit $exitCode
            }
        }
    }
    Write-Host " "
}

# Utility
function Create-LogFile() {
    (New-TemporaryFile).FullName -replace "\w+$","log"
}

$script:messages = [System.Collections.ArrayList]@()
function List-StoredWarnings() {
    $script:messages | Get-Unique | Write-Warning
}

function Add-Message (
    [parameter(Mandatory=$true,ValueFromPipeline=$true)][string]$Message,
    [parameter(Mandatory=$false)][switch]$Passthru
) {
    # Strip tokens from message
    $storedMessage = $Message -replace "\?se.*\%3D",""
    $script:messages.Add($storedMessage) | Out-Null
    if ($Passthru) {
        Write-Output $Message
    }
}

function Get-Settings (
    [parameter(Mandatory=$true)][string]$SettingsFile,
    [parameter(Mandatory=$true)][string]$LogFile
) {
    if (!$SettingsFile) {
        Write-Output "$($PSStyle.Foreground.Red)No settings file specified, exiting$($PSStyle.Reset)" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    Write-Output "Using settings file '$SettingsFile'" | Tee-Object -FilePath $LogFile -Append | Write-Information
    if (!(Test-Path $SettingsFile)) {
        Write-Output "$($PSStyle.Foreground.Red)Settings file '$SettingsFile' not found, exiting$($PSStyle.Reset)" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    $settings = (Get-Content $SettingsFile | ConvertFrom-Json)
    if (!$settings.syncPairs) {
        Write-Output "$($PSStyle.Foreground.Red)Settings file '$SettingsFile' does not contain any directory pairs to sync, exiting$($PSStyle.Reset)" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }

    return $settings
}

function Remove-Message (
    [parameter(Mandatory=$true)][string]$Message
) {
    do {
        $lastIndexOfMessage = $script:messages.LastIndexOf($Message)
        if ($lastIndexOfMessage -ge 0) {
            $script:messages.RemoveAt($lastIndexOfMessage)
        }
    } while ($lastIndexOfMessage -ge 0)
}