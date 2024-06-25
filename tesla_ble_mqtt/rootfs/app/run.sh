#!/command/with-contenv bashio
#set -e


# read options in case of HA addon. Otherwise, they will be sent as environment variables
if [ -n "${HASSIO_TOKEN:-}" ]; then
  export BLE_PRESENCE_DETECTION_TTL="$(bashio::config 'ble_presence_detection_ttl')" \
         MQTT_IP="$(bashio::config 'mqtt_ip')" \
         MQTT_PORT="$(bashio::config 'mqtt_port')" \
         MQTT_USER="$(bashio::config 'mqtt_user')" \
         MQTT_PWD="$(bashio::config 'mqtt_pwd')" \
         TESLA_CMD_RETRY_DELAY="$(bashio::config 'tesla_cmd_retry_delay')" \
         VIN_LIST="$(bashio::config 'vin')" \
         DEBUG="$(bashio::config 'debug')"
else
  NOCOLOR='\033[0m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  YELLOW='\033[1;32m'
  MAGENTA='\033[0;35m'
  RED='\033[0;31m'

  function bashio::log.debug   { [ $DEBUG == "true" ] && echo -e "${NOCOLOR}$1"; }
  function bashio::log.info    { echo -e "${GREEN}$1${NOCOLOR}"; }
  function bashio::log.notice  { echo -e "${CYAN}$1${NOCOLOR}"; }
  function bashio::log.warning { echo -e "${YELLOW}$1${NOCOLOR}"; }
  function bashio::log.error   { echo -e "${MAGENTA}$1${NOCOLOR}"; }
  function bashio::log.fatal   { echo -e "${RED}$1${NOCOLOR}"; }
  function bashio::log.cyan    { echo -e "${CYAN}$1${NOCOLOR}"; }
  function bashio::log.green   { echo -e "${GREEN}$1${NOCOLOR}"; }
  function bashio::log.magenta { echo -e "${MAGENTA}$1${NOCOLOR}"; }
  function bashio::log.red     { echo -e "${RED}$1${NOCOLOR}"; }
  function bashio::log.yellow  { echo -e "${YELLOW}$1${NOCOLOR}"; }
fi

# Set log level to debug
bashio::config.true debug && bashio::log.level debug

bashio::log.cyan "tesla_ble_mqtt_docker by Iain Bullock 2024 https://github.com/iainbullock/tesla_ble_mqtt_docker"
bashio::log.cyan "Inspiration by Raphael Murray https://github.com/raphmur"
bashio::log.cyan "Instructions by Shankar Kumarasamy https://shankarkumarasamy.blog/2024/01/28/tesla-developer-api-guide-ble-key-pair-auth-and-vehicle-commands-part-3"

bashio::log.green "Configuration Options are:
  BLE_PRESENCE_DETECTION_TTL=$BLE_PRESENCE_DETECTION_TTL
  MQTT_IP=$MQTT_IP
  MQTT_PORT=$MQTT_PORT
  MQTT_USER=$MQTT_USER
  MQTT_PWD=Not Shown
  TESLA_CMD_RETRY_DELAY=$TESLA_CMD_RETRY_DELAY
  VIN_LIST=$VIN_LIST
  DEBUG=$DEBUG"

if [ ! -d /share/tesla_ble_mqtt ]
then
  bashio::log.info "Creating directory /share/tesla_ble_mqtt"
  mkdir /share/tesla_ble_mqtt
else
  bashio::log.debug "/share/tesla_ble_mqtt already exists, existing keys can be reused"
fi


# Generate list of BLE Local Name from a list of VIN separated with a space
vin_list_to_ble_local_name_list() {
  vin_list="$1"
  for vin in $vin_list; do
    ble_local_name_list+="S$(echo -n "$vin" | sha1sum | cut -c -16)C "
  done
  # remove last char (space)
  ble_local_name_list=${ble_local_name_list::-1}
  eval "$2='$ble_local_name_list'"
}


# BLE car presence detection loop
presence_detection_loop() {
  ble_local_name_regex="($(echo ble_local_name_list|sed -e 's/ /|/g'))"
  set +e
  while [ ! (/app/presence.ex "$ble_local_name_regex" "$vin_list" 2>&1 > /dev/null &) ]; do
    bashio.warning::log.warning "BLE car presence detection process failed"
    bashio.warning::log.notice "Restarting BLE car presence detection process in background in 5s"
    sleep 5s
  done
}


send_command() {
 for i in $(seq 5); do
  bashio::log.notice "Attempt $i/5 to send command"
  set +e
  tesla-control -ble -vin $TESLA_VIN -key-name /share/tesla_ble_mqtt/private.pem -key-file /share/tesla_ble_mqtt/private.pem $1
  EXIT_STATUS=$?
  set -e
  if [ $EXIT_STATUS -eq 0 ]; then
    bashio::log.info "tesla-control send command succeeded"
    break
  else
    bashio::log.error "tesla-control send command failed exit status $EXIT_STATUS. Retrying in $TESLA_CMD_RETRY_DELAY"
    sleep $TESLA_CMD_RETRY_DELAY
  fi
 done
}


send_key() {
 for i in $(seq 5); do
  bashio::log.notice "Attempt $i/5 to send public key"
  set +e
  tesla-control -ble -vin $TESLA_VIN add-key-request /share/tesla_ble_mqtt/public.pem owner cloud_key
  EXIT_STATUS=$?
  set -e
  if [ $EXIT_STATUS -eq 0 ]; then
    bashio::log.notice "KEY SENT TO VEHICLE: PLEASE CHECK YOU TESLA'S SCREEN AND ACCEPT WITH YOUR CARD"
    break
  else
    bashio::log.error "tesla-control could not send the pubkey; make sure the car is awake and sufficiently close to the bluetooth device. Retrying in $TESLA_CMD_RETRY_DELAY"
    sleep $TESLA_CMD_RETRY_DELAY
  fi
 done
}


# Call function to get BLE Local Name from a VIN list
vin_list_to_ble_local_name_list "$vin_list" ble_local_name_list
bashio::log.info "BLE Local Name list: $ble_local_name_list"


# Source files
bashio::log.notice "Source /app/listen_to_mqtt.sh"
. /app/listen_to_mqtt.sh
bashio::log.notice "Source /app/discovery.sh""
. /app/discovery.sh


# HA Auto-Discovery
bashio::log.info "Setup auto-discovery for Home Assistant"
setup_auto_discovery


# MQTT Discard messages
bashio::log.info "Connect to MQTT to discard any unread messages"
mosquitto_sub -E -i tesla_ble_mqtt -h $MQTT_IP -p $MQTT_PORT -u $MQTT_USER -P $MQTT_PWD -t tesla_ble/+


# If enable, start BLE car presence detection loop
if [ $BLE_PRESENCE_DETECTION_TTL > 0 ]; then
  bashio::log.info "Start BLE car presence detection loop process in background"
  presence_detection_loop &
fi


# Main MQTT Subscription Loop
bashio::log.info "Entering main listen to MQTT loop"
while : ; do
  listen_to_mqtt
  sleep 2
done
