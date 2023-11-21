#!/bin/sh
#
# NORDVPN-RC
#
# NordVPN client using WireGuard and Netifrc.
#

# exit when any command fails
set -T

echoexit() {
  # Print to stderr and exit
  printf "%s\n" "$@" 1>&2
  exit 1
}

# Checking dependencies:
whereis curl > /dev/null || echoexit "'curl' not found."
whereis jq > /dev/null || echoexit "'jq' not found."
whereis wg > /dev/null || echoexit "'wg' not found."
whereis rc-service > /dev/null || echoexit "'rc-service' not found."

# constants

TMPDIR="/tmp"
DB_FILE="$TMPDIR/nordvpn-rc-db"

# config files
WIREGUARD_DIR="/etc/wireguard"
NORDVPN_DIR="$WIREGUARD_DIR/nordvpn"
NORDVPN_CONFIG="$NORDVPN_DIR/config.json"

# urls
NORDVPN_API_BASE="https://api.nordvpn.com"
NORDVPN_API_USER="$NORDVPN_API_BASE/v1/users/current"
NORDVPN_API_CREDENTIALS="$NORDVPN_API_BASE/v1/users/services/credentials"
NORDVPN_API_SERVERS="$NORDVPN_API_BASE/v1/servers"
NORDVPN_API_COUNTRIES="$NORDVPN_API_BASE/v1/servers/countries"
NORDVPN_API_RECOMMENDED="$NORDVPN_API_BASE/v1/servers/recommendations"

# id of wireguard servers
NORDVPN_WG_ID="35"

# api servers filters
NORDVPN_API_SERVERS_FILTERS="filters\[servers.status\]=online"
NORDVPN_API_SERVERS_FILTERS+="&filters\[servers_technologies\]\[id\]=$NORDVPN_WG_ID"
NORDVPN_API_SERVERS_FILTERS+="&filters\[servers_technologies\]\[pivot\]\[status\]=online"

# api servers fields
NORDVPN_API_SERVERS_FIELDS="fields\[servers.id\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.name\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.hostname\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.station\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.load\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.created_at\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.groups.id\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.groups.title\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.technologies.id\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.technologies.metadata\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.locations.country.id\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.locations.country.name\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.locations.country.city.id\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.locations.country.city.name\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.locations.country.city.latitude\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.locations.country.city.longitude\]"
NORDVPN_API_SERVERS_FIELDS+="&fields\[servers.locations.country.city.hub_score\]"

# servers query
NORDVPN_API_SERVERS_BASE="$NORDVPN_API_SERVERS?$NORDVPN_API_SERVERS_FIELDS&$NORDVPN_API_SERVERS_FILTERS"

# recommended servers query
NORDVPN_API_RECOMMENDED_BASE="$NORDVPN_API_RECOMMENDED?$NORDVPN_API_SERVERS_FIELDS&$NORDVPN_API_SERVERS_FILTERS"

# verify if user has root privileges
verify_root() {
	if [ "$(id -u)" != "0" ]; then
   		exit_non_root
	fi
}

# print error message for insufficient privileges and exit
exit_non_root() {
	echo -e "This command requires administrative privileges."
	echo -e "Try 'sudo nordvpn-rc <your-args-go-here>' or login as root."
	exit 1
}

# verify if token is valid on remote
verify_token() {
	local token response errors valid
	token=$1

	# request api for user metadata
	response=$(curl -s "$NORDVPN_API_USER" -u "token:$token")

	# check for errors in response
	valid="valid"
	if [[ "$response" == "" ]]; then
		exit_invalid_token
	fi
	errors=$(printf %s "$response" | jq '.errors' 2>/dev/null)
	if [[ "$errors" != "" ]] && [[ "$errors" != "null" ]]; then
		exit_invalid_token
	fi
}

