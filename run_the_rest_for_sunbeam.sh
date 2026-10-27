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

for ((i=2; i<=$#; i++)); do
    ssh ${!i} "LC_ALL=C sudo apt install virtinst libvirt-daemon-system -y > /dev/null 2>&1 ; sudo usermod -a -G kvm ubuntu ; sudo usermod -a -G libvirt ubuntu ; touch done" &
done

wait_for_done "${@:2}"

nice_output "Define rest of the nodes"
for ((i=3; i<=$#; i++)); do
    data="$(get_server_data ${!i})"
    read hostname disk_size memory cpu_cores <<< "$data"
    ssh ${!i} "node=node${i} ; virt-install --print-xml --noautoconsole --virt-type kvm --boot network,hd,menu=on --name \${node} --ram ${memory}000 --vcpus ${cpu_cores} --cpu host-passthrough,cache.mode=passthrough --graphics vnc --video=cirrus --os-type linux --os-variant ubuntu24.04 --controller scsi,model=virtio-scsi,index=0 --disk path=/tmp/\${node}_1.qcow2,size=400,format=qcow2,bus=scsi,cache=writeback --disk path=/tmp/\${node}_2.qcow2,size=400,format=qcow2,bus=scsi,cache=writeback --network=bridge=br0,model=virtio --network=bridge=br0,model=virtio --network=bridge=br0,model=virtio --network=bridge=br0,model=virtio > \${node}.xml ; virsh -c qemu:///system define node${i}.xml ; touch done" &
done

wait_for_done "${@:3}"

