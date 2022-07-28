#!/bin/bashwhile IFS="" read -r p || [ -n "$p" ] 

acc_user=$1  

mkdir -p /home/$acc_user/logs
sudo rm -rf /home/$acc_user/logs/create_docker_processing
sudo rm -rf /home/$acc_user/logs/create_docker__done

touch /home/$acc_user/logs/create_docker_processing
exec &> /home/$acc_user/logs/create_docker_processing

echo '--------- Script Start ---------' 

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

## $1 : user_name 

acc_user=$1

sudo docker-compose -f /home/$acc_user/docker-compose.yml up -d 

FILE=/home/$acc_user/docker-compose.yml

if test -f "$FILE"; then
    echo "hosting account created"
else
    echo "hosting creation failed"
fi

mv /home/$acc_user/logs/create_docker_processing /home/$acc_user/logs/create_docker__done

echo '--------- Script END ---------'

exit