# print error message for invalid token and exit
exit_invalid_token() {
	echo -e "You have not set a valid nordvpn access token."
	echo -e "Please follow the instructions to obtain a new token: https://support.nordvpn.com/Connectivity/Linux/1905092252/How-to-log-in-to-NordVPN-on-Linux-with-a-token.htm"
	echo -e "Once you have copied your token, you can use it by running 'nordvpn-rc set token <your-token-goes-here>'."
	exit 1
}

# verify api response
verify_response() {
	local response errors
	response=$1

	# check for errors in response
	if [[ "$response" == "" ]]; then
		echoexit "api_error: API call returned nothing."
	fi	
	errors=$(printf %s "$response" | jq '.errors' 2>/dev/null)
	if [[ "$errors" != "" ]] && [[ "$errors" != "null" ]]; then
		echoexit "api_error: API replied with errors: '$errors'."
	fi
}

# get wireguard private key from nordvpn and put it in the config file
update_private_key() {
	verify_root

	local config token response private_key
	
	# read config file
	config=$(cat "$NORDVPN_CONFIG" 2>/dev/null || echo "{}")

	# get nordvpn token from config file
	token=$(printf %s "$config" | jq -r '.token')

	# verify token
	verify_token "$token"

	# request api for credentials
	response=$(curl -s "$NORDVPN_API_CREDENTIALS" -u "token:$token")
	verify_response "$response"

	# get private key from response
	private_key=$(printf %s "$response" | jq -r '.nordlynx_private_key')
	if [[ "$private_key" == "" ]]; then
		echoexit "api_error: API did not provide a valid private_key."
	fi

	# create new config
	config=$(printf %s "$config" | jq --arg key "$private_key" '.private_key = $key')

	# write updated config file
	mkdir -p "$NORDVPN_DIR"
	echo "$config" > "$NORDVPN_CONFIG"
	chmod 600 "$NORDVPN_CONFIG"
	
}

# set nordvpn access token in the config file
set_token() {
	verify_root

	local config token valid
	token=$1

	# check the string provided by user
	if [[ "$token" == "" ]]; then
		echoexit "error: Attempting to set invalid access token."
	fi
	
	# verify token
	verify_token "$token"

	# read config file
	config=$(cat "$NORDVPN_CONFIG" 2>/dev/null || echo "{}")
	
	# create new config
	config=$(printf %s "$config" | jq --arg tok "$token" '.token = $tok')
	
	# write updated config file
	mkdir -p "$NORDVPN_DIR"
	echo "$config" > "$NORDVPN_CONFIG"
	chmod 600 "$NORDVPN_CONFIG"

	# update credentials
	update_private_key
}

# set wireguard interface in the config file
set_interface() {
	verify_root
	
	local config interface wg_if_file
	interface=$1

	# check the string provided by user
	if [[ "$interface" == "" ]]; then
		echoexit "error: Attempting to set invalid interface."
	fi

	# check for existing config file
	wg_if_file="$WIREGUARD_DIR/$interface.conf"
	if test -f "$wg_if_file"; then
		echo -e "File '$wg_if_file' already exists."
		read -p "Do you want to override it? [Yes/No] " -r
		if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    			echo -e "Not doing anything."
			exit 0
		fi
	fi

	# read config file
	config=$(cat "$NORDVPN_CONFIG" 2>/dev/null || echo "{}")
	
	# create new config
	config=$(printf %s "$config" | jq --arg if "$interface" '.interface = $if')
	
	# write updated config file
	mkdir -p "$NORDVPN_DIR"
	echo "$config" > "$NORDVPN_CONFIG"
	chmod 600 "$NORDVPN_CONFIG"

	echo -e "Interface '$interface' configured."
}

# get countries from nordvpn
get_countries() {
	local response countries

	# request api for countries
	response=$(curl -s "$NORDVPN_API_COUNTRIES")
	verify_response "$response"

	# extract country name and id
	countries=$(printf %s "$response" | jq 'map({ id: .id, name: .name })')

	# return response
	printf %s "$countries"
}

