# File sync scripts for azcopy & rsync
This repo contains a number of scripts that act as wrappers around [azcopy](https://github.com/Azure/azure-storage-azcopy) and [rsync](https://github.com/WayneD/rsync). You can find them [here](./scripts).

The wrappers allow batch (i.e. multiple sync) operations to happen in sequence, and implement (additional) retries. They are implemented using PowerShell, with the batches configured as JSON files.

Why would you want to sync files to a redundant location? I f you're using a cloud storage solution such as DropBox, Google Drive, iCloud or OneDrive, your files are safe you'd assume. Well, yes and no. They protect you from any *hardware* problems you may have on the device you're syncing files from. That is, you still have an online copy of the files in case you lose a device due to a hardware issue or altogether.
However, they do not (or only in a limited way) protect you against *logical* errors. A logical error is that you accidentally delete files in a file (move) operation. Your deletes will be synced to the cloud and files will be removed (eventually) there as well. A classic example is overwriting a folder containing files with a folder with no files using the Finder on macOS. Once you confirm the overwrite, your original files have been deleted.
If you discover to late what happened, data can be lost forever.  
Last, there incidents have happened in the past were cloud providers did lose your data e.g. [Adobe Creative Cloud](https://www.dpreview.com/news/8563369544/lightroom-cc-update-for-ios-ipados-permanently-deletes-photos-and-presets-for-some-users).  

Hence this repo takes the approach of archiving files to a (remote) destination where they will remain.

## Sync with rsync
[rsync](https://github.com/WayneD/rsync) is a tool with a long history on Linux that is also preinstalled on macOS. The [sync_with_rsync.ps1](./scripts/sync_with_rsync.ps1) script takes a settings file with configured directory pairs and optional patterns and exclude list as argument. See example below:

```json
{
    "syncPairs" : [
        {
            "source": "~/Pictures/Lightroom/Photos",
            "target": "/Volumes/External/LightroomBackup/Photos"
        }
        
    ]
}
```

### Syncing
See adapt the sample [sample](./scripts/rsync-settings.jsonc) and pass its path as argument into [sync_with_rsync.ps1](./scripts/sync_with_rsync.ps1):
```powershell
sync_with_rsync.ps1 -SettingsFile /path/to/settings.json
```

## Sync with azcopy 
[azcopy](https://github.com/Azure/azure-storage-azcopy) is a tool that allows you to sync (among other things) a local directory to an Azure Storage Account. The [sync_with_azcopy.ps1](./scripts/sync_with_azcopy.ps1) script takes a settings file with configured directory pairs and optional patterns and exclude list as argument. See example below:
```json
{
    "tenantId" : "00000000-0000-0000-0000-000000000000",
    "syncPairs" : [
        {
            "source": "~/Pictures/Lightroom/Photos",
            "target": "https://mystorage.blob.core.windows.net/lightroom/photos"
        }
    ]
}
```

This settings file requires an Azure Active Directory tenant to be configured through the tenantId field. This will allow the script to 'find' storage accounts configured in the settings file using Azure Resource Graph. Alternatively, the `AZCOPY_TENANT_ID` environment variable or the `Tenant` argument can be used.

### Azure Storage Account(s)
You can work with pre-existing storage accounts, or you can use the [create_storage_account.ps1](./scripts/create_storage_account.ps1) script to create one with recommended settings: 
- Cross-region (RA-GRS) data replication
- Public access disabled
- Resource lock to prevent accidental deletion
- Soft delete enabled
- Storage Firewall enabled (sync will open and close it as needed)

```powershell
create_storage_account.ps1 -Name mystorage `
                           -ResourceGroup files-sync `
                           -Location westeurope `
                           -Container pictures, video
```

### Syncing with Azure Storage
See adapt the sample [sample](./scripts/azcopy-settings.jsonc) and pass its path as argument into [sync_with_azcopy.ps1](./scripts/sync_with_azcopy.ps1):
```powershell
sync_with_azcopy.ps1 -SettingsFile /path/to/settings.json
```