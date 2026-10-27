#!/bin/bash

# Set variables
DEPLOY_SCRIPT="deploy_with_testflinger.py"
SERVER_FILE="servers.txt"
AGENT_LIMIT=10
COMPLETION_THRESHOLD=7
OUTPUT_DIR="output"
IP_FILE="${OUTPUT_DIR}/ips.txt"
DEPLOY_OUTPUT="${OUTPUT_DIR}/deploy_output.txt"

# Step 1: Run deploy_with_testflinger.py
echo "Running deployment script..."
mkdir -p "$OUTPUT_DIR"
# stdout holds the results; the last line is the space-separated list of IPs
python3 $DEPLOY_SCRIPT $SERVER_FILE --agent-limit $AGENT_LIMIT --completion-threshold $COMPLETION_THRESHOLD | tee "$DEPLOY_OUTPUT"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "Deployment script failed. Exiting."
    exit 1
fi

# Step 2: Extract IPs from the output
echo "Extracting IPs from deployment output..."
tail -n 1 "$DEPLOY_OUTPUT" | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' > $IP_FILE
if [ ! -s $IP_FILE ]; then
    echo "No IPs found in deployment output. Exiting."
    exit 1
fi
echo "Extracted IPs:"
cat $IP_FILE

# Step 3: Run change_networking.sh
echo "Running change_networking.sh..."
./change_networking.sh $(cat $IP_FILE)
if [ $? -ne 0 ]; then
    echo "change_networking.sh failed. Exiting."
    exit 1
fi

# Step 4: Run generate_vxlan_scripts.sh
echo "Running generate_vxlan_scripts.sh..."
./generate_vxlan_scripts.sh $(cat $IP_FILE)
if [ $? -ne 0 ]; then
    echo "generate_vxlan_scripts.sh failed. Exiting."
    exit 1
fi

# Step 5: Run run_the_rest.sh
echo "Running run_the_rest.sh..."
./run_the_rest_for_sunbeam.sh $(cat $IP_FILE)
if [ $? -ne 0 ]; then
    echo "run_the_rest.sh failed. Exiting."
    exit 1
fi

echo "Wrapper script completed successfully."
