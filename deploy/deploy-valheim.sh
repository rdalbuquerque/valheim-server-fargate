#!/bin/bash

curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo apt install docker-compose -y

(crontab -l; echo "@reboot sudo docker-compose up -d") | crontab -

sudo docker-compose up -d


