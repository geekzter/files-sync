#!/bin/bash
# set -x

echo $(basename $0) "$@"

ALLOW_DELETE=0
DRY_RUN=0
FILES_SYNC_RSYNC_SETTINGS=${FILES_SYNC_RSYNC_SETTINGS:-$(dirname $0)/rsync-settings.json}
LOG_FILE=$(mktemp)
VERBOSE=0
while [ "$1" != "" ]; do
    case $1 in
        --allow-delete)                 ALLOW_DELETE=1
                                        ;;                                                                                                                
        --dry-run)                      DRY_RUN=1
                                        ;;
        --settings-file)                shift
                                        FILES_SYNC_RSYNC_SETTINGS=$1
                                        ;;
        --verbose)                      VERBOSE=1
                                        ;;
       * )                              echo "Invalid argument: $1"
                                        exit 1
    esac
    shift
done

echo "ALLOW_DELETE: $ALLOW_DELETE"
echo "DRY_RUN: $DRY_RUN"
echo "FILES_SYNC_RSYNC_SETTINGS: $FILES_SYNC_RSYNC_SETTINGS"

set -e
while read -r source target delete exclude; do
    echo "Do whatever with ${source} ${target} ${delete} ${exclude}"
    rsyncArgs="-auz --modify-window=1 --exclude-from=$(dirname $0)/exclude.txt"
    echo "$source -> $target" 
    rsyncArgs="$rsyncArgs $(echo $exclude | jq -r '.[]' | while read -r line; do echo -n " --exclude=$line"; done)"

    if [[ "$source" == *\** ]]; then
        sourceExpanded=$source
    else
        sourceExpanded=$(realpath $source)
    fi
    if [ $ALLOW_DELETE -eq 1 ] && [ "${delete}" = "1" ]; then
        rsyncArgs="$rsyncArgs --delete"
    fi
    if [ $DRY_RUN -eq 1 ]; then
        rsyncArgs="$rsyncArgs --dry-run"
    fi
    if [ $VERBOSE -eq 1 ]; then
        rsyncArgs="$rsyncArgs -vv"
    else
        rsyncArgs="$rsyncArgs -v"
    fi
    rsyncArgs="$rsyncArgs --log-file=${LOG_FILE}"
    targetExpanded=$(realpath $target) 
    rsyncCommand="rsync $rsyncArgs $sourceExpanded $targetExpanded"
    echo "rsyncCommand: $rsyncCommand"

    eval "${rsyncCommand}"
done< <(cat $FILES_SYNC_RSYNC_SETTINGS | jq --raw-output '.syncPairs[] | "\(.source) \(.target) \(.delete) \(.exclude)"')

echo "Log file: $LOG_FILE"