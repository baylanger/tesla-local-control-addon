#!/usr/bin/expect -re -f

# TODO / NOTES : TO BE REMOVED ONCE WE'RE HAPPY WITH THE IMPLEMENTATION
# - if the output matches a known fatal error, exit immediately w/ an error code:
#   Examples : a hci0 fatal error OR no hci is available, etc
#              # [bluetooth]# SetDiscoveryFilter failed: org.bluez.Error.NotReady
#              # [bluetooth]# Failed to start discovery: org.bluez.Error.NotReady
# - if the output matches a message that requires us to wait until the BLE device is available:
#    - wait ~60 seconds
#
# Check if after reboot the dongle's powerstate is On or Off

# Initialize variables for arguments
set mqtt_base_topic ""
set mqtt_hostname   ""
set mqtt_password   ""
set mqtt_port       1883
set mqtt_username   ""
set use_stdin       0

# Parse command-line arguments
for {set i 0} {$i < $argc} {incr i} {
    switch -- [lindex $argv $i] {
        "-mqtt_hostname" {
            incr i
            set mqtt_hostname [lindex $argv $i]
        }
        "-mqtt_port" {
            incr i
            set mqtt_port [lindex $argv $i]
        }
        "-mqtt_username" {
            incr i
            set mqtt_username [lindex $argv $i]
        }
        "-mqtt_password" {
            incr i
            set mqtt_password [lindex $argv $i]
        }
        "-mqtt_base_topic" {
            incr i
            set mqtt_topic [lindex $argv $i]
        }
        "-stdin" {
            set use_stdin 1
        }
        default {
            puts "Unknown option: [lindex $argv $i]"
            exit 1
        }
    }
}


# bluetooth prompt
set prompt #

# PID & FD of the spawned mosquitto_pub process
set mqtt_pub_pid 0
set mqtt_pub_fd 0

# Array to store MAC addresses with their associated expiration time (TTL)
array set mac_addrs_ttl {}

# ble_mac_addr_pattern can start if the vehicle(s)' BLE Local Name isn't in "bluetoothctl devices"
set ble_mac_addr_pattern ""

# Use command-line arguments if provided
lassign $argv vin_list ble_local_name_regex stdin

# OPTS is defined as environment variable of array type
#   array set OPTS {
#     vin_list                     ""
#     ble_presence_detection_ttl   ""
#     mqtt_server                  ""
#     mqtt_port                    ""
#     username                     ""
#     passwd                       ""
#     mqtt_topic                   ""
#     mqtt_pretopic                ""
#     mqtt_posttopic               ""
#     debug                        ""
#     log
#   }
# export exp_log_user 0
#

proc usage {code} {
  global OPTS
  puts [expr {$code ? "stderr" : "stdout"}] \
  "$::argv0 -mqtt_server ?options?
  -ble-presence-detection-ttl  vehicule presence time to live. Default 300 seconds; 0 disable detection.
  -debug                       enable debug
  -log                         bool 0|1 (display expect log info {[exp_log_user]})
  -help                        (print out this message)"
  -mqtt-port                   mqtt port. Defaults to 1883
  -mqtt-posttopic              mqtt posttopic to append after -mqtt-topic; Default nil
  -mqtt-pretopic               mqtt pretopic to append before -mqtt-topic; Default nil
  -mqtt-server                 mqtt host to connect to. Default localhost.
  -mqtt-topic                  mqtt topic to publish to; Default tesla_ble/........... TBD
  -mqtt-passwd                 provide a password; Default anonymous
  -mqtt-username               provide a username
  -vin-list                    single BLE Local Name or multiple "SabcdefghijklmnopC SponmlkjihgfedcbaC"
  exit $code
}

proc parseargs {argc argv} {
  global OPTS
  foreach {key val} $argv {
    switch -exact -- $key {
      "-ble-presence-ttl"  { set OPTS(ble_presence_detection_ttl)   $val }
      "-mqtt-passwd"       { set OPTS(mqtt_passwd)        $val }
      "-mqtt-port"         { set OPTS(mqtt_port)          $val }
      "-mqtt-posttopic"    { set OPTS(mqtt_posttopic)     $val }
      "-mqtt-pretopic"     { set OPTS(mqtt_pretopic)      $val }
      "-mqtt-server"       { set OPTS(mqtt_server)        $val }
      "-mqtt-topic"        { set OPTS(mqtt_topic)         $val }
      "-mqtt-username"     { set OPTS(mqtt_username)      $val }
      "-vin-regex"         { set OPTS(vin_regex)          $val }
      "-debug"             { exp OPTS(debug)              $val }
      "-log"               { exp_log_user                 $val }
      "-help"              { usage 0 }
    }
  }
}
#parseargs $argc $argv

