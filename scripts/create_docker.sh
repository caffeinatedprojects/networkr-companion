#!/bin/bashwhile IFS="" read -r p || [ -n "$p" ] 

acc_user=$1  

mkdir -p /home/$acc_user/logs
sudo rm -rf /home/$acc_user/logs/create_docker_processing
sudo rm -rf /home/$acc_user/logs/create_docker_done

touch /home/$acc_user/logs/create_docker_processing
exec 1> >(tee -a "/home/$acc_user/logs/create_docker_processing")

echo '--------- Script Start ---------' 

FILE=/home/$acc_user/.env

if test -f "$FILE"; then
    sudo chown $acc_user:$acc_user $FILE
else
    echo "Environment file not found"
fi 
 
cd /home/$acc_user/
sudo make install

FILE=/home/$acc_user/data/site/wp-config.php

if test -f "$FILE"; then
    echo "wordpress site installed"
else
    echo "wordpress install failed"
fi

echo '--------- Script END ---------'


sleep 1
mv /home/$acc_user/logs/create_docker_processing /home/$acc_user/logs/create_docker_done
exit 0