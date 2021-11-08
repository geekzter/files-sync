function Get-Settings (
    [parameter(Mandatory=$true)][string]$SettingsFile,
    [parameter(Mandatory=$true)][string]$LogFile
) {
    if (!$SettingsFile) {
        Write-Output "No settings file specified, exiting" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    Write-Information "Using settings file '$SettingsFile'"
    if (!(Test-Path $SettingsFile)) {
        Write-Output "Settings file '$SettingsFile' not found, exiting" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    $settings = (Get-Content $SettingsFile | ConvertFrom-Json)
    if (!$settings.syncPairs) {
        Write-Output "Settings file '$SettingsFile' does not contain any directory pairs to sync, exiting" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }

    return $settings
}

function Get-StorageAccount (
    [parameter(Mandatory=$true)][string]$StorageAccountName
) {
    az graph query -q "resources | where type =~ 'microsoft.storage/storageaccounts' and name == '$StorageAccountName'" `
                   --query "data" `
                   -o json | ConvertFrom-Json | Set-Variable storageAccount
    # $storageAccount | Format-List | Write-Debug
    return $storageAccount
}

$script:messages = [System.Collections.ArrayList]@()
function List-StoredWarnings() {
    $script:messages | Write-Warning
}

function Open-Firewall (
    [parameter(Mandatory=$true)][string]$StorageAccountName,   
    [parameter(Mandatory=$true)][string]$ResourceGroupName,   
    [parameter(Mandatory=$true)][string]$SubscriptionId
) {
    # Add firewall rule on storage account
    $ipAddress=$(Invoke-RestMethod -Uri https://ipinfo.io/ip -MaximumRetryCount 9).Trim()
    Write-Debug "Public IP address is $ipAddress"
    Write-Verbose "Adding rule for Storage Account $StorageAccountName to allow ip address $ipAddress..."
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
        # TODO: Open browser at https://microsoft.com/devicelogin?
        if ($TenantId) {
            azcopy login --tenant-id $tenantId
        } else {
            azcopy login
        }
    }
}
function StoreAndWrite-Warning (
    [parameter(Mandatory=$true,ValueFromPipeline=$true)][string]$Message
) {
    $script:messages.Add($Message) | Out-Null
    Write-Warning $Message
}

function Sync-Directories (
    [parameter(Mandatory=$true)][string]$Source,   
    [parameter(Mandatory=$false)][string]$Pattern,   
    [parameter(Mandatory=$true)][string]$Target,   
    [parameter(Mandatory=$false)][switch]$Delete=$false,
    [parameter(Mandatory=$false)][switch]$DryRun,
    [parameter(Mandatory=$true)][string]$LogFile
) {
    if (!(Get-Command rsync -ErrorAction SilentlyContinue)) {
        Write-Output "rsync nog found, exiting" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    if (!(Get-Command bash -ErrorAction SilentlyContinue)) {
        Write-Output "This script uses bash to invoke rsync and bash was not found, exiting" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    
    if ($Source -notmatch '\*') {
        if (!(Get-ChildItem $Source -Force -ErrorAction SilentlyContinue)) {
            Write-Output "Source '$Source' does not exist, skipping" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
            return
        }
        $sourceExpanded = ((Resolve-Path $Source).Path + [IO.Path]::DirectorySeparatorChar)
    } else {
        $sourceExpanded = $Source
    }
    if ($sourceExpanded -match "\s") {
        $sourceExpanded = "'${sourceExpanded}'"
        Write-Debug "`$sourceExpanded: $sourceExpanded"
    }
    # Write-Verbose "Checking whether offline files exist in '$Source'..."
    # if (!$Pattern -and (Get-ChildItem -Path $Source -Include *.icloud -Recurse -Force -ErrorAction SilentlyContinue)) {
    #     Write-Output "Online iCloud files exist in '$Source' and will be ignored" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
    # }

    if (-not (Test-Path $Target)) {
        Write-Output "Target '$Target' does not exist, skipping" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
        return
    }
    $targetExpanded = (Resolve-Path $Target).Path 
    if ($targetExpanded -match "\s") {
        $targetExpanded = "'${targetExpanded}'"
    }
    
    $rsyncArgs = "-auvvz --modify-window=1 --exclude-from=$(Join-Path $PSScriptRoot exclude.txt)"
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

    $rsyncCommand = "rsync $rsyncArgs $sourceExpanded $targetExpanded"
    Write-Output "`nSync $sourceExpanded -> $targetExpanded" | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor Green
    Write-Output $rsyncCommand | Tee-Object -FilePath $LogFile -Append | Write-Debug
    bash -c "${rsyncCommand}" # Use bash to support certain wildcards e.g. .??*
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        switch ($exitCode) {
            23 {
                Write-Output "Status 23, you may not have sufficient permissions on ${sourceExpanded}" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
            }
        }
        Write-Output "'$rsyncCommand' exited with status $exitCode, exiting" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
        exit $exitCode
    }
    Write-Host " "
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
        Write-Output "azcopy nog found, exiting" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    if (-not (Test-Path $Source)) {
        Write-Output "Source '$Source' does not exist, skipping" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
        return
    }
    if ($Target -notmatch "https://\w+\.blob.core.windows.net/[\w|/]+") {
        Write-Output "Target '$Target' is not a storage URL, skipping" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
        return
    }
    # Write-Verbose "Checking whether offline files exist in '$Source'..."
    # if (Get-ChildItem -Path $Source -Include *.icloud -Recurse -Hidden) {
    #     Write-Output "Online iCloud files exist in '$Source' and will be ignored" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
    # }

    $excludePattern = (((Get-Content (Join-Path $PSScriptRoot exclude.txt) -Raw) -replace "`r","") -replace "`n","`;")
    $azcopyArgs = "--exclude-pattern=`"${excludePattern}`" --recursive"
    if ($Delete) {
        $azcopyArgs += " --delete-destination"
    }
    if ($DryRun) {
        $azcopyArgs += " --dry-run"
    }

    if ($Token) {
        $azCopyTarget = "${Target}?${Token}"
    } else {
        $azCopyTarget = $Target
    }
    $azcopyCommand = "azcopy sync '$Source' '$azCopyTarget' $azcopyArgs"
    Write-Output "`nSync '$Source' -> '$Target'" | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor Green
    Write-Output $azcopyCommand | Tee-Object -FilePath $LogFile -Append | Write-Debug
    Invoke-Expression $azcopyCommand #| Tee-Object -FilePath $LogFile -Append

    # Fetch Job ID, so we can find azcopy log and append it to the script log file
    $jobId = ((azcopy jobs list --output-type json | ConvertFrom-Json).MessageContent | ConvertFrom-Json -AsHashtable).JobIDDetails[0].JobId
    $jobLogFile = ((Join-Path $env:AZCOPY_LOG_LOCATION "${jobId}.log") -replace "\$([IO.Path]::DirectorySeparatorChar)+","\$([IO.Path]::DirectorySeparatorChar)")
    if (Test-Path $jobLogFile) {
        Get-Content $jobLogFile | Add-Content -Path $LogFile
    } else {
        Write-Output "Could not find azcopy log file '${jobLogFile}'" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
    }
    
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Output "'$azcopyCommand' exited with status $exitCode, exiting $($MyInvocation.MyCommand.Name)" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
        exit $exitCode
    }
    Write-Host " "
}