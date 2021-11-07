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
    [parameter(Mandatory=$true)][string]$TenantId
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
        az login -t $TenantId -o none
    }

    # There's no way to check whether we have a session, always (re-)authenticate
    azcopy login --tenant-id $tenantId
}
function StoreAndWrite-Warning (
    [parameter(Mandatory=$true,ValueFromPipeline=$true)][string]$Message
) {
    $script:messages.Add($Message) | Out-Null
    Write-Warning $Message
}

function Sync-Directories (
    [parameter(Mandatory=$true)][string]$Source,   
    [parameter(Mandatory=$true)][string]$Target,   
    [parameter(Mandatory=$false)][switch]$Delete=$false,
    [parameter(Mandatory=$false)][switch]$DryRun,
    [parameter(Mandatory=$true)][string]$LogFile
) {

    if (!(Get-Command rsync -ErrorAction SilentlyContinue)) {
        Write-Output "rsync nog found, exiting" | Tee-Object -FilePath $LogFile -Append | Write-Warning
        exit
    }
    if (-not (Test-Path $Source)) {
        Write-Output "Source '$Source' does not exist, skipping" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
        return
    }
    if (-not (Test-Path $Target)) {
        Write-Output "Target '$Target' does not exist, skipping" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
        return
    }
    if (Get-ChildItem -Path $Source -Include *.icloud -Recurse -Hidden) {
        Write-Output "Online iCloud files exist in '$Source' and will be ignored" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
    }
    if (!$Source.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $Source += [IO.Path]::DirectorySeparatorChar # Tell rsync to treat source as directory
    }

    $rsyncArgs = "-auvvz --modify-window=1 --exclude-from=$(Join-Path $PSScriptRoot exclude.txt)"
    if ($Delete) {
        $rsyncArgs += " --delete"
    }
    if ($DryRun) {
        $rsyncArgs += " --dry-run"
    }
    if ($LogFile) {
        $rsyncArgs += " --log-file=$LogFile"
    }

    $rsyncCommand = "rsync $rsyncArgs `"$Source`" `"$Target`""
    Write-Output "`nSync '$Source' -> '$Target'" | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor Green
    Write-Output $rsyncCommand | Tee-Object -FilePath $LogFile -Append | Write-Debug
    Invoke-Expression $rsyncCommand
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Output "'$rsyncCommand' exited with status $exitCode, exiting $($MyInvocation.MyCommand.Name)" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
        exit $exitCode
    }
    Write-Host " "
}

function Sync-DirectoryToAzure (
    [parameter(Mandatory=$true)][string]$Source,   
    [parameter(Mandatory=$true)][string]$Target,   
    [parameter(Mandatory=$false)][switch]$Delete=$false,
    [parameter(Mandatory=$false)][switch]$DryRun,
    [parameter(Mandatory=$true)][string]$LogFile
) {
    # Redirect temporary files to the OS default location, if not already redirected
    $env:AZCOPY_LOG_LOCATION ??= $env:TEMP
    $env:AZCOPY_LOG_LOCATION ??= $env:TMP
    $env:AZCOPY_LOG_LOCATION ??= $env:TMPDIR

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
    if (Get-ChildItem -Path $Source -Include *.icloud -Recurse -Hidden) {
        Write-Output "Online iCloud files exist in '$Source' and will be ignored" | Tee-Object -FilePath $LogFile -Append | StoreAndWrite-Warning
    }

    $excludePattern = (((Get-Content (Join-Path $PSScriptRoot exclude.txt) -Raw) -replace "`r","") -replace "`n","`;")
    $azcopyArgs = "--exclude-pattern=`"${excludePattern}`" --recursive"
    if ($Delete) {
        $azcopyArgs += " --delete-destination"
    }
    if ($DryRun) {
        $azcopyArgs += " --dry-run"
    }

    $azcopyCommand = "azcopy sync `"$Source`" `"$Target`" $azcopyArgs"
    Write-Output "`nSync '$Source' -> '$Target'" | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor Green
    Write-Output $azcopyCommand | Tee-Object -FilePath $LogFile -Append | Write-Debug
    Invoke-Expression $azcopyCommand #| Tee-Object -FilePath $LogFile -Append

    # Fetch Job ID, so we can find azcopy log and append it to the script log file
    $jobId = ((azcopy jobs list --output-type json | ConvertFrom-Json).MessageContent | ConvertFrom-Json -AsHashtable).JobIDDetails[0].JobId
    $jobLogFile = (Join-Path $env:AZCOPY_LOG_LOCATION "${jobId}.log")
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