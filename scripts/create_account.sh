#!/bin/bash 
 
## $1 : user_name
## $2 : user_pass
## $3 : website_id  

acc_user=$1 
acc_pass=$2 
website_id=$3   
 
if [ -f "/home/$acc_user" ]; then
    sudo userdel -r $acc_user
    sudo rm -rf /home/$acc_user/*
fi 

sudo adduser $acc_user --gecos "First Last,RoomNumber,WorkPhone,HomePhone" --disabled-password
echo $acc_user:$acc_pass | chpasswd 
# usermod -aG sudo $acc_user 
# sudo usermod -aG www-data $acc_user
# sudo chown -R $acc_user:www-data /home/$acc_user
# sudo chown -R www-data:www-data /home/$acc_user
# sudo chmod -R 774 /home/$acc_user  

echo '***** Created Hosting *******' 
echo 'created folders' 
sudo -u $acc_user -i --  mkdir -p /home/$acc_user/public_html 
sudo -u $acc_user -i --  cp -a /home/networkr/networkr-companion/template/. /home/$acc_user/ 


FILE=/home/$acc_user/docker-compose.yml

if test -f "$FILE"; then
    echo "hosting account created"
else
    echo "hosting creation failed"
fi

