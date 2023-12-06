#!/bin/bash  

echo '----- Start Daily Back Up ----' 
date '+%d/%m/%Y_%H:%M:%S'  

OUTPUT_JSON=$(cat /home/networkr/data/users.json | jq '.backups') 
echo $OUTPUT_JSON

LENGTH_NAMES=$(echo $OUTPUT_JSON | jq length)

YEAR=$(date +%Y)
MONTH=$(date +%m) 

echo $(date +%Y)
echo $(date +%m) 

i=0
while [ $i -ne $LENGTH_NAMES ]
do

    echo "$i"
  
	NAME=$(echo $OUTPUT_JSON | jq ".[$i].name" | sed s'/\"//g')
	USER=$(echo $OUTPUT_JSON | jq ".[$i].username" | sed s'/\"//g')
	USERID=$(echo $OUTPUT_JSON | jq ".[$i].user_id" | sed s'/\"//g')
	SERVERID=$(echo $OUTPUT_JSON | jq ".[$i].server_id" | sed s'/\"//g')
	THEPATH=/home/$USER
	FILE='backup-'$(date '+%Y-%m-%d')'.tar.gz'
	ARCHIVE_FILE='backup-'$NAME'-'$(date '+%Y-%m-%d')'.tar.gz'
	
	echo '----------- Starting Back Up : ' $USER ' -----------'
	
	echo 'Name: ' $NAME

 	sudo make backup --directory=/home/$USER

	echo 'Moving to Storage: '$backup_file  

	sudo s3cmd put $THEPATH/data/backup/$FILE s3://caffeinated-media/pressillion/backups/$USERID/$YEAR/$MONTH/$SERVERID/$ARCHIVE_FILE
   
	sudo rm  -r -f $THEPATH/backup/* 

	echo '------------------------------'

	i=$(($i+1))

done 

echo '----- End Daily Backs Up ----'
date '+%d/%m/%Y_%H:%M:%S'
