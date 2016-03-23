#!/bin/bash

# This script creates a "snapshot" backup of files in a Bitcoin datadir which 
# are likely to change when you run again.
#
# As most of the block data does not change, this allows the creation 
# of a relatively small backup which can be used to restore to a certain point 
# (by simply unpacking this backup and deleting any newer files).

# If the script does not encounter any errors, a timestamped backup archive is 
# deposited in the current working directory.

# EXIT CODE:
# 0 - backup was successfully created
# Any other return value signifies an error, and there should be output on stderr.

# LIMITATIONS:
# - does not check that disk space is sufficient to create the backup file
# - what about crossovers from one day to the next? timezones etc.
#   is the script safe?

# path to your Bitcoin datadir - adapt as necessary
DATADIR="$HOME"/.bitcoin

curdir=$(pwd)
pushd .

pgrep bitcoind > /dev/null && {
    echo "Error: bitcoind is running - shut it down before a backup operation!"
    exit 1
}

# create a temporary manifest file - will be filled with a list of files to backup
manifest=$(mktemp)
test -f $manifest || {
    echo "Error: could not create temporary file" >&2
    exit 1
}

# work in parent of datadir, so archival paths can simple be .bitcoin/*
cd "$DATADIR"/..

backup_date=$(date "+%Y%m%d_%H%M_%z")

# get list of files except debug logs, conf files and contents of blocks/ 
datadir_list_reduced=$(find .bitcoin/ | \
                       grep -v .bitcoin/blocks | \
                       egrep -v '(debug\.log|bitcoin\.conf|bitcoind\.pid|LOCK)' | \
                       grep -v '^\.bitcoin$')

# skip the LOCK files, we assume they'll be re-created as needed
index_reduced=$(find .bitcoin/blocks/index | grep -v LOCK)

parent_of_datadir=$(cd "$DATADIR"/.. ; pwd)
# only save the very last two modified files in blocks/
last_blockfiles=$(ls -1rt "$DATADIR"/blocks/{blk,rev}* | \
                  tail -2 | sed -e "s,${parent_of_datadir}/,,g")

# write the manifest
# 1. top level datadir files
echo $datadir_list_reduced | xargs -n 1 echo > $manifest

# the archived list, since it was filtered out above
echo $last_blockfiles | xargs -n 1 echo >> $manifest
# Note: manually adding contents of .bitcoin/blocks/index/ folder to 
echo $index_reduced | xargs -n 1 echo >> $manifest

backup_file=datadir_snapshot_${backup_date}.tar
tar -cvp --exclude=LOCK -T $manifest -f ${curdir}/${backup_file}
result=$?

# remove the listing file - all that information can be gleaned from the tarball
rm -f $manifest

popd 

if [ $result -eq 0 ]; then
    echo "$(date): created backup file $backup_file"
else
    echo "The tar command returned an error while creating the backup file." >&2
    rm -f ${curdir}/${backup_file}
    exit 1
fi

