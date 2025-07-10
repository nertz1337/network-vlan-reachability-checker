#!/bin/bash

# Define the number of pings per IP
ping_count=2

# Define the base network interface name (e.g., eth0, enp0s3, wlan0)
# IMPORTANT: Change this to your actual base interface name
BASE_INTERFACE="eth1"

# Define the VLANs you expect to have subinterfaces for
# This list is used to find existing subinterfaces based on common naming convention.
# Make sure this accurately reflects the VLANs you have configured subinterfaces for.
VLAN_IDS=(2 201 202 203 211 212 213 221 222 240)

# Define the log file for results
log_file="ping_results.log"
> "$log_file" # Clear previous log file content

# Define ANSI color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# --- Help Message Function ---
show_help() {
    echo -e "${RED}Usage: $0 <target_ip_file>${NC}"
    echo ""
    echo "This script iterates through configured VLAN subinterfaces and uses each"
    echo "to ping ALL IP addresses listed in the provided <target_ip_file>."
    echo "This means a single interface will attempt to ping IPs across all specified VLANs."
    echo ""
    echo "Arguments:"
    echo "  <target_ip_file>  A text file containing one IP address per line to ping."
    echo "                    Empty lines and lines starting with '#' are ignored."
    echo ""
    echo "Example target_ip_file content:"
    echo "  # Some IPs from VLAN 2"
    echo "  11.3.2.10"
    echo "  11.3.2.15"
    echo ""
    echo "  # Some IPs from VLAN 201"
    echo "  11.3.201.5"
    echo "  11.3.201.100"
    echo ""
    echo "Prerequisites:"
    echo "  - VLAN subinterfaces listed in the script's VLAN_IDS array must be"
    echo "    configured and active on your system (e.g., ${BASE_INTERFACE}.201)."
    echo "    Example: sudo ip link add link ${BASE_INTERFACE} name ${BASE_INTERFACE}.201 type vlan id 201"
    echo "             sudo ip addr add 11.3.201.X/24 dev ${BASE_INTERFACE}.201"
    echo "             sudo ip link set dev ${BASE_INTERFACE}.201 up"
    echo "  - Each active subinterface should ideally have a default gateway configured"
    echo "    pointing to its respective Layer 3 switch/router's SVI for proper inter-VLAN routing."
    echo "  - The script requires root privileges to use specific interfaces. Run with 'sudo'."
    echo ""
    echo "Output:"
    echo "  - Live status updates in green (SUCCESS) or red (FAILED) in the terminal."
    echo "  - A detailed log of all pings in '${log_file}' (without colors)."
    echo ""
    echo "Current BASE_INTERFACE setting: ${BASE_INTERFACE}"
    echo "VLAN IDs expected to have subinterfaces: ${VLAN_IDS[*]}"
}

# Check if a target IP file was provided as an argument
if [ -z "$1" ]; then
    show_help | tee -a "$log_file" # Output help to terminal and log file
    exit 1
fi

target_ip_file="$1" # Assign the first argument to target_ip_file

echo "Starting ping script..." | tee -a "$log_file"
echo "Reading target IPs from: ${target_ip_file}" | tee -a "$log_file"
echo "Using base interface: ${BASE_INTERFACE}" | tee -a "$log_file"
echo "Attempting to find subinterfaces for VLAN IDs: ${VLAN_IDS[*]}" | tee -a "$log_file"
echo "" | tee -a "$log_file"

# Check if the target IP file exists
if [ ! -f "$target_ip_file" ]; then
    echo -e "${RED}Error: Target IP file '${target_ip_file}' not found!${NC}" | tee -a "$log_file"
    echo "Please ensure the file exists and the path is correct." | tee -a "$log_file"
    exit 1
fi

# Function to get the IP address of an interface
get_interface_ip() {
    local iface="$1"
    ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1
}