# get cities from nordvpn
get_cities() {
	local country response cities
	country=$1

	# request api for countries
	response=$(curl -s "$NORDVPN_API_COUNTRIES")
	verify_response "$response"

	# extract city name and id
	cities=$(printf %s "$response" | jq --arg cc "$country" '.[] | select(.name == $cc) | .cities | map({id: .id, name: .name})')

	# return response
	printf %s "$cities"
}

# print server info to terminal
show_server() {
	local server form cyan white normcyan boldcyan bold endcolor
	server=$1

	# check server
	if [[ "$server" == "" ]] || [[ "$server" == "null" ]]; then
		echoexit "error: invalid server json."
	fi

	# format colors
	cyan="36"
	white="97"
	normcyan="\e[${cyan}m"
	boldcyan="\e[1;${cyan}m"
	bold="\e[1;${white}m"
	endcolor="\e[0m"

	# formattated output
	form="${boldcyan}nordvpn${endcolor}: ${normcyan}$(printf %s "$server" | jq -r '.id')${endcolor}"
	form+="\n  ${bold}name${endcolor}: $(printf %s "$server" | jq -r '.name')"
	form+="\n  ${bold}hostname${endcolor}: $(printf %s "$server" | jq -r '.hostname')"
	form+="\n  ${bold}station${endcolor}: $(printf %s "$server" | jq -r '.station')"
	form+="\n  ${bold}public key${endcolor}: $(printf %s "$server" | jq -r --argjson wi "$NORDVPN_WG_ID" '.technologies[] | select(.id == $wi) | .metadata[] | select(.name == "public_key") | .value')"	
	form+="\n  ${bold}groups${endcolor}: $(printf %s "$server" | jq -r '.groups | map(.title) | join(", ")')"
	form+="\n  ${bold}created at${endcolor}: $(printf %s "$server" | jq -r '.created_at')"
	form+="\n  ${bold}country${endcolor}: $(printf %s "$server" | jq -r '.locations[].country.name')"
	form+="\n  ${bold}city${endcolor}: $(printf %s "$server" | jq -r '.locations[].country.city.name')"
	form+="\n  ${bold}latitude${endcolor}: $(printf %s "$server" | jq -r '.locations[].country.city.latitude')"
	form+="\n  ${bold}longitude${endcolor}: $(printf %s "$server" | jq -r '.locations[].country.city.longitude')"
	form+="\n  ${bold}hub score${endcolor}: $(printf %s "$server" | jq -r '.locations[].country.city.hub_score')"
	form+="\n  ${bold}load${endcolor}: $(printf %s "$server" | jq -r '.load')"

	# Print server info to terminal
	echo -e "$form"
}

# get server id from file
get_server_id() {
	verify_root

	local interface wg_if_file wg_if line server_id
	interface=$1

	# wireguard config file name
	wg_if_file="$WIREGUARD_DIR/$interface.conf"
	
	# check if file exists
	if ! test -f "$wg_if_file"; then
		echoexit "No interface config file found."
	fi

	# change interface symlink
	wg_if="$(cat "$wg_if_file" 2>/dev/null)"

	# check for comment in file
	line="$(printf %b "$wg_if" | grep "^# SERVER_ID = " 2>/dev/null)"
	if [[ "$line" == "" ]]; then
		echoexit "error: invalid wireguard config '$wg_if_file'."
	fi

	# extract server id
	server_id="$(printf %s "$line" | cut -d "=" -f 2 | sed -r "s/\ //g")"
	
	# return server id
	printf %s "$server_id"
}

