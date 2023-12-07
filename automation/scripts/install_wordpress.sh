#!/bin/bash

## $1 : acc_user
acc_user=$1  
 
mkdir -p ~/logs/$acc_user/

touch ~/logs/$acc_user/install_wordpress_processing
#exec &> /home/$acc_user/logs/install_wordpress_processing

{

echo '--------- Script Start ---------' 

FILE=/home/$acc_user/.env

if test -f "$FILE"; then
    echo "Environment found"
else
    echo "Environment file not found"
fi 
 
sudo make install --directory=/home/$acc_user

FILE=/home/$acc_user/data/site/wp-config.php

if test -f "$FILE"; then
    echo "wordpress site installed"
else
    echo "wordpress install failed"
fi

echo '--------- Script END ---------'


} | tee -a ~/logs/$acc_user/install_wordpress_processing

sleep 1
mv ~/logs/$acc_user/install_wordpress_processing ~/logs/$acc_user/install_wordpress_done
exit 0