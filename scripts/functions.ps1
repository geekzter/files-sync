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
    [parameter(Mandatory=$false)][switch]$DryRun=$true,
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

    $rsyncArgs = "-auvvz --modify-window=1 --exclude-from=$(Join-Path $PSScriptRoot rsync-exclude.txt)"
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