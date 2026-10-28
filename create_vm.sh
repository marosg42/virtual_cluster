#!/bin/bash
#
# Runs on a cluster node: creates and starts an Ubuntu 24.04 VM attached to
# the VxLAN bridge br0 with a static IP configured by cloud-init.
#
# Usage: create_vm.sh <name> <address/prefix> <gateway> <mac> <memory_mb> <vcpus> <dns,dns,...>
#
# SSH keys authorized for the default "ubuntu" user in the VM are this node's
# ~/.ssh/authorized_keys plus ~/hosts_ed25519.pub (keys of all cluster nodes).

set -euo pipefail

NAME=$1
ADDRESS=$2
GATEWAY=$3
MAC=$4
MEMORY=$5
VCPUS=$6
DNS=$7

IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_DIR="/var/lib/libvirt/images"
BASE_IMAGE="${IMAGE_DIR}/noble-server-cloudimg-amd64.img"
ROOT_DISK="${IMAGE_DIR}/${NAME}.qcow2"
DATA_DISK="${IMAGE_DIR}/${NAME}-data.qcow2"
SEED_ISO="${IMAGE_DIR}/${NAME}-seed.iso"
ROOT_DISK_SIZE="400G"
DATA_DISK_SIZE_GB=400
VIRSH="virsh -c qemu:///system"

# VxLAN encapsulation lowers the MTU of br0, the VM must not exceed it
MTU=$(cat /sys/class/net/br0/mtu)

if ${VIRSH} dominfo "${NAME}" > /dev/null 2>&1; then
    echo "Removing existing VM ${NAME}"
    ${VIRSH} destroy "${NAME}" > /dev/null 2>&1 || true
    ${VIRSH} undefine "${NAME}" > /dev/null
fi
sudo rm -f "${ROOT_DISK}" "${DATA_DISK}" "${SEED_ISO}"

if [ ! -f "${BASE_IMAGE}" ]; then
    sudo wget -q -O "${BASE_IMAGE}.tmp" "${IMAGE_URL}"
    sudo mv "${BASE_IMAGE}.tmp" "${BASE_IMAGE}"
fi

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

cat > "${work}/meta-data" << EOF
instance-id: ${NAME}
local-hostname: ${NAME}
EOF

{
    echo "#cloud-config"
    echo "hostname: ${NAME}"
    echo "ssh_authorized_keys:"
    cat ~/.ssh/authorized_keys ~/hosts_ed25519.pub 2> /dev/null \
        | grep -E '^(ssh|ecdsa)-' | sort -u | sed 's/^/  - /'
} > "${work}/user-data"

cat > "${work}/network-config" << EOF
version: 2
ethernets:
  primary:
    match:
      macaddress: "${MAC}"
    set-name: ens3
    mtu: ${MTU}
    dhcp4: false
    dhcp6: false
    addresses:
      - ${ADDRESS}
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      addresses: [${DNS}]
EOF

sudo cloud-localds -N "${work}/network-config" "${SEED_ISO}" \
    "${work}/user-data" "${work}/meta-data"
sudo qemu-img create -q -f qcow2 -F qcow2 -b "${BASE_IMAGE}" "${ROOT_DISK}" "${ROOT_DISK_SIZE}"

virt-install --connect qemu:///system --import --noautoconsole \
    --name "${NAME}" --memory "${MEMORY}" --vcpus "${VCPUS}" \
    --cpu host-passthrough,cache.mode=passthrough \
    --os-variant ubuntu24.04 --graphics vnc \
    --controller scsi,model=virtio-scsi,index=0 \
    --disk "path=${ROOT_DISK},format=qcow2,bus=scsi,cache=writeback" \
    --disk "path=${DATA_DISK},size=${DATA_DISK_SIZE_GB},format=qcow2,bus=scsi,cache=writeback" \
    --disk "path=${SEED_ISO},device=cdrom" \
    --network "bridge=br0,model=virtio,mac=${MAC}" \
    --network bridge=br0,model=virtio \
    --network bridge=br0,model=virtio \
    --network bridge=br0,model=virtio

${VIRSH} autostart "${NAME}" > /dev/null
echo "VM ${NAME} started with address ${ADDRESS}"
