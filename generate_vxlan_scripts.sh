#!/bin/bash

OUTPUT_DIR="vxlan_scripts"
rm -rf ${OUTPUT_DIR}
mkdir -p ${OUTPUT_DIR}
echo "Creating scripts in directory: ${OUTPUT_DIR}"

OVERLAY_NETWORK="192.168.240"
VNI=100
VXLAN_PORT=4789

declare -a SERVER_IPS=("$@")
TOTAL_SERVERS=${#SERVER_IPS[@]}

for ((i=0; i<TOTAL_SERVERS; i++)); do
    SERVER_IP=${SERVER_IPS[$i]}
    OVERLAY_IP="${OVERLAY_NETWORK}.$((i+101))"
    SCRIPT_FILE="${OUTPUT_DIR}/setup_${SERVER_IP}.sh"
    cat > ${SCRIPT_FILE} << EOF

# Install required packages
sudo apt update > /dev/null 2>&1
sudo apt install -y bridge-utils vlan > /dev/null 2>&1

# Load required kernel modules
sudo modprobe vxlan
sudo modprobe bridge
sudo modprobe 8021q

# Create bridge for VxLAN traffic
sudo ip link add br0 type bridge
sudo ip link set br0 up

# Create VxLAN interface
sudo ip link add vxlan${VNI} type vxlan id ${VNI} local ${SERVER_IP} dstport ${VXLAN_PORT}
sudo ip link set vxlan${VNI} up
sudo ip link set vxlan${VNI} master br0

# Assign overlay IP
sudo ip addr add ${OVERLAY_IP}/24 dev br0

# Add FDB entries for all other servers
EOF
    
    # Add FDB entries
    for ((j=0; j<TOTAL_SERVERS; j++)); do
        if [ $i -ne $j ]; then
            echo "sudo bridge fdb append 00:00:00:00:00:00 dev vxlan${VNI} dst ${SERVER_IPS[$j]}" >> ${SCRIPT_FILE}
        fi
    done
    
    # Add verification section
    cat >> ${SCRIPT_FILE} << EOF

EOF

    cat >> ${SCRIPT_FILE} << EOF

sudo ip link add link br0 name br0.2743 type vlan id 2743
sudo ip link add link br0 name br0.2744 type vlan id 2744
sudo ip link add link br0 name br0.2745 type vlan id 2745
sudo ip link add link br0 name br0.2746 type vlan id 2746
sudo ip link add link br0 name br0.101 type vlan id 101
sudo ip link set dev br0.2743 up
sudo ip link set dev br0.2744 up
sudo ip link set dev br0.2745 up
sudo ip link set dev br0.2746 up
sudo ip link set dev br0.101 up
sudo ip route add 10.241.144.0/21 dev br0
EOF

if [[ ${i} == 0 ]]; then
    cat >> ${SCRIPT_FILE} << EOF
sudo ip addr add 10.241.144.1/21 dev br0
sudo ip addr add 192.168.110.1/24 dev br0.2743
sudo ip addr add 192.168.112.1/24 dev br0.2746
sudo ip addr add 10.242.10.1/24 dev br0.101
sudo ip addr add 192.168.111.1/24 dev br0.2745
sudo ip addr add 10.243.10.1/24 dev br0.2744

# # Allow 10.241.144.0 to reach outside world
# interface=\$(ip -o addr show | grep "inet ${SERVER_IP}" | cut -f2 -d" ")
# sudo iptables -t nat -A POSTROUTING -s 10.241.144.0/21 -o \${interface} -j MASQUERADE

VXLAN_SUBNET="192.168.240.0/24"
VM_SUBNET="10.241.144.0/21"
sudo ip route add \$VXLAN_SUBNET dev br0 src 192.168.240.101
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
sudo iptables -A FORWARD -s \$VM_SUBNET -d \$VXLAN_SUBNET -j ACCEPT
sudo iptables -A FORWARD -s \$VXLAN_SUBNET -d \$VM_SUBNET -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s \$VM_SUBNET ! -d \$VXLAN_SUBNET -j MASQUERADE
VM_SUBNET="10.243.10.0/24"
sudo iptables -A FORWARD -s \$VM_SUBNET -d \$VXLAN_SUBNET -j ACCEPT
sudo iptables -A FORWARD -s \$VXLAN_SUBNET -d \$VM_SUBNET -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s \$VM_SUBNET ! -d \$VXLAN_SUBNET -j MASQUERADE
EOF
fi

    cat >> ${SCRIPT_FILE} << EOF
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' > /dev/null 2>&1
ssh-keygen -t rsa -f ~/.ssh/id_rsa -N '' > /dev/null 2>&1
EOF

    chmod +x ${SCRIPT_FILE}
    
    echo "Created setup script for ${SERVER_IP}: ${SCRIPT_FILE}"
done


for ((i=0; i<TOTAL_SERVERS; i++)); do
    SERVER_IP=${SERVER_IPS[$i]}
    OVERLAY_IP="${OVERLAY_NETWORK}.$((i+101))"
    echo "- \`setup_${SERVER_IP}.sh\`: Sets up server ${SERVER_IP} with overlay IP ${OVERLAY_IP}" >> ${OUTPUT_DIR}/README.md
done

echo "All scripts have been generated in the ${OUTPUT_DIR} directory"