# get server hostname from file
get_server_hostname() {
	verify_root

	local interface wg_if_file wg_if line hostname
	interface=$1

	# wireguard config file name
	wg_if_file="$WIREGUARD_DIR/$interface.conf"
	
	# check if file exists
	if ! test -f "$wg_if_file"; then
		echoexit "error: no interface config file found."
	fi

	# change interface symlink
	wg_if="$(cat "$wg_if_file" 2>/dev/null)"

	# check for entry in file
	line="$(printf %b "$wg_if" | grep "^Endpoint = " 2>/dev/null)"
	if [[ "$line" == "" ]]; then
		echoexit "error: invalid wireguard config '$wg_if_file'."
	fi

	# extract server hostname
	hostname="$(printf %s "$line" | cut -d "=" -f 2 | sed -r "s/\ //g" | cut -d ":" -f 1)"
	
	# return server hostname
	printf %s "$hostname"
}

# check if wireguard conifg matches connected interface
peer_online() {
	verify_root

	local interface server server_ip server_key if_endpoint if_ip if_key
	interface=$1
	server=$2

	# get server info
	server_ip="$(printf %s "$server" | jq -r '.station')"
	server_key="$(printf %s "$server" | jq -r --argjson wi "$NORDVPN_WG_ID" '.technologies[] | select(.id == $wi) | .metadata[] | select(.name == "public_key") | .value')"

	# get interface info
	if_endpoint="$(wg show "$interface" endpoints 2>/dev/null)"
	if_ip="$(printf %s "$if_endpoint" | sed -r 's/[[:blank:]]+/ /g' | cut -d " " -f 2 | cut -d ":" -f 1)"
	if_key="$(printf %s "$if_endpoint" | sed -r 's/[[:blank:]]+/ /g' | cut -d " " -f 1)"

	# print result of match
	if [[ "$server_ip" == "$if_ip" ]] && [[ "$server_key" == "$if_key" ]]; then
		printf %s "online"
	else
		printf %s "offline"
	fi
}

# get status of current wireguard connection
get_status() {
	verify_root

	local config interface server_id response server if_pub_key if_stts peer_stts con_stts

	# read config file
	config=$(cat "$NORDVPN_CONFIG" 2>/dev/null || echo "{}")
	
	# extract interface
	interface=$(printf %s "$config" | jq -r '.interface')
	if [[ "$interface" == "" ]] || [[ "$interface" == "null" ]]; then
		echoexit "error: invalid wireguard interface."
	fi
	
	# extract server id
	server_id="$(get_server_id "$interface")"

	# request api for server with given id
	response=$(curl -s "$NORDVPN_API_SERVERS_BASE&filters\[servers.id\]=$server_id&limit=1")
	verify_response "$response"

	# extract server
	server="$(printf %s "$response" | jq '.[]')"

	# check if interface is connected to given server
	if_pub_key="$(wg show "$interface" public-key 2>/dev/null)"
	if [[ "$if_pub_key" == "" ]]; then
		if_stts="down"
	else
		if_stts="up"
	fi

	# check if remote matches interface
	peer_stts="none"
	if [[ "$if_stts" == "up" ]]; then
		peer_stts="$(peer_online "$interface" "$server")"
	fi

	# check if interface is connected to given server
	if [[ "$if_stts" == "up" ]] && [[ "$peer_stts" == "online" ]]; then
		con_stts="connected"
	else
		con_stts="disconnected"
	fi

	# print status
	echo -e "status: $con_stts"
	echo -e "  interface: $if_stts"
	echo -e "  peer: $peer_stts"

	# print info if interface is up
	if [[ "$if_stts" == "up" ]]; then
		# print wireguard info
		echo -e ""
		wg show "$interface"
		
		# print nordvpn server info
		echo -e ""
		show_server "$server"
	fi
}