# --- Discover active subinterfaces ---
declare -a active_interfaces_and_ips
echo "Discovering active VLAN subinterfaces..." | tee -a "$log_file"
for vlan_id in "${VLAN_IDS[@]}"; do
    interface_name="${BASE_INTERFACE}.${vlan_id}"
    if ip link show "$interface_name" >/dev/null 2>&1; then
        interface_ip=$(get_interface_ip "$interface_name")
        if [ -n "$interface_ip" ]; then
            active_interfaces_and_ips+=("${interface_name}:${interface_ip}")
            echo -e "${GREEN}Found active subinterface: ${interface_name} with IP: ${interface_ip}${NC}" | tee -a "$log_file"
        else
            echo -e "${YELLOW}Warning: Subinterface ${interface_name} exists but has no IP address. Skipping.${NC}" | tee -a "$log_file"
        fi
    else
        echo -e "${YELLOW}Warning: Subinterface ${interface_name} not found. Skipping.${NC}" | tee -a "$log_file"
    fi
done

if [ ${#active_interfaces_and_ips[@]} -eq 0 ]; then
    echo -e "${RED}Error: No active VLAN subinterfaces found based on configuration. Please ensure they are configured and up.${NC}" | tee -a "$log_file"
    exit 1
fi
echo "" | tee -a "$log_file"

# Read all target IPs into an array first
declare -a target_ips_list
while IFS= read -r ip_address; do
    if [[ -n "$ip_address" && ! "$ip_address" =~ ^# ]]; then
        target_ips_list+=("$ip_address")
    fi
done < "$target_ip_file"

if [ ${#target_ips_list[@]} -eq 0 ]; then
    echo -e "${RED}Error: No valid IP addresses found in '${target_ip_file}'.${NC}" | tee -a "$log_file"
    exit 1
fi
echo "Target IPs to ping: ${target_ips_list[*]}" | tee -a "$log_file"
echo "" | tee -a "$log_file"

# --- Main loop: Iterate through each active source interface ---
for interface_info in "${active_interfaces_and_ips[@]}"; do
    IFS=':' read -r current_interface current_source_ip <<< "$interface_info"
    current_vlan_id=$(echo "$current_interface" | awk -F'.' '{print $NF}') # Extract VLAN ID from interface name

    echo "--- Using Source Interface: ${current_interface} (IP: ${current_source_ip}, VLAN: ${current_vlan_id}) to ping all targets ---" | tee -a "$log_file"

    # --- Nested loop: Ping all target IPs from the current source interface ---
    for dest_ip_address in "${target_ips_list[@]}"; do
        # Extract VLAN ID from the destination IP address (assuming format X.Y.<vlan_id>.Z)
        # Using awk for robustness here as well
        dest_vlan_id=$(echo "${dest_ip_address}" | awk -F'.' '{print $3}')

        echo "  Pinging Destination: ${dest_ip_address} (Dest VLAN: ${dest_vlan_id})..." | tee -a "$log_file"

        # Ping the target IP address using the specified source interface
        ping -c "$ping_count" -I "$current_interface" "$dest_ip_address" >> "$log_file" 2>&1

        # Check the exit status of the ping command
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}SUCCESS: Dest: ${dest_ip_address} (VLAN: ${dest_vlan_id}) from Src: ${current_source_ip} (Int: ${current_interface})${NC}" | tee -a "$log_file"
            log_message="  SUCCESS: Dest: ${dest_ip_address} (VLAN: ${dest_vlan_id}) from Src: ${current_source_ip} (Int: ${current_interface})"
            echo "$log_message" >> "$log_file"
        else
            echo -e "  ${RED}FAILED: Dest: ${dest_ip_address} (VLAN: ${dest_vlan_id}) from Src: ${current_source_ip} (Int: ${current_interface})${NC}" | tee -a "$log_file"
            log_message="  FAILED: Dest: ${dest_ip_address} (VLAN: ${dest_vlan_id}) from Src: ${current_source_ip} (Int: ${current_interface})"
            echo "$log_message" >> "$log_file"
        fi
        echo "" | tee -a "$log_file" # Add a blank line for readability
    done
    echo "--- Finished with Source Interface: ${current_interface} ---" | tee -a "$log_file"
    echo "" | tee -a "$log_file"
done

echo "Ping script finished. Results saved to $log_file" | tee -a "$log_file"