#!/bin/bash

acc_user=$1  

sudo rm -rf /home/$acc_user/logs 
mkdir -p /home/$acc_user/logs

touch /home/$acc_user/logs/install_wordpress_processing
#exec &> /home/$acc_user/logs/install_wordpress_processing

{

echo '--------- Script Start ---------' 

FILE=/home/$acc_user/.env

if test -f "$FILE"; then
    echo "Environment found"
else
    echo "Environment file not found"
fi 
 
cd /home/$acc_user/
sudo make setup

FILE=/home/$acc_user/data/site/wp-config.php

if test -f "$FILE"; then
    echo "wordpress site installed"
else
    echo "wordpress install failed"
fi

echo '--------- Script END ---------'


} | tee -a /home/$acc_user/logs/install_wordpress_processing

sleep 1
mv /home/$acc_user/logs/install_wordpress_processing /home/$acc_user/logs/install_wordpress_done
exit 0