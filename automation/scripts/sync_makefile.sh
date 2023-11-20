#!/bin/bash  

echo '----- Start Sync Makefile ----' 
date '+%d/%m/%Y_%H:%M:%S'  

OUTPUT_JSON=$(cat /home/networkr/data/users.json | jq '.backups')

TEMPLATE_PATH="/home/networkr/networkr-companion/template"

echo $OUTPUT_JSON

LENGTH_NAMES=$(echo $OUTPUT_JSON | jq length)   

i=0

while [ $i -ne $LENGTH_NAMES ]
do

    echo "$i"
  
	NAME=$(echo $OUTPUT_JSON | jq ".[$i].name" | sed s'/\"//g')
	USER=$(echo $OUTPUT_JSON | jq ".[$i].username" | sed s'/\"//g') 
	USER_PATH=/home/$USER 
	
	echo '----------- Starting Back Up : ' $USER ' -----------'
	
	echo 'Name: ' $NAME 

	sudo mv $TEMPLATE_PATH/Makefile $USER_PATH/Makefile
	sudo chown $USER:$USER $USER_PATH/Makefile

	sudo mv $TEMPLATE_PATH/docker-compose.yml $USER_PATH/docker-compose.yml
	sudo chown $USER:$USER $USER_PATH/docker-compose.yml

	sudo mv $TEMPLATE_PATH/_config.yml $USER_PATH/_config.yml
	sudo chown $USER:$USER $USER_PATH/_config.yml
	
	sudo mv $TEMPLATE_PATH/conf.d/php.ini $USER_PATH/conf.d/php.ini
	sudo chown $USER:$USER $USER_PATH/conf.d/php.ini 

	echo '------------------------------'

	i=$(($i+1))

done 

echo '----- End Sync Makefile ----' 
date '+%d/%m/%Y_%H:%M:%S'
