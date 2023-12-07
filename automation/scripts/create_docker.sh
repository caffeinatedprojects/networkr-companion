#!/bin/bash

acc_user=$1  

sudo rm -rf ~/logs/$acc_user
mkdir -p ~/logs/$acc_user

touch ~/logs/$acc_user/create_docker_processing 

{

echo '--------- Script Start ---------' 

FILE=/home/$acc_user/.env

if sudo test -f "$FILE"; then
    sudo chown $acc_user:$acc_user $FILE
else
    echo "Environment file not found"
fi 
  
sudo make start --directory=/home/$acc_user

sleep 10

FILE=/home/$acc_user/data/site/wp-blog-header.php

if sudo test -f "$FILE"; then
    echo "docker created"
else
    echo "docker failed"
fi

echo '--------- Script END ---------'


} | tee -a ~/logs/$acc_user/create_docker_processing

sleep 1
mv ~/logs/$acc_user/create_docker_processing ~/logs/$acc_user/create_docker_done
exit 0