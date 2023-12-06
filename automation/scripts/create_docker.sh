#!/bin/bash

acc_user=$1  

sudo rm -rf /home/$acc_user/logs 
mkdir -p /home/$acc_user/logs

touch /home/$acc_user/logs/create_docker_processing
#exec &> /home/$acc_user/logs/create_docker_processing

{

echo '--------- Script Start ---------' 

FILE=/home/$acc_user/.env

if test -f "$FILE"; then
    sudo chown $acc_user:$acc_user $FILE
else
    echo "Environment file not found"
fi 
  
sudo make start  --directory=/home/$acc_user

sleep 10

FILE=/home/$acc_user/data/site/wp-blog-header.php

if test -f "$FILE"; then
    echo "docker created"
else
    echo "docker failed"
fi

echo '--------- Script END ---------'


} | tee -a /home/$acc_user/logs/create_docker_processing

sleep 1
mv /home/$acc_user/logs/create_docker_processing /home/$acc_user/logs/create_docker_done
exit 0