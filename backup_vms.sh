#!/bin/bash
#
# Back up all libvirt VMs from the cluster nodes to a remote machine.
#
# Usage: backup_vms.sh <list_of_IPs>
#
# All VMs on all nodes are powered off at once (not gracefully), then each node
# rsyncs its VM disks and domain definitions over SSH directly to
# ${BACKUP_TARGET}/host<N>/, N being the position of the node in the IP list.
# Overlay disks are flattened first so backups don't depend on a base image.
#
# Nodes authenticate to the backup machine with the forwarded SSH agent, so
# a key accepted by the backup machine must be loaded in the local ssh-agent.

# TODO: replace the placeholder with the real backup location
BACKUP_TARGET="${BACKUP_TARGET:-backup@backup.example.com:/srv/virtual_cluster_backup}"

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

function stop_vms() {
    ssh -n $2 'for vm in $(virsh -c qemu:///system list --name); do virsh -c qemu:///system destroy "$vm" ; done'
}

function backup_node() {
    ssh -A $2 "bash -s -- host$1 '$BACKUP_TARGET'" << 'EOF'
main() {
set -euo pipefail
HOST_DIR=$1
TARGET=$2
VIRSH="virsh -c qemu:///system"
STAGING=~/vm_backup/${HOST_DIR}
RSYNC_SSH="ssh -o StrictHostKeyChecking=accept-new"

if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "$(hostname): no forwarded SSH agent, load a key for the backup machine with ssh-add"
    exit 1
fi

rm -rf ~/vm_backup
mkdir -p ${STAGING}
for vm in $(${VIRSH} list --all --name); do
    echo "$(hostname): backing up ${vm}"
    ${VIRSH} dumpxml --inactive --security-info "${vm}" > ${STAGING}/${vm}.xml
    for disk in $(${VIRSH} domblklist "${vm}" --details | awk '$1 == "file" && ($2 == "disk" || $2 == "cdrom") {print $4}'); do
        if sudo qemu-img info --output=json "${disk}" | grep -q '"backing-filename"'; then
            echo "$(hostname): flattening ${disk}"
            sudo qemu-img rebase -f qcow2 -b "" "${disk}"
        fi
        echo "${disk}" >> ${STAGING}/disks.txt
    done
done

# Domain definitions first so TARGET/host<N> gets created, then the disks
rsync -a -e "${RSYNC_SSH}" ${STAGING} "${TARGET}/"
if [ -f ${STAGING}/disks.txt ]; then
    sudo SSH_AUTH_SOCK="${SSH_AUTH_SOCK}" rsync -aS --partial --no-relative -e "${RSYNC_SSH}" \
        --files-from=${STAGING}/disks.txt / "${TARGET}/${HOST_DIR}/"
fi
echo "$(hostname): backup finished"
}
main "$@" < /dev/null
EOF
}

nice_output "Stopping all VMs"
on_all_nodes stop_vms "$@" || exit 1

nice_output "Backing up VMs to ${BACKUP_TARGET}"
on_all_nodes backup_node "$@" || exit 1

nice_output "Backup finished"
