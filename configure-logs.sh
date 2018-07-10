#!/bin/bash

NAME=$(curl http://169.254.169.254/latest/meta-data/instance-id)
# hostnamectl set-hostname $NAME
# echo '/bin/hostname $NAME' >> /etc/rc.local

echo '/bin/hostname $NAME'
sudo systemctl restart network

sudo service rsyslog restart