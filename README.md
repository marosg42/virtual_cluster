# Virtual_cluster

PoC for creating virtual cluster. This is very environment specific project I doubt anybody outside my team could benefit from it.

# Use

- deploy_with_testflinger.py <input_file> [--count N]
  - requires `TESTFLINGER_CLIENT_ID` and `TESTFLINGER_SECRET_KEY`, either exported or in a `.env` file in the current directory (exported variables take precedence):
    ```
    TESTFLINGER_CLIENT_ID=my-client-id
    TESTFLINGER_SECRET_KEY=my-secret
    ```
    an access token is obtained from Testflinger and regenerated automatically when it expires
  - <input_file> is a text file with a list of queues for Testflinger, one queue per line, nothing fancy
  - deploys exactly N machines (`--count`, default 3)
    - only agents in `waiting` state with at most 2 consecutive provisioning failures are used
    - if not enough agents are available it waits 10 minutes and retries (3 times)
    - machines that fail to deploy are cancelled and the missing number is redeployed on agents not tried yet, up to 3 rounds
    - on failure all jobs are cancelled; `cancel.sh` is kept up to date with all submitted jobs
- change_networking.sh <list_of_IPs>
  - <list_of_IPs> is the list from `deploy_with_testflinger.py` output
  - it will make sure only one interface is configured and it is the interface through which SSH is happening
- generate_vxlan_scripts.sh <list_of_IPs>
  - <list_of_IPs> is the list from `deploy_with_testflinger.py` output
  - it will generate a script for each server for establiching VxLan overlay
  - first node is different as it serves as a gateway
- run_the_rest_for_sunbeam.sh <list_of_IPs>
  - <list_of_IPs> is the list from `deploy_with_testflinger.py` output
  - it will scp scripts and run them to establish VxLAN
  - it will install libvirt and create an identical Ubuntu 24.04 VM `node<N>` on every node using `create_vm.sh`
    - there is no DHCP on the SDN, each VM gets a static IP `10.241.144.(100+N)/21` via cloud-init, gateway `10.241.144.1` (first node, which NATs to the outside world)
    - DNS servers are taken from the first node, MTU from `br0`
    - root disk 400G (cloud image), extra empty 400G data disk, 4 NICs on `br0` (only the first is configured)
    - SSH keys of all nodes and the keys authorized on the host are allowed for user `ubuntu` in the VM
    - VM IPs are written to `output/vm_ips.txt`, the script fails if any VM is not reachable over SSH
- wrapper_script_sunbeam.sh
  - runs all of the above in order, using queues from `servers.txt`
- backup_vms.sh <list_of_IPs>
  - powers off all VMs on all nodes at once (not gracefully) and leaves them stopped
  - flattens overlay disks so they don't depend on the cloud image, then each node rsyncs its VM disks and domain definitions over SSH to `$BACKUP_TARGET/host<N>/` (N = position in the IP list)
  - `BACKUP_TARGET` defaults to a placeholder in the script, override it from the environment, e.g. `BACKUP_TARGET=user@host:/path`
  - nodes authenticate to the backup machine with your forwarded SSH agent, the key must be loaded with `ssh-add`
- restore_vms.sh <list_of_IPs>
  - use the same number of nodes and the same order as for the backup, the first node is the SDN gateway
  - prepare fresh nodes first without creating new VMs: `SKIP_VM_CREATION=1 ./run_the_rest_for_sunbeam.sh <list_of_IPs>` (after `change_networking.sh` and `generate_vxlan_scripts.sh`)
  - rsyncs `$BACKUP_TARGET/host<N>/` to node N, adjusts domain definitions (disk paths, CPU/memory if the new host is smaller, machine type if unsupported), defines the VMs and starts all of them at once
