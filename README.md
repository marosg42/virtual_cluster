# Virtual_cluster

PoC for creating virtual cluster. This is very environment specific project I doubt anybody outside my team could benefit from it.

# Use

- deploy_with_testflinger.py <input_file>
  - requires `TESTFLINGER_CLIENT_ID` and `TESTFLINGER_SECRET_KEY`, either exported or in a `.env` file in the current directory (exported variables take precedence):
    ```
    TESTFLINGER_CLIENT_ID=my-client-id
    TESTFLINGER_SECRET_KEY=my-secret
    ```
    an access token is obtained from Testflinger and regenerated automatically when it expires
  - <input_file> is a text file with a list of queues for Testflinger, one queue per line, nothing fancy
  - start deploying 15 machines, when 11 are deployed kill the rest
- change_networking.sh <list_of_IPs>
  - <list_of_IPs> is the list from `deploy_with_testflinger.py` output
  - it will make sure only one interface is configured and it is the interface through which SSH is happening
- generate_vxlan_scripts.sh <list_of_IPs>
  - <list_of_IPs> is the list from `deploy_with_testflinger.py` output
  - it will generate a script for each server for establiching VxLan overlay
  - first node is different as it serves as a gateway
- run_the_rest.sh <list_of_IPs>
  - <list_of_IPs> is the list from `deploy_with_testflinger.py` output
  - it will scp scripts and run them to establish VxLAN
  - it will install FCE and stuff
  - install MAAS, copy all keys and similar shenanigans
