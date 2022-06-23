## $1 : domain_name  

echo '***** Delete Hosting *******' 

echo 'docker down' 
sudo docker-compose down -f /home/$1/docker-compose.yml 

echo 'delete user' 
sudo userdel $1

echo 'delete folders' 
sudo rm -rf /home/$1  
 
if [ ! -d "/home/$1 " ]; then
    echo 'website deleted: ' $1
else
    echo 'deletion failed: ' $1 
fi 