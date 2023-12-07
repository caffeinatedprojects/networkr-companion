#!/bin/bash

acc_user=$1  

sudo rm -rf ~/logs/$acc_user/ 
mkdir -p ~/logs/$acc_user/

touch ~/logs/$acc_user/logs/check_wordpress_processing
#exec &> /home/$acc_user/logs/check_wordpress_processing

{

echo '--------- Script Start ---------' 

FILE=/home/$acc_user/.env

if sudo test -f "$FILE"; then
    echo "Environment found"
else
    echo "Environment file not found"
fi 
 
sudo make siteurl --directory=/home/$acc_user

echo '--------- Script END ---------'


} | tee -a ~/logs/$acc_user/check_wordpress_processing

sleep 1

mv ~/logs/$acc_user/check_wordpress_processing ~/logs/$acc_user/check_wordpress_done

exit 0