## check arguments
#if {$OPTS(-mqtt_server) == "" || $OPTS(vins) == ""} {
#  usage 1
#}

# End user can pass
if { $argc < 2 } {
  set stdin ""
} else {
  puts "Option stdin: using stdin as input, will not spawn bluetoothclt"
}

# Scan Timeout
#if [info exists env(SCAN_TIMEOUT)] {
#  set scan_timeout $::env(SCAN_TIMEOUT)
#  puts "Option timeout: $scan_timeout seconds"
#else
#  set scan_timeout 0
#}

# Presence TTL
set ble_presence_detection_ttl $::env(BLE_PRESENCE_DETECTION_TTL)
puts "Option ble_presence_detection_ttl: $ble_presence_detection_ttl seconds"

# MQTT Hostname or IP
set mqtt_ip $::env(MQTT_IP)
puts "Option mqtt_sip: $mqtt_ip"

# MQTT Port
set mqtt_port $::env(MQTT_PORT)
puts "Option mqtt_port: $mqtt_port"

# MQTT Username
set mqtt_username $::env(MQTT_USER)
puts "Option mqtt_username: $mqtt_username"

# MQTT Password
set mqtt_password $::env(MQTT_PWD)
puts "Option mqtt_password: ***************"

# MQTT Protocol
#set protocol $::env(MQTT_PROTOCOL)
#puts "Option protocol: $protocol"

# MQTT topic
set mqtt_topic $::env(MQTT_TOPIC)
puts "Option mqtt_topic: $mqtt_topic"


# TEMPORARY
set vins [split $vin_list ]
set vin_1 [lindex $vins 0]
set mqtt_topic "tesla_ble/binary_sensor/presence/$vin_1"


# If not present, add MAC addr to regex pattern
proc mac_addr_regex_ops {ble_mac_addr_regex ble_mac_addr} {

  # if empty, add ble_mac_addr with no pipe
  if { $ble_mac_addr_regex == "" } {
    set ble_mac_addr_regex "$ble_mac_addr"
  } elseif { ![regexp $ble_mac_addr $ble_mac_addr_regex] } {
    # If ble_mac_addr is not present, append with pipe
    append ble_mac_addr_regex "|$ble_mac_addr"
  }
  puts "ble_mac_addr_regex: $ble_mac_addr_regex"

  return $ble_mac_addr_regex

}


# add or update a MAC address with its TTL
proc add_or_update_mac_addr_ttl {mac_addr ttl_seconds} {
  global mac_addrs_ttl
  global mqtt_server mqtt_port mqtt_username mqtt_password mqtt_topic

  # Get the current time in seconds since the epoch
  set current_time [clock seconds]

  # Calculate the expiration time
  set expiration_time [expr {$current_time + $ttl_seconds}]

  # If the mac_addr is not present or entry is expired, publish to MQTT value ON
  if { [is_mac_addr_expired $mac_addr] } {
    # Publish a message
    puts "MQTT publish value ON for topic: $mqtt_topic"
    mosquitto_publish $mqtt_server $mqtt_port $mqtt_username $mqtt_password $mqtt_topic "ON"
  }

  # Update the MAC address with the new expiration time
  set mac_addrs_ttl($mac_addr) $expiration_time
}


# Function to check if a MAC address has expired
proc is_mac_addr_expired {mac_addr} {
  global mac_addrs_ttl

  # Get the current time in seconds since the epoch
  set current_time [clock seconds]

  # Check if the MAC address exists
  if {[info exists mac_addrs_ttl($mac_addr)]} {
    # Get the expiration time for the MAC address
    set expiration_time $mac_addrs_ttl($mac_addr)

    # Check if the current time is past the expiration time
    if {$current_time > $expiration_time} {
      puts "MAC address $mac_addr has expired!"
      return 1 ;# MAC address has expired
    } else {
      puts "MAC address $mac_addr is still valid!"
      return 0 ;# MAC address is still valid
    }
  } else {
    puts "MAC address $mac_addr not part of the current list!"
    return 2 ;# MAC address does not exist, so it's considered expired
  }
}


