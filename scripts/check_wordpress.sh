#!/bin/bash

acc_user=$1  

sudo rm -rf /home/$acc_user/logs 
mkdir -p /home/$acc_user/logs

touch /home/$acc_user/logs/check_wordpress_processing
#exec &> /home/$acc_user/logs/check_wordpress_processing

{

echo '--------- Script Start ---------' 

FILE=/home/$acc_user/.env

if test -f "$FILE"; then
    sudo chown $acc_user:$acc_user $FILE
else
    echo "Environment file not found"s
fi 
 
cd /home/$acc_user/
sudo make siteurl 

echo '--------- Script END ---------'


} | tee -a /home/$acc_user/logs/check_wordpress_processing

sleep 1
mv /home/$acc_user/logs/check_wordpress_processing /home/$acc_user/logs/check_wordpress_done
exit 0