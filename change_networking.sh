#!/bin/bash

# ssh to all provided IPs
#    on each server remove all IPs that are not the ssh IP
#    set default route to go through network with ssh IP
#
# Goal is to eliminate IPs from the same network and change those servers that have default route through 101 VLAN

for server_ip in "$@"; do
    echo "Processing server: $server_ip"
    ssh-keygen -f '/home/marian/.ssh/known_hosts' -R ${server_ip} 2>/dev/null
    
    ssh "$server_ip" '
        # Get the IP address used for the SSH connection
        CONNECTION_IP=$(echo $SSH_CONNECTION | cut -d" " -f3)
        echo "Connected using IP: $CONNECTION_IP"
        
        # Get the interface that has this IP
        CONNECTION_IFACE=$(ip -o addr show | grep "$CONNECTION_IP" | awk '\''{print $2}'\'')
        echo "Connected interface: $CONNECTION_IFACE"
        
        if [ -z "$CONNECTION_IFACE" ]; then
            echo "Could not determine the interface for IP $CONNECTION_IP"
            exit 1
        fi

        ip -br a
        ip r
        
        # Calculate appropriate gateway (first IP in subnet)
        # Extract IP base and convert last octet to 1
        IP_BASE=$(echo "$CONNECTION_IP" | cut -d"." -f1-3)
        DEFAULT_GW="${IP_BASE}.1"
        echo "Setting default gateway to: $DEFAULT_GW"
        
        # Get network prefix (CIDR)
        NETMASK=$(ip -o addr show | grep "$CONNECTION_IP" | awk '\''{print $4}'\'' | cut -d"/" -f2)
        if [ -z "$NETMASK" ]; then
            NETMASK="24"  # Use 24 as default if not found
        fi
        
        # Create a temporary netplan config
        echo "Using netplan for configuration"
            cat << EOF | sudo tee /etc/netplan/50-cloud-init.yaml
network:
    version: 2
    renderer: networkd
    ethernets:
        $CONNECTION_IFACE:
            dhcp4: no
            addresses: ["$CONNECTION_IP/$NETMASK"]
            routes:
            -   to: default
                via: $DEFAULT_GW
            nameservers:
                addresses:
                - 10.239.8.11
                - 10.239.8.12
                - 10.239.8.13
                search:
                - maas
EOF
        
        # Apply the config
        sudo netplan apply
        
        echo "Network reconfiguration completed on $(hostname)"
        ip -br a
        ip r
    '
    
    # Check if SSH command was successful
    if [ $? -eq 0 ]; then
        echo "Successfully reconfigured networking on $server_ip"
    else
        echo "Failed to reconfigure networking on $server_ip"
    fi
    
    echo "-------------------------------------------"
done

echo "All servers processed."