# Function to start the mosquitto_pub process
proc mosquitto_pub_spawn {server port username password} {
    global mqtt_pub_pid mqtt_pub_fd

    # Close previous file descriptor if open
    if {[info exists mqtt_pub_fd] && $mqtt_pub_fd != 0} {
        catch {close $mqtt_pub_fd}
    }

    # Determine if we need to use authentication
    set auth_options ""
    if {$username != "" && $password != ""} {
        append auth_options " -u $username -P $password"
    }

    # Command to run mosquitto_pub with necessary options
    set cmd "mosquitto_pub --nodelay -h $server -p $port$auth_options -t '' -l"

    # Open a pipe to the mosquitto_pub process
    set mqtt_pub_fd [open "|$cmd" "w"]

    # Get the process ID of the mosquitto_pub process
    set mqtt_pub_pid [pid $mqtt_pub_fd]
}


# Publish a message to a topic
proc mosquitto_publish {server port username password topic value} {
  global mqtt_pub_pid mqtt_pub_fd

  # Check if mosquitto_pub process is running
  if {![info exists mqtt_pub_pid] || $mqtt_pub_pid == 0 || [catch {exec ps $mqtt_pub_pid}]} {
    # Start the mosquitto_pub process if not running
  puts "mosquitto_publish restarting mosquitto_pub"
    mosquitto_pub_spawn $server $port $username $password
  }

  # Publish the message by sending it to the stdin of the mosquitto_pub process
  puts "MQTT publish to mqtt_pub_pid=$mqtt_pub_pid $topic $value"
  puts $mqtt_pub_fd "$topic $value"
  flush $mqtt_pub_fd
}


# Function to publish a message to MQTT topic
proc mosquitto_publish_command {server port username password topic value} {

  # Define the mosquitto_pub command with arguments
  set command "mosquitto_pub --nodelay -h $server -p $port -u $username -P $password -t $topic -m $value"

  # Spawn the mosquitto_pub process
  spawn {*}$command

  # Expect the process to finish and capture the exit status
  expect {
    -timeout 60
    eof {
      # Get the exit status of the process
      set exit_status [wait]
      # Extract the exit code from the exit status
      set exit_code [lindex $exit_status 3]
      # Return 0 for success, 1 for failure
      if {$exit_code == 0} {
          return 0
      } else {
          return 1
      }
    }
  }
}


# Regex pattern to match the criteria:
# - Support 1 or multiple BLE Local Names
# - Multiple Local Names are seperated using the pipe | character
# - A Local Name Starts with a letter S
# - A Local Name Ends with a letter C
# - A Local Name is exactly 18 characters (S................C)
set pattern {^(S.{16}C)(\|(S.{16}C))*$}

# Validate ble_local_name_regex
#if {[regexp $pattern $ble_local_name_regex]} {
#    puts "Option ble_local_name_regex: $ble_local_name_regex"
#} else {
#    puts "Option ble_local_name_regex: Error $ble_local_name_regex has wrong format"
#    exit 5
#}

set ble_mac_addr_regex ""

set ble_ln_pattern "(NEW|DEL) Device (\[0-9A-F:\]+) (\[ -~\]+)"
set ble_ln_pattern "(NEW|DEL) Device (\[0-9A-F:\]+) ($ble_local_name_regex)"

set chg_ble_ln_list_regex "(CHG) Device (\[0-9A-F:\]+) ($ble_local_name_regex)"
set chg_ble_ln_list_regex "(CHG) Device (\[0-9A-F:\]+) (\[ -~\]+)"
set chg_ble_ln_list_regex "(CHG) Device (\[0-9A-F:\]+) (\[ -~\]+)"

set newdel_ble_ln_list_regex "(NEW|DEL) Device (\[0-9A-F:\]+) (\[ -~\]+)"

#set newdel_ble_ln_list_regex "(NEW|DEL) Device (\[0-9A-F:\]+) ($ble_local_name_regex)"
#set newdel_ble_ln_list_regex "(NEW|DEL) Device (\[0-9A-F:\]+) (S.{16}C)(|(S.{16}C))*$"

