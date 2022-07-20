#!/bin/bash

# Confirm .env file exists
if [ -f .env ]; then

    # Create tmp clone
    cat .env > .env.tmp;

    # Subtitutions + fixes to .env.tmp2
    cat .env.tmp | sed -e '/^#/d;/^\s*$/d' -e "s/'/'\\\''/g" -e "s/=\(.*\)/='\1'/g" > .env.tmp2

    # Set the vars
    set -a; source .env.tmp2; set +a

    # Remove tmp files
    rm .env.tmp .env.tmp2

fi 

## $1 : user_name
## $2 : user_pass
## $3 : website_id  

acc_user=$1 
acc_pass=$2 
website_id=$3  

FILE=/home/$acc_user/docker-compose.yml

if test -f "$FILE"; then
    echo "hosting account created"
else
    echo "hosting creation failed"
fi

