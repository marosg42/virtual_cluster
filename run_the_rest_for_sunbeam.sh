#!/bin/bash

function get_server_data() {
    result=$(ssh "$1" '
        hostname_val=$(hostname)
        
        # Get root disk size in GB (rounded to nearest integer)
        disk_size=$(df -BG / | awk "NR==2 {print \$2}" | sed "s/G//")
        
        # Get total memory in GB (rounded to nearest integer)
        mem_total=$(grep MemTotal /proc/meminfo | awk "{print int(\$2/1024/1024+0.5)}")
        
        # Get number of CPU cores
        cpu_cores=$(grep -c "^processor" /proc/cpuinfo)
        
        # Apply the adjustments
        adjusted_disk_size=$((disk_size - 50))
        if [ $adjusted_disk_size -lt 0 ]; then adjusted_disk_size=0; fi
        
        adjusted_mem_total=$((mem_total - 8))
        if [ $adjusted_mem_total -lt 0 ]; then adjusted_mem_total=0; fi
        
        adjusted_cpu_cores=$((cpu_cores - 2))
        if [ $adjusted_cpu_cores -lt 0 ]; then adjusted_cpu_cores=0; fi
        
        echo "$hostname_val $adjusted_disk_size $adjusted_mem_total $adjusted_cpu_cores"
    ')
    echo "$result"
}

function nice_output() {
    echo
    echo "***** " $1 " *****"
    echo
}

function wait_for_done() {
    nice_output "Waiting for tasks to finish"
    for ip in $* ; do
        while true; do
            if ssh "$ip" "test -f done"; then
                nice_output "Task finished in $ip"
                break
            fi
            sleep 2
        done
    done
    for ip in $* ; do
        ssh "$ip" "rm done"
    done
    nice_output "All tasks finished"
}

export LC_ALL=C
# ssh ${1} wget https://github.com/babs/multiping/releases/download/v1.5.0/multiping-linux-amd64.xz
# ssh ${1} unxz multiping-linux-amd64.xz
# ssh ${1} chmod +x multiping-linux-amd64
# # sudo ./multiping-linux-amd64  192.168.240.10{1..7} 10.241.144.{1..2} 10.241.144.{102..107}

nice_output "Copy setup scripts"
for ((i=1; i<=$#; i++)); do
    echo "- ${!i}"
    scp vxlan_scripts/setup_${!i}.sh ${!i}:
done

nice_output "Setup servers"
for ((i=1; i<=$#; i++)) ; do
    ssh ${!i} "./setup_${!i}.sh ; touch done" &
done

wait_for_done $*

nice_output "Install libvirt on all nodes"
for ((i=1; i<=$#; i++)); do
    ssh ${!i} "LC_ALL=C sudo apt install virtinst libvirt-daemon-system qemu-kvm qemu-utils cloud-image-utils wget -y > /dev/null 2>&1 ; sudo usermod -a -G kvm ubuntu ; sudo usermod -a -G libvirt ubuntu ; touch done" &
done

wait_for_done $*

# Prepare nodes only (network + libvirt), e.g. before restore_vms.sh
if [ "${SKIP_VM_CREATION:-0}" = 1 ]; then
    nice_output "Skipping VM creation"
    exit 0
fi

# VMs get static IPs on the untagged SDN network, the first node is the gateway
VM_NETWORK="10.241.144"
VM_PREFIX=21
VM_GATEWAY="${VM_NETWORK}.1"
# VM traffic leaves through the gateway node, so use its upstream resolvers
VM_DNS=$(ssh $1 "grep -h '^nameserver' /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null | awk '{print \$2}' | grep -v '^127\.' | sort -u | paste -sd,")
if [ -z "$VM_DNS" ]; then
    echo "Could not determine DNS servers on $1. Exiting."
    exit 1
fi
mkdir -p output
VM_IPS_FILE="output/vm_ips.txt"

nice_output "Distribute node keys"
for ((i=1; i<=$#; i++)); do
    ssh ${!i} "cat .ssh/id_ed25519.pub"
done > output/hosts_ed25519.pub
for ((i=1; i<=$#; i++)); do
    scp output/hosts_ed25519.pub create_vm.sh ${!i}:
done

nice_output "Create Ubuntu 24.04 VM on all nodes"
: > "$VM_IPS_FILE"
for ((i=1; i<=$#; i++)); do
    data="$(get_server_data ${!i})"
    read hostname disk_size memory cpu_cores <<< "$data"
    vm_ip="${VM_NETWORK}.$((100 + i))"
    vm_mac=$(printf "52:54:00:f0:00:%02x" $i)
    echo "$vm_ip" >> "$VM_IPS_FILE"
    echo "- node${i} on ${!i}: ${vm_ip}"
    ssh ${!i} "./create_vm.sh node${i} ${vm_ip}/${VM_PREFIX} ${VM_GATEWAY} ${vm_mac} $((memory * 1024)) ${cpu_cores} ${VM_DNS} ; touch done" &
done

wait_for_done $*

nice_output "Wait for VMs to boot"
for ((i=1; i<=$#; i++)); do
    vm_ip="${VM_NETWORK}.$((100 + i))"
    ssh ${!i} "for try in \$(seq 120); do ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR ubuntu@${vm_ip} 'cloud-init status --wait > /dev/null ; hostname' && break ; sleep 5 ; done ; touch done" &
done

wait_for_done $*

nice_output "VMs"
failed=0
for ((i=1; i<=$#; i++)); do
    vm_ip="${VM_NETWORK}.$((100 + i))"
    if ssh ${!i} "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR ubuntu@${vm_ip} true"; then
        echo "node${i} ${vm_ip} (host ${!i}) OK"
    else
        echo "node${i} ${vm_ip} (host ${!i}) NOT REACHABLE"
        failed=1
    fi
done
exit $failed