# Pattern match from "bluetoothctl devices"
set devices_ble_ln_list_regex "Device (\[0-9A-F:\]+) ($ble_local_name_regex)"

# With "bluetoothctl devices" & vehicule(s)' BLE Local Name; try to populate ble_mac_addr_pattern
if { $stdin == "" } {
  spawn ./bluetoothctl-no-color devices
}
expect {
  -timeout 5
  -re "$devices_ble_ln_list_regex" {
    # We have a match; Extract the vehicule's MAC addr
    set ble_mac_addr [string trim $expect_out(1,string)]
    set ble_msg [string trim $expect_out(2,string)]
    puts "$ble_mac_addr $ble_msg"

    set ble_mac_addr_regex [ mac_addr_regex_ops $ble_mac_addr_regex $ble_mac_addr ]
    #puts "ble_mac_addr_regex: $chg_ble_ln_list_regex"
    #set chg_ble_ln_list_regex "(CHG) Device ($ble_mac_addr_regex) ($ble_local_name_regex)"
    set ble_mac_addr_pattern "(CHG) Device ($ble_mac_addr_regex) (\[ -~\]+)"
    exp_continue
  }
}



if { $stdin == "" } {
  spawn ./bluetoothctl-no-color
#  spawn -noecho ./bluetoothctl-no-color
  log_user 0

  expect -ex $prompt
  send "power on\r"
  expect -ex "Changing power on succeeded"

  send "scan on\r"
  expect -ex $prompt

}

puts "Option ble_local_name_regex: $ble_local_name_regex"
puts "Option ble_mac_addr_pattern: $ble_mac_addr_pattern"

puts "vin_list: $vin_list"
puts "ble_ln_pattern: $ble_ln_pattern"
puts "ble_local_name_regex: $ble_local_name_regex"
puts "ble_mac_addr_pattern: $ble_mac_addr_pattern"

expect {
  -timeout 180

  # Try to match a NEW|DEL status
  -re "$ble_ln_pattern" {
    # We have a match; Extract the vehicule's MAC addr
    set ble_status [string trim $expect_out(1,string)]
    set ble_mac_addr [string trim $expect_out(2,string)]

    if { $ble_status == "NEW" } {
      set ble_local_name [string trim $expect_out(3,string)]
      puts "$ble_status $ble_mac_addr $ble_local_name"
      add_or_update_mac_addr_ttl $ble_mac_addr $ble_presence_detection_ttl
    } elseif { $ble_status == "DEL" } {
      # DEL means device was removed from the cache
      # It doesn't mean that the device is out of reach
      set ble_local_name [string trim $expect_out(3,string)]
      puts "$ble_status $ble_mac_addr $ble_local_name"
    } elseif { $ble_status == "CHG" } {
      set ble_local_name ""
      puts "$ble_status $ble_mac_addr $ble_local_name"
#      ble_status_chg $ble_mac_addr
    }

    # Loop in ble_mac_addr_regex, check if any mac_addr is expired
    foreach mac_addr $ble_mac_addr_regex {
      # Check again if the MAC address has expired
      if { [is_mac_addr_expired $mac_addr] } {
        # MAC addr' TTL has expired, publish a OFF message
        puts "MQTT publish value OFF for topic: $mqtt_topic"
        mosquitto_publish $mqtt_server $mqtt_port $mqtt_username $mqtt_password $mqtt_topic "OFF"
      }
    }
    exp_continue
  }

  # Try to match a CHG status
  -re "$ble_mac_addr_pattern" {
    # We have a match; Extract the vehicule's MAC addr
    set ble_status [string trim $expect_out(1,string)]
    set ble_mac_addr [string trim $expect_out(2,string)]
    set ble_msg [string trim $expect_out(3,string)]
    puts "$ble_status $ble_mac_addr $ble_msg"
    add_or_update_mac_addr_ttl $ble_mac_addr $ble_presence_detection_ttl
    exp_continue
  }

#  # Try to match a CHG status
#  -re "$newdel_ble_ln_list_regex" {
#    # We have a match; Extract the vehicule's MAC addr
#    set ble_status [string trim $expect_out(1,string)]
#    set ble_mac_addr [string trim $expect_out(2,string)]
#    set ble_msg [string trim $expect_out(3,string)]
#    puts "$ble_status $ble_mac_addr $ble_msg"
#    exp_continue
#  }
}
