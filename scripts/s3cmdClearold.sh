#!/bin/bash

echo '--------- Script Start ---------' 

# Usage: bash s3cmdClearold.sh "caffeinated-media/site_backups/2020/" "7 days"
#  s3cmd ls caffeinated-media/site_backups/2020/

s3cmd ls --recursive s3://$1 | grep " DIR " -v | while read -r line;
  do
    createDate=`echo $line|awk {'print $1" "$2'}`
    createDate=$(date -d "$createDate" "+%s")
    olderThan=$(date -d "$2 ago" "+%s")
    if [[ $createDate -le $olderThan ]];
      then 
        fileName=`echo $line|awk {'print $4'}`
        if [ $fileName != "" ]
          then
            #printf 'Deleting "%s"\n' $fileName
            s3cmd del "$fileName"
        fi
    fi
  done;

echo '--------- Script END ---------'