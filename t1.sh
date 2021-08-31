proj="test1"
sproj_dir="/home/pronoor/$proj"
tproj_dir="/home/pronoor/gitdada/$proj"
usr="pronoor"
paswd="pronoor123"
trg_host="148.59.34.110"

#Coping repo to target
echo "Coping repo to target"
scp -r $sproj_dir $usr@$trg_host:$tproj_dir
st0=$?
if [ $st0 -eq 1 ]; then
        echo "Error whie coping repo to target. Exiting.."
        exit
fi

#moving repo to /var/www
echo "moving repo to /var/www"
ssh $usr@$trg_host "echo $paswd | sudo -S cp -r $tproj_dir /var/www/html"
st01=$?
if [ $st01 -eq 1 ]; then
	ssh $usr@$trg_host "rm -rf $tproj_dir"
        echo "Error while copy repo to public dir. Exiting.."
        exit 1
fi


#Restarting server
echo "Restarting server"
ssh $usr@$trg_host "echo $paswd| sudo -S sudo service apache2 restart"
st5=$?
if [ $st5 -eq 1 ]; then
	echo "Unable to restart server. Exiting..."
	exit 1
fi

echo "Deployed Successfully"

