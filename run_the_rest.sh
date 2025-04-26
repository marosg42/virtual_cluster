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

nice_output "Setup MAAS VM"
ssh $1 "sudo apt install -y uvtool virtinst > /dev/null 2>&1"
ssh $1 "sudo -g libvirt uvt-simplestreams-libvirt sync release=noble arch=amd64"
data="$(get_server_data ${1})"
read hostname disk_size memory cpu_cores <<< "$data"
ssh $1 "sudo -g libvirt uvt-kvm create --machine-type ubuntu --cpu \"${cpu_cores}\" --host-passthrough --memory \"${memory}000\" --disk \"400\" --unsafe-caching --bridge br0 --network-config /dev/stdin --ssh-public-key-file ~/.ssh/id_ed25519.pub --no-start  maas << 'EOF1'
    network:
            version: 2
            ethernets:
                ens3:
                    dhcp4: false
                    dhcp6: false
                ens8:
                    dhcp4: false
                    dhcp6: false
            bridges:
                broam:
                    dhcp4: false
                    dhcp6: false
                    addresses:
                    - 10.241.144.2/21
                    interfaces:
                    - ens3
                    parameters:
                        forward-delay: \"0\"
                        stp: false
                    gateway4: 10.241.144.1
                    nameservers:
                        addresses:
                            - 10.239.8.11
                            - 10.239.8.12
                            - 10.239.8.13
                    routes:
                    -   to: 192.168.240.0/24
                        via: 10.241.144.1

                brinternal:
                    dhcp4: false
                    dhcp6: false
                    addresses:
                    - 192.168.110.2/24
                    interfaces:
                    - ens8.2743
                    mtu: 1500
                    parameters:
                        forward-delay: \"0\"
                        stp: false
            vlans:
                ens8.2743:
                    id: 2743
                    mtu: 1500
                    link: ens8
EOF1
"
ssh $1 sudo -g libvirt virsh -c qemu:///system attach-interface "maas" bridge br0 --model virtio --config
ssh $1 sudo -g libvirt virsh -c qemu:///system start "maas"

wait_for_done "${@:2}"

nice_output "Define KVM node"
data="$(get_server_data ${2})"
read hostname disk_size memory cpu_cores <<< "$data"
ssh $2 "node=nodekvm ; virt-install --print-xml --noautoconsole --virt-type kvm --boot network,hd,menu=on --name \${node} --ram ${memory}000 --vcpus ${cpu_cores} --cpu host-passthrough,cache.mode=passthrough --graphics vnc --video=cirrus --os-type linux --os-variant ubuntu24.04 --controller scsi,model=virtio-scsi,index=0 --disk path=/tmp/\${node}.qcow2,size=800,format=qcow2,bus=scsi,cache=writeback  --network=bridge=br0,model=virtio --network=bridge=br0,model=virtio --network=bridge=br0,model=virtio --network=bridge=br0,model=virtio > \${node}.xml ; virsh -c qemu:///system define \${node}.xml ; touch done" &

nice_output "Define rest of the nodes"
for ((i=3; i<=$#; i++)); do
    data="$(get_server_data ${!i})"
    read hostname disk_size memory cpu_cores <<< "$data"
    ssh ${!i} "node=node${i} ; virt-install --print-xml --noautoconsole --virt-type kvm --boot network,hd,menu=on --name \${node} --ram ${memory}000 --vcpus ${cpu_cores} --cpu host-passthrough,cache.mode=passthrough --graphics vnc --video=cirrus --os-type linux --os-variant ubuntu24.04 --controller scsi,model=virtio-scsi,index=0 --disk path=/tmp/\${node}_1.qcow2,size=400,format=qcow2,bus=scsi,cache=writeback --disk path=/tmp/\${node}_2.qcow2,size=400,format=qcow2,bus=scsi,cache=writeback --network=bridge=br0,model=virtio --network=bridge=br0,model=virtio --network=bridge=br0,model=virtio --network=bridge=br0,model=virtio > \${node}.xml ; virsh -c qemu:///system define node${i}.xml ; touch done" &
done

wait_for_done "${@:2}"


nice_output "Install FCE"

ssh -A $1 "GIT_SSH_COMMAND=\"ssh -o StrictHostKeyChecking=no\" git clone git+ssh://marosg@git.launchpad.net/cpe-foundation"
ssh -A $1 "GIT_SSH_COMMAND=\"ssh -o StrictHostKeyChecking=no\" git clone git+ssh://marosg@git.launchpad.net/solutions-qa-deployments sqa-labs ; cd sqa-labs ; git checkout solutionsqa/envs"
ssh $1 "cd cpe-foundation; sudo ./install" > /dev/null
scp -r project_caracal $1:project

nice_output "Wait for MAAS VM"
ssh $1 "while ! ping -c 1 10.241.144.2 >/dev/null ; do echo Noping; sleep 1; done"
ssh $1 "while ! ssh -o StrictHostKeyChecking=no 10.241.144.2 hostname ; do sleep 5 ; done"
ssh $1 -- ssh -o StrictHostKeyChecking=no 10.241.144.2 hostname
scp $1:.ssh/id_ed25519.pub output/

nice_output "Start MAAS installation"
ssh $1 "cd project; fce --debug build --layer maas --steps ..maas:configure_networks"
ssh $1 "scp .ssh/id_ed25519 10.241.144.2:.ssh/"


nice_output "Generate keys"
ssh $1 "ssh 10.241.144.2 sudo ssh-keygen -f  /var/snap/maas/current/root/.ssh/id_rsa -y" > output/maas_ssh_pub_key
ssh $1 "ssh 10.241.144.2 ssh-keygen -f .ssh/id_ed25519 -y" > output/ubuntu_ssh_pub_key

nice_output "Distribute keys"
for ((i=2; i<=$#; i++)); do
    scp output/id_ed25519.pub output/maas_ssh_pub_key output/ubuntu_ssh_pub_key ${!i}:
    ssh ${!i} "cat maas_ssh_pub_key >> .ssh/authorized_keys ; cat ubuntu_ssh_pub_key >> .ssh/authorized_keys ; cat id_ed25519.pub >> .ssh/authorized_keys"
done

nice_output "Run keyscan on MAAS VM"
for ((i=2; i<=$#; i++)); do
    ssh ${1} "ssh 10.241.144.2 \"ssh-keyscan 10.241.144.$((i+100)) >> .ssh/known_hosts\""
    ssh ${1} "ssh 10.241.144.2 \"ssh-keyscan 192.168.240.$((i+100)) >> .ssh/known_hosts\""
done

nice_output "Finish MAAS installation"
ssh $1 "cd project; fce --debug build --layer maas --steps enlist_nodes..configure_vms"

nice_output "Install Juju"
ssh $1 "cd project; fce --debug build --layer juju_maas_controller"
