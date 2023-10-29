#!/bin/bash 
 
## $1 : user_name
## $2 : user_pass  

acc_user=$1 
acc_pass=$2    
 
#if [ -f "/home/$acc_user" ]; then
    sudo userdel -r $acc_user
    sudo rm -rf /home/$acc_user/*
#fi 

sudo adduser $acc_user --gecos "First Last,RoomNumber,WorkPhone,HomePhone" --disabled-password
echo $acc_user:$acc_pass | chpasswd  

sudo usermod -aG sudo $acc_user 

if getent passwd $acc_user > /dev/null 2>&1; then

    sudo mkdir /home/$acc_user/.ssh
    sudo touch /home/$acc_user/.ssh/authorized_keys 
    echo "the user exists"

else

    echo "the user does not exist"

fi