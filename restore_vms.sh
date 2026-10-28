#!/bin/bash
#
# Restore libvirt VMs backed up by backup_vms.sh onto cluster nodes.
#
# Usage: restore_vms.sh <list_of_IPs>
#
# Node N in the IP list gets the VMs from ${BACKUP_TARGET}/host<N>/. Keep the
# same number of nodes and the same order as during backup: the first node is
# the SDN gateway. Nodes must already have the VxLAN network (br0) set up, see
# SKIP_VM_CREATION in run_the_rest_for_sunbeam.sh.
#
# Disks are rsynced over SSH directly from the backup machine to each node,
# authenticating with the forwarded SSH agent. Domain definitions are adjusted
# to the new host (disk paths, CPU/memory if the host is smaller, machine type
# if unsupported), defined, and then all VMs are started at once.

# TODO: replace the placeholder with the real backup location
BACKUP_TARGET="${BACKUP_TARGET:-backup@backup.example.com:/srv/virtual_cluster_backup}"
VM_NETWORK="10.241.144"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <list_of_IPs>"
    exit 1
fi

function nice_output() {
    echo
    echo "***** " $1 " *****"
    echo
}

# Run a command on all nodes in parallel, fail if any of them failed
# Usage: on_all_nodes <function_name> <list_of_IPs>
function on_all_nodes() {
    local func=$1
    shift
    local pids=() failed=0
    for ((i=1; i<=$#; i++)); do
        $func $i ${!i} &
        pids+=($!)
    done
    for ((i=0; i<${#pids[@]}; i++)); do
        if ! wait ${pids[$i]}; then
            echo "FAILED on node $((i + 1)) (${@:$((i + 1)):1})"
            failed=1
        fi
    done
    return $failed
}

function restore_node() {
    ssh -A $2 "bash -s -- host$1 '$BACKUP_TARGET'" << 'EOF'
main() {
set -euo pipefail
HOST_DIR=$1
TARGET=$2
VIRSH="virsh -c qemu:///system"
IMAGE_DIR=/var/lib/libvirt/images
STAGING=~/vm_restore/${HOST_DIR}
RSYNC_SSH="ssh -o StrictHostKeyChecking=accept-new"

if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "$(hostname): no forwarded SSH agent, load a key for the backup machine with ssh-add"
    exit 1
fi

if [ ! -d /sys/class/net/br0 ]; then
    echo "$(hostname): bridge br0 does not exist, set up the VxLAN network first"
    exit 1
fi
if ! command -v virsh > /dev/null || ! command -v qemu-img > /dev/null; then
    LC_ALL=C sudo apt install virtinst libvirt-daemon-system qemu-kvm qemu-utils -y > /dev/null 2>&1
fi

rm -rf ~/vm_restore
mkdir -p ${STAGING}
rsync -a -e "${RSYNC_SSH}" --include='*.xml' --include='disks.txt' --exclude='*' \
    "${TARGET}/${HOST_DIR}/" ${STAGING}/
if ! ls ${STAGING}/*.xml > /dev/null 2>&1; then
    echo "$(hostname): no VMs in backup ${TARGET}/${HOST_DIR}"
    exit 1
fi

for xml in ${STAGING}/*.xml; do
    vm=$(basename "${xml}" .xml)
    if ${VIRSH} dominfo "${vm}" > /dev/null 2>&1; then
        echo "$(hostname): removing existing VM ${vm}"
        ${VIRSH} destroy "${vm}" > /dev/null 2>&1 || true
        ${VIRSH} undefine "${vm}" --nvram > /dev/null
    fi
done

echo "$(hostname): copying disks"
sudo mkdir -p ${IMAGE_DIR}
sudo SSH_AUTH_SOCK="${SSH_AUTH_SOCK}" rsync -aS --partial -e "${RSYNC_SSH}" \
    --exclude='*.xml' --exclude='disks.txt' "${TARGET}/${HOST_DIR}/" ${IMAGE_DIR}/

# Resources available for VMs, same reservation as in run_the_rest_for_sunbeam.sh
host_memory_kib=$(( ($(awk '/MemTotal/ {print int($2/1024/1024+0.5)}' /proc/meminfo) - 8) * 1024 * 1024 ))
host_vcpus=$(( $(nproc --all) - 2 ))
${VIRSH} capabilities > ~/vm_restore/capabilities.xml

for xml in ${STAGING}/*.xml; do
    vm=$(basename "${xml}" .xml)
    python3 - "${xml}" ${IMAGE_DIR} ${host_memory_kib} ${host_vcpus} ~/vm_restore/capabilities.xml << 'PYEOF'
import os
import sys
import xml.etree.ElementTree as ET

xml_file, image_dir, host_memory_kib, host_vcpus, caps_file = sys.argv[1:]
host_memory_kib, host_vcpus = int(host_memory_kib), int(host_vcpus)
tree = ET.parse(xml_file)
domain = tree.getroot()
name = domain.findtext("name")
devices = domain.find("devices")

# Disks were restored into image_dir under their original file names
for disk in devices.findall("disk"):
    source = disk.find("source")
    if source is not None and "file" in source.attrib:
        source.set("file", os.path.join(image_dir, os.path.basename(source.get("file"))))
    for backing in disk.findall("backingStore"):
        disk.remove(backing)

# Don't ask for more than the new host can give
for tag in ("memory", "currentMemory"):
    element = domain.find(tag)
    unit = element.get("unit", "KiB")
    if unit != "KiB":
        continue
    if int(element.text) > host_memory_kib:
        print(f"{name}: reducing {tag} from {element.text} to {host_memory_kib} KiB")
        element.text = str(host_memory_kib)
vcpu = domain.find("vcpu")
if int(vcpu.text) > host_vcpus:
    print(f"{name}: reducing vcpus from {vcpu.text} to {host_vcpus}")
    vcpu.text = str(host_vcpus)
    topology = domain.find("cpu/topology")
    if topology is not None:
        domain.find("cpu").remove(topology)

# Fall back to the generic machine type alias if this QEMU doesn't know it
os_type = domain.find("os/type")
machine = os_type.get("machine")
caps = ET.parse(caps_file).getroot()
machines = {m.text for m in caps.iter("machine")} | {
    m.get("canonical") for m in caps.iter("machine") if m.get("canonical")
}
if machine and machine not in machines:
    generic = "q35" if "q35" in machine else "pc"
    print(f"{name}: machine type {machine} not supported, using {generic}")
    os_type.set("machine", generic)

emulator = devices.find("emulator")
if emulator is not None and not os.path.exists(emulator.text):
    emulator.text = "/usr/bin/qemu-system-x86_64"

tree.write(xml_file)
PYEOF
    ${VIRSH} define "${xml}" > /dev/null
    ${VIRSH} autostart "${vm}" > /dev/null
    echo "$(hostname): defined ${vm}"
done
}
main "$@" < /dev/null
EOF
}

function start_vms() {
    ssh -n $2 'for vm in $(virsh -c qemu:///system list --inactive --name); do virsh -c qemu:///system start "$vm" ; done'
}

nice_output "Restoring VMs from ${BACKUP_TARGET}"
on_all_nodes restore_node "$@" || exit 1

nice_output "Starting all VMs"
on_all_nodes start_vms "$@" || exit 1

nice_output "Checking VMs"
# Assumes VMs created by create_vm.sh, node<N> has address 10.241.144.(100+N)
for ((i=1; i<=$#; i++)); do
    vm_ip="${VM_NETWORK}.$((100 + i))"
    if ssh -A ${!i} "for try in \$(seq 60); do ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR ubuntu@${vm_ip} true && exit 0 ; sleep 5 ; done ; exit 1"; then
        echo "${vm_ip} on ${!i} OK"
    else
        echo "WARNING: ${vm_ip} on ${!i} not reachable over SSH (check that your SSH agent key is authorized in the VM)"
    fi
done

nice_output "Restore finished"
