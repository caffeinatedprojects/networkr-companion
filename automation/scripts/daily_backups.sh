#!/bin/bash 

mkdir -p ~/logs/backup

processing=`date +%Y-%m-%d_log_processing`
completed=`date +%Y-%m-%d_log_completed` 

touch ~/logs/backup/$processing
exec &> ~/logs/backup/$processing 

echo '----- Start Daily Back Up ----' 
date '+%d/%m/%Y_%H:%M:%S'  

OUTPUT_JSON=$(cat ~/data/users.json | jq '.backups') 
# echo $OUTPUT_JSON

# Get the length of the list:
LENGTH_NAMES=$(echo $OUTPUT_JSON | jq length)

# An array to store all names:
ARR_NAMES=()

YEAR=$(date +%Y)
MONTH=$(date +%m)  

# Iterate through to store the names:
for((i=0; i < $LENGTH_NAMES; ++i)); do

	# Extract the "name" and remove parenthesis:
	NAME=$(echo $OUTPUT_JSON | jq ".[$i].name" | sed s'/\"//g')
	USER=$(echo $OUTPUT_JSON | jq ".[$i].username" | sed s'/\"//g')
	USERID=$(echo $OUTPUT_JSON | jq ".[$i].user_id" | sed s'/\"//g')
	SERVERID=$(echo $OUTPUT_JSON | jq ".[$i].server_id" | sed s'/\"//g')
	PATH=/home/$USER
	FILE='backup-'$$(date '+%Y-%m-%d')'.tar.gz'
	
	echo '----------- Starting Back Up : ' $USER ' -----------'
	
	echo 'Name: ' $NAME

	cd $PATH

	sudo make backup

	echo 'Moving to Storage: '$backup_file  

	s3cmd put $PATH/data/backup/$FILE s3://caffeinated-media/pressillion/backups/USERID/$YEAR/$MONTH/SERVERID/$FILE
   
	rm  -r -f $PATH/backup/* 

	echo '------------------------------'

done 

echo '----- End Daily Backs Up ----'
date '+%d/%m/%Y_%H:%M:%S'

mv ~/logs/backup/$processing ~/logs/backup/$completed 
