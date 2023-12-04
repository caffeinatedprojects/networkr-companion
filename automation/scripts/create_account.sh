#!/bin/bash 
 
## $1 : user_name
## $2 : user_pass
## $3 : website_id  

acc_user=$1 
acc_pass=$2 
website_id=$3   
 
#if [ -f "/home/$acc_user" ]; then
    sudo userdel -r $acc_user
    sudo rm -rf /home/$acc_user/*
#fi 

sudo adduser $acc_user --gecos "First Last,RoomNumber,WorkPhone,HomePhone" --disabled-password
echo $acc_user:$acc_pass | chpasswd  

echo '***** Created Hosting *******' 
echo 'created folders'  

sudo cp -a /home/networkr/networkr-companion/template/. /home/$acc_user/
sudo rsync --archive --chown=$acc_user:$acc_user /home/networkr/.ssh /home/$acc_user

sudo chown -R $acc_user:$acc_user /home/$acc_user/data/* 
sudo rm /home/$acc_user/.env-example 

FILE=/home/$acc_user/docker-compose.yml

if test -f "$FILE"; then
    echo "hosting account created"
else
    echo "hosting creation failed"
fi