# wireguard postup script
wg_postup() {
	verify_root

	local interface
	interface=$1

	echo -e "Runnning postup ..."

	# After the interface is up, we add routing and firewall rules,
	# which prevent packets from going through the normal routes, which are
	# for "plaintext" packets.
	# routing rules taken from: https://www.wireguard.com/netns/
	# firewall rules taken from: man wg-quick
	#
	# If the connection to the VPN goes down, the firewall rule makes sure
	# no other connections can be open, until you remove the interface
	# using: rc-service net.wg0 stop
	#
	# For the nftables firewall rule to work, make sure you set:
	# SAVE_ON_STOP="no"
	# in: /etc/conf.d/nftables

	# set a firewall mark for all wireguard packets
	wg set "$interface" fwmark 334455 || exit 1
	
	# route all packets to the interface in table 2468
	ip route add default dev "$interface" table 2468 || exit 1
	
	# if packet doesn't have the wireguard firewall mark,
	# send it to table 2468
	ip rule add not fwmark 334455 table 2468 || exit 1
		
	# if packet isn't going out the interface, doesn't have
	# the wireguard firewall mark and isn't broadcast or multicast
	# reject it (don't drop it like there's no connection)
	nft add table ip filter
	nft add chain ip filter output
	nft insert rule ip filter output oifname!="wg0" mark!=334455 fib daddr type!=local counter reject || exit 1
		
	# Make sure only DNS server is the one from your provider or
	# a custom one fitting your needs!
	# If there is one, otherwise you can remove this line.
	echo "nameserver 103.86.96.100" > /etc/resolv.conf || exit 1
	echo "nameserver 103.86.99.100" >> /etc/resolv.conf || exit 1
}

# wireguard predown script
wg_predown() {
	verify_root

	local interface
	interface=$1

	echo -e "Runnning predown ..."

	# When bringing down the interface using rc-service, make sure that all
	# rules specific to isolating the wireguard connections are gone, so
	# that normal connections can work again.
	# Change the DNS values for your setup!
	
	# Bringing back default nftables rules.
	rc-service nftables reload || exit 1

	# Removing wireguard specific routing rules.
	ip route del default dev "$interface" table 2468 || exit 1
	ip rule del not fwmark 334455 table 2468 || exit 1

	# Bringing back your own DNS settings, in case they were
	# changed in postup()
	rc-service dhcpcd stop
	rc-service dhcpcd start

	#echo "nameserver 1.2.3.4" > /etc/resolv.conf || exit 1
	#echo "nameserver 123.12.21.1" >> /etc/resolv.conf || exit 1
}

# connect to given wireguard server
connect() {
	verify_root

	local server hostname server_id public_key config private_key wg_config wg_config_file interface wg_if_file
	server=$1

	# extract hostname
	hostname=$(printf %s "$server" | jq -r '.hostname')
	if [[ "$hostname" == "" ]] || [[ "$hostname" == "null" ]]; then
		echoexit "error: invalid server hostname."
	fi

	# extract server id
	server_id=$(printf %s "$server" | jq -r '.id')
	if [[ "$server_id" == "" ]] || [[ "$server_id" == "null" ]]; then
		echoexit "error: invalid server id."
	fi

	# extract public key
	public_key=$(printf %s "$server" | jq -r --argjson wi "$NORDVPN_WG_ID" '.technologies[] | select(.id == $wi) | .metadata[] | select(.name == "public_key") | .value')
	if [[ "$public_key" == "" ]] || [[ "$public_key" == "null" ]]; then
		echoexit "error: invalid server public key."
	fi

	# read config file
	config=$(cat "$NORDVPN_CONFIG" 2>/dev/null || echo "{}")
	
	# extract private key
	private_key=$(printf %s "$config" | jq -r '.private_key')
	if [[ "$private_key" == "" ]] || [[ "$private_key" == "null" ]]; then
		echoexit "error: invalid client private key."
	fi
	
	# create wireguard config
	wg_config="# File created by nordvpn-rc script."
	wg_config+="\n# Do not edit this file manually."
	wg_config+="\n# SERVER_ID = $server_id"
	wg_config+="\n"
	wg_config+="\n[Interface]"
	wg_config+="\nPrivateKey = $private_key"
	wg_config+="\nListenPort = 51820"
	wg_config+="\n"
	wg_config+="\n[Peer]"
	wg_config+="\nPublicKey = $public_key"
	wg_config+="\nAllowedIPs = 0.0.0.0/0"
	wg_config+="\nEndpoint = $hostname:51820"
	wg_config+="\n"

	# wireguard config file name
	wg_config_file="$NORDVPN_DIR/$(printf %s "$hostname" | cut -d "." -f 1).conf"

	# write wireguard config
	mkdir -p "$NORDVPN_DIR"
	printf %b "$wg_config" > "$wg_config_file"
	chmod 600 "$wg_config_file"

	# extract interface
	interface=$(printf %s "$config" | jq -r '.interface')
	if [[ "$interface" == "" ]] || [[ "$interface" == "null" ]]; then
		echoexit "error: invalid wireguard interface."
	fi

	# wireguard config file name
	wg_if_file="$WIREGUARD_DIR/$interface.conf"
	
	# change interface symlink
	rm "$wg_if_file"
	ln -s "$wg_config_file" "$wg_if_file"

	# print connecting
	echo -e "Connecting to server '$hostname' ..."
	
	# start wireguard interface
	rc-service "net.$interface" stop
	rc-service "net.$interface" start

	# add wireguard firewall rules
	wg_postup "$interface"
	
	# print connected
	echo -e "Connected successfully!"
}

# connect to server by id
connect_by_id() {
	verify_root

	local server_id response server
	server_id=$1
	
	# request api for server with given id
	response=$(curl -s "$NORDVPN_API_SERVERS_BASE&filters\[servers.id\]=$server_id&limit=1")
	verify_response "$response"

	# extract server
	server="$(printf %s "$response" | jq '.[]')"

	# connect to server
	connect "$server"
}

# connect to recommended server
connect_to_recommended() {
	verify_root

	local filters response server
	filters=$1

	# request api for recommended server
	response=$(curl -s "$NORDVPN_API_RECOMMENDED_BASE&$filters&limit=1")
	verify_response "$response"

	# extract server
	server="$(printf %s "$response" | jq '.[]')"

	# connect to server
	connect "$server"
}

# connect to other server
connect_to_other() {
	verify_root

	local filters config interface old_server_id response server server_id
	filters=$1
	
	# read config file
	config=$(cat "$NORDVPN_CONFIG" 2>/dev/null || echo "{}")
	
	# extract interface
	interface=$(printf %s "$config" | jq -r '.interface')
	if [[ "$interface" == "" ]] || [[ "$interface" == "null" ]]; then
		echoexit "error: invalid wireguard interface."
	fi

	# extract server id
	old_server_id="$(get_server_id "$interface")"

	# request api for recommended server
	response=$(curl -s "$NORDVPN_API_RECOMMENDED_BASE&$filters&limit=2")
	verify_response "$response"

	# extract server
	server="$(printf %s "$response" | jq '.[0]')"

	# check id
	server_id="$(printf %s "$server" | jq -r '.id')"
	if [[ "$old_server_id" == "$server_id" ]]; then
		server="$(printf %s "$response" | jq '.[1]')"
	fi

	# connect to server
	connect "$server"
}

# connect to recommended server in given country
connect_location() {
	verify_root

	local country city filters
	country=$1
	city=$2

	# set filters
	if [[ "$city" == "" ]]; then
		if [[ "$country" == "" ]]; then
			filters=""
		else
			local country_id
			# extract country id
			country_id=$(get_countries | jq -r --arg cc "$country" '.[] | select(.name == $cc) | .id')
			if [[ "$country_id" == "" ]]; then
				echoexit "error: invalid country."
			fi
			# set country filters
			filters="filters\[country_id\]=$country_id"
		fi
	else
			local city_id
			# extract city id
			city_id=$(get_cities "$country" | jq -r --arg ct "$city" '.[] | select(.name == $ct) | .id')
			if [[ "$city_id" == "" ]]; then
				echoexit "error: invalid country or city."
			fi
			# set country filters
			filters="filters\[country_city_id\]=$city_id"
	fi
	
	# return filters
	printf %s "$filters"
}

# disconnect
wg_disconnect() {
	verify_root

	local config interface server_id response server hostname

	# read config file
	config=$(cat "$NORDVPN_CONFIG" 2>/dev/null || echo "{}")
	
	# extract interface
	interface=$(printf %s "$config" | jq -r '.interface')
	if [[ "$interface" == "" ]] || [[ "$interface" == "null" ]]; then
		echoexit "error: invalid wireguard interface."
	fi
	
	# extract server hostname
	hostname="$(get_server_hostname "$interface")"

	# print disconnecting
	echo -e "Disconnecting from server '$hostname' ..."
	
	# remove wireguard firewall rules
	wg_predown "$interface"

	# stop wireguard interface
	rc-service "net.$interface" stop

	# print disconnected
	echo -e "Disconnected successfully!"
}

# restart
wg_restart() {
	verify_root

	local config interface hostname

	# read config file
	config=$(cat "$NORDVPN_CONFIG" 2>/dev/null || echo "{}")
	
	# extract interface
	interface=$(printf %s "$config" | jq -r '.interface')
	if [[ "$interface" == "" ]] || [[ "$interface" == "null" ]]; then
		echoexit "error: invalid wireguard interface."
	fi

	# extract server hostname
	hostname="$(get_server_hostname "$interface")"

	# print restarting
	echo -e "Restarting connection to server '$hostname' ..."

	# restart wireguard interface
	rc-service "net.$interface" stop
	rc-service "net.$interface" start

	# print restarted
	echo -e "Restarted successfully!"
}

# error wrong number of args
exit_args() {
	local mod
	mod="$(printf %s " $2 " | sed -r 's/[[:blank:]]+/ /g')"
	echo -e "Too $1 arguments."
	echo -e "Try 'nordvpn-rc$mod--help' to see available options."
	exit 1
}

# main
[ $# -lt 1 ] && exit_args "few" ""
m_opt=$1
shift
case "$m_opt" in
	"-h" | "--help")
		[ $# -gt 0 ] && exit_args "many" ""
		echo -e ""
		echo -e "NordVPN client using WireGuard and Netifrc."
		echo -e "Usage: nordvpn-rc <action> <options>"
		echo -e ""
		echo -e "actions:"
		echo -e "  -h, --help    display this help message"
		echo -e "  (g)et         get info from VPN provider"
		echo -e "  (s)et         set config"
		echo -e "  (c)onnect     connect to server"
		echo -e "  (d)isconnect  disconnect from server"
		echo -e "  (r)estart     restart current connection"
		echo -e ""
		echo -e "To see options run 'nordvpn-rc <action> --help'"
		echo -e ""
		exit 0
		;;
	"g" | "get")
		[ $# -lt 1 ] && exit_args "few" "get"
		g_opt=$1
		shift
		case "$g_opt" in
			"-h" | "--help")
				[ $# -gt 0 ] && exit_args "many" "get"
				echo -e ""
				echo -e "NordVPN client using WireGuard and Netifrc."
				echo -e "Action: get"
				echo -e "Usage: nordvpn-rc get <options>"
				echo -e ""
				echo -e "options:"
				echo -e "  -h, --help  display this help message"
				echo -e "  countries   get country list from VPN provider"
				echo -e "  cities      get city list from VPN provider"
				echo -e "  status      get current VPN status"
				echo -e ""
				exit 0
				;;
			"countries")
				[ $# -gt 0 ] && exit_args "many" "get"
				get_countries | jq -r '.[].name'
				exit 0
				;;
			"cities")
				[ $# -lt 1 ] && exit_args "few" "get"
				country=$1
				shift
				[ $# -gt 0 ] && exit_args "many" "get"
				get_cities "$country" | jq -r '.[].name'
				exit 0
				;;
			"status")
				[ $# -gt 0 ] && exit_args "many" "get"
				get_status
				exit 0
				;;
			*)
				echo -e "Invalid argument '$g_opt'."
				echo -e "Try 'nordvpn-rc get --help' to see available options."
				exit 1
				;;
		esac
		;;
	"s" | "set")
		[ $# -lt 1 ] && exit_args "few" "set"
		s_opt=$1
		shift
		case "$s_option" in
			"-h" | "--help")
				[ $# -gt 0 ] && exit_args "many" "set"
				echo -e ""
				echo -e "NordVPN client using WireGuard and Netifrc."
				echo -e "Action: set"
				echo -e "Usage: nordvpn-rc set <options>"
				echo -e ""
				echo -e "options:"
				echo -e "  -h, --help     display this help message"
				echo -e "  token          set the token given by VPN provider"
				echo -e "  if, interface  set the name of the wireguard interface"
				echo -e ""
				exit 0
				;;
			"token")
				[ $# -lt 1 ] && exit_args "few" "set"
				token=$1
				shift
				[ $# -gt 0 ] && exit_args "many" "set"
				set_token "$token"
				exit 0
				;;
			"if" | "interface")
				[ $# -lt 1 ] && exit_args "few" "set"
				interface=$1
				shift
				[ $# -gt 0 ] && exit_args "many" "set"
				set_interface "$interface"
				exit 0
				;;
			*)
				echo -e "Invalid argument '$s_opt'."
				echo -e "Try 'nordvpn-rc set --help' to see available options."
				exit 1
				;;
		esac
		;;
	"c" | "cr" | "co" | "connect")
		case "$m_opt" in
			"cr") c_opt="r" ;;
			"co") c_opt="o" ;;
			*)
				[ $# -lt 1 ] && exit_args "few" "connect"
				c_opt=$1
				shift
				;;
		esac
		case "$c_opt" in
			"-h" | "--help")
				[ $# -gt 0 ] && exit_args "many" "connect"
				echo -e ""
				echo -e "NordVPN client using WireGuard and Netifrc."
				echo -e "Action: connect"
				echo -e "Usage: nordvpn-rc connect <options>"
				echo -e ""
				echo -e "options:"
				echo -e "  -h, --help      display this help message"
				echo -e "  (r)recommended  connect to a server recommended by the VPN provider"
				echo -e "  (o)ther         connect to a different server than the current one"
				echo -e "  <id|hostname>   connect to a server with given <id> or <hostname>"
				echo -e ""
				exit 0
				;;
			"r" | "recommended")
				[ $# -lt 1 ] && country="" || country=$1 && shift 2>/dev/null
				[ $# -lt 1 ] && city="" || city=$1 && shift 2>/dev/null
				[ $# -gt 0 ] && exit_args "many" "connect"
				connect_to_recommended "$(connect_location "$country" "$city")"
				exit 0
				;;
			"o" | "other")
				[ $# -lt 1 ] && country="" || country=$1 && shift 2>/dev/null
				[ $# -lt 1 ] && city="" || city=$1 && shift 2>/dev/null
				[ $# -gt 0 ] && exit_args "many" "connect"
				connect_to_other "$(connect_location "$country" "$city")"
				exit 0
				;;
			*)
				[ $# -gt 0 ] && exit_args "many" "connect"
				num_re='^[0-9]+$'
				if [[ $c_opt =~ $num_re ]]; then
					connect_by_id "$c_opt"
				else
					connect_by_hostname "$c_opt"
				fi
				exit 0
				;;
		esac
		;;
	"d" | "disconnect")
		[ $# -gt 0 ] && exit_args "many" "disconnect"
		wg_disconnect
		exit 0
		;;
	"r" | "restart")
		[ $# -gt 0 ] && exit_args "many" "restart"
		wg_restart
		exit 0
		;;
	*)
		echo -e "Invalid argument '$m_opt'."
		echo -e "Try 'nordvpn-rc --help' to see available options."
		exit 1
		;;
esac

