#!/bin/bash

# sudo bash /home/networkr/networkr-companion/automation/scripts/delete_hosting.sh liffick-stahler-meig1

acc_user=$1  

echo '--------- Script Start ---------' 

FILE=/home/$acc_user/.env

if test -f "$FILE"; then
    echo "Environment found"
else
    echo "Environment file not found"
fi 
 
sudo make down --directory=/home/$acc_user
sudo make clean --directory=/home/$acc_user
sudo deluser $acc_user  
sudo rm -rf /home/$acc_user 

FILE=/home/$acc_user/data/site/wp-config.php

if test -f "$FILE"; then
    echo "wordpress delete failed"
else
    echo "wordpress delete"
fi

echo '--------- Script END ---------' 
 
sleep 1
exit 0