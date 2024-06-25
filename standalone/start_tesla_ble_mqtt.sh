#!/bin/bash

# Note: in case you get "permission denied" on docker commands: see: https://stackoverflow.com/questions/48957195/how-to-fix-docker-got-permission-denied-issue
# fill these values according to your settings #############
VIN_LIST=""
BLE_PRESENCE_DETECTION_TTL=300
MQTT_IP=127.0.0.1
MQTT_PORT=1883
MQTT_USER=""
MQTT_PWD=""
TESLA_CMD_RETRY_DELAY=5
DEBUG=false
############################################################


set -e
cd "$(dirname "$0")"

echo "Fetch addon files..."
mkdir tesla_ble_mqtt && cd tesla_ble_mqtt
git clone --ignore standalone/start_tesla_ble_mqtt.sh https://github.com/raphmur/tesla-local-control-addon
cd tesla-local-control-addon
mv standalone/docker-compose.yml .

echo "Making sure we have a clean start ..."
docker rm -f tesla_ble_mqtt
if [ ! -d /share/tesla_ble_mqtt ]
then
    mkdir /share/tesla_ble_mqtt
else
    echo "/share/tesla_ble_mqtt already exists, existing keys can be reused"
fi


echo "Create docker structure..."
docker volume create tesla_ble_mqtt

echo "Start main docker container with configuration Options:
  VIN_LIST=$VIN_LIST
  BLE_PRESENCE_DETECTION_TTL=$BLE_PRESENCE_DETECTION_TTL
  MQTT_IP=$MQTT_IP
  MQTT_PORT=$MQTT_PORT
  MQTT_USER=$MQTT_USER
  MQTT_PWD=Not Shown
  TESLA_CMD_RETRY_DELAY=$TESLA_CMD_RETRY_DELAY
  DEBUG=$DEBUG"

docker-compose up -d \
  -e TESLA_VIN=$TESLA_VIN \
  -e BLE_PRESENCE_DETECTION_TTL=$BLE_PRESENCE_DETECTION_TTL \
  -e MQTT_IP=$MQTT_IP \
  -e MQTT_PORT=$MQTT_PORT \
  -e MQTT_USER=$MQTT_USER \
  -e MQTT_PWD=$MQTT_PWD \
  -e TESLA_CMD_RETRY_DELAY=$TESLA_CMD_RETRY_DELAY \
  -e DEBUG=$DEBUG
