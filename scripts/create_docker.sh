#!/bin/bashwhile IFS="" read -r p || [ -n "$p" ] 

acc_user=$1  

mkdir -p /home/$acc_user/logs
sudo rm -rf /home/$acc_user/logs/create_docker_processing
sudo rm -rf /home/$acc_user/logs/create_docker_done

touch /home/$acc_user/logs/create_docker_processing
exec &> /home/$acc_user/logs/create_docker_processing

echo '--------- Script Start ---------' 

FILE=/home/$acc_user/.env

if test -f "$FILE"; then
    sudo chown $acc_user:$acc_user $FILE
else
    echo "Environment file not found"
fi

# Confirm .env file exists
# if [ -f .env ]; then

#     # Create tmp clone
#     cat .env > .env.tmp;

#     # Subtitutions + fixes to .env.tmp2
#     cat .env.tmp | sed -e '/^#/d;/^\s*$/d' -e "s/'/'\\\''/g" -e "s/=\(.*\)/='\1'/g" > .env.tmp2

#     # Set the vars
#     set -a; source .env.tmp2; set +a

#     # Remove tmp files
#     rm .env.tmp .env.tmp2

# fi 
 
cd /home/$acc_user/
sudo make install

FILE=/home/$acc_user/data/site/wp-config.php

if test -f "$FILE"; then
    echo "wordpress site installed"
else
    echo "wordpress install failed"
fi

mv /home/$acc_user/logs/create_docker_processing /home/$acc_user/logs/create_docker__done

echo '--------- Script END ---------'

exit