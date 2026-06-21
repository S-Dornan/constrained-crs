#!/usr/bin/env bash
# Smoke Test Controller for the OSS-CRS starvation benchmark methodology

VM1_ID=301
VM2_ID=302

# ==========================================
# Graceful Interrupt Handler
# ==========================================
cleanup() {
  echo -e "\n[!] KEYBOARD INTERRUPT DETECTED. Halting Orchestrator..."
  echo "[*] Tearing down ephemeral Cleanroom ($VM2_ID)..."
  qm stop $VM2_ID >/dev/null 2>&1 || true
  qm destroy $VM2_ID >/dev/null 2>&1 || true
  echo "[+] Cleanroom completely destroyed."
  echo "[+] Log Vault ($VM1_ID) left running to ensure final cloud sync."
  exit 1
}

# Trap Ctrl+C (SIGINT) and kill commands (SIGTERM)
trap cleanup SIGINT SIGTERM

# Define the runs based on methodology constraints: 
# "Name : Cores : RAM(MB) : NetRate(MB/s) : ConfigPath"
EXPERIMENTS=(
  "smoke_1_baseline:8:32768:20:experiment-configs/QA"
  "smoke_2_stepdown:6:24576:15:experiment-configs/QA"
  "smoke_3_stepdown:4:16384:10:experiment-configs/QA"
  "smoke_4_starved:2:8192:5:experiment-configs/QA"
)

# 15 Minutes = 900 seconds (Approx 1 hour total runtime for 4 experiments)
MAX_RUNTIME=900
POLL_INTERVAL=60

echo "Initializing Smoke Test Orchestrator..."

for EXP in "${EXPERIMENTS[@]}"; do
  IFS=':' read -r NAME CORES RAM RATE CONFIG_DIR <<< "$EXP"
  
  echo "======================================================="
  echo "STARTING SMOKE TEST: $NAME"
  echo "Constraints -> Cores: $CORES | RAM: $RAM | Net: $RATE"
  echo "======================================================="

  # 1. Build the fresh architecture using the parameterized script
  ./vm-config.sh "$CORES" "$RAM" "$RATE"

  # Prepare the unique directory on the Log Vault for this run
  qm guest exec $VM1_ID -- sudo -u ubuntu mkdir -p /home/ubuntu/vault-results/$NAME

  # 2. Inject the Fuzzer Commands via detached tmux sessions
  echo "Triggering Valkey Queue..."
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s valkey 'cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run python scripts/valkey-helper.py start'
  
  sleep 30
  
  # ====================
  # INJECT LOCAL CONFIGS
  # ====================
  echo "[*] Injecting custom offline configurations directly from Hypervisor..."
  
  # 1. Create the destination folder inside the Cleanroom
  qm guest exec $VM2_ID -- sudo -u ubuntu mkdir -p /home/ubuntu/CRSBench/experiment-configs/QA
  
  # 2. Read the local YAML on the Proxmox host, Base64 encode it, and inject it into the guest
  # Note: The path assumes run-smoketests.sh is running from inside iac/experiment-environment/
  
  B64_FINDING=$(base64 -w 0 ../../experiment-configs/QA/smoke-finding.yaml)
  qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "echo '$B64_FINDING' | base64 -d > /home/ubuntu/CRSBench/experiment-configs/QA/smoke-finding.yaml"
  
  B64_FIXING=$(base64 -w 0 ../../experiment-configs/QA/smoke-fixing.yaml)
  qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "echo '$B64_FIXING' | base64 -d > /home/ubuntu/CRSBench/experiment-configs/QA/smoke-fixing.yaml"
  
  echo "[+] Configurations successfully injected."

  # ==========================================
  # EXECUTION: The Chained Pipeline
  # ==========================================
  echo "Triggering CRSBench Worker and Runner..."
  
  # Start the background worker
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s worker "cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run crsbench worker --experiment-config $CONFIG_DIR/smoke-finding.yaml 2>&1 | sudo tee /dev/ttyS1"
  
  # Chain the runner phases (Finding -> Fixing)
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s runner "cd /home/ubuntu/CRSBench && \
    echo '[*] PHASE 1: BUG FINDING' | sudo tee -a /dev/ttyS1 && \
    /home/ubuntu/.local/bin/uv run crsbench run --experiment-config $CONFIG_DIR/smoke-finding.yaml 2>&1 | sudo tee -a /dev/ttyS1 && \
    echo '[*] PHASE 2: BUG FIXING' | sudo tee -a /dev/ttyS1 && \
    /home/ubuntu/.local/bin/uv run crsbench run --experiment-config $CONFIG_DIR/smoke-fixing.yaml 2>&1 | sudo tee -a /dev/ttyS1"
  # 3. Deterministic Polling Loop
  ELAPSED=0
  echo -n "Experiments running. Vault is logging. Monitoring progress"

  while [ $ELAPSED -lt $MAX_RUNTIME ]; do
    # Check if 'runner' is still in the active tmux session list
    if ! qm guest exec $VM2_ID -- sudo -u ubuntu tmux ls 2>/dev/null | grep -q "runner"; then
      echo "" # Clear the line
      echo "Runner session terminated (completed or crashed) at $ELAPSED seconds."
      break
    fi
    
    echo -n "."
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
  done
  echo "" # Ensure the next terminal output starts on a fresh line

  # ==========================================
  # Data Exfiltration & Log Slicing
  # ==========================================
  echo "[*] Polling loop finished. Initiating data rescue protocol..."
  
  set -x # Turn on debugging
  # Limit rsync to 2000 KB/s to prevent network interrupt panics on the Log Vault
  qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "cd /home/ubuntu/CRSBench/results && rsync -avz --bwlimit=2000 -e 'ssh -i /home/ubuntu/.ssh/id_ed25519 -o StrictHostKeyChecking=no' . ubuntu@172.16.255.20:/home/ubuntu/vault-results/$NAME/"
  set +x # Turn off debugging

  # Wait dynamically for the SSH/Rsync TCP connection to drop from ESTABLISHED
  echo -n "Waiting for network buffer flush and TCP connection closure"
  while qm guest exec $VM2_ID -- sudo -u ubuntu ss -tn 2>/dev/null | grep -q "172.16.255.20:22.*ESTABLISHED"; do
    echo -n "."
    sleep 2
  done
  echo " [DATA EXFILTRATION COMPLETE]"

  # Archive the serial telemetry into the folder, then truncate the original file so it's clean for the next run
  echo "Archiving serial telemetry for $NAME..."
  qm guest exec $VM1_ID -- bash -c "cp /home/ubuntu/experiment-telemetry.log /home/ubuntu/vault-results/$NAME/serial-console.log && > /home/ubuntu/experiment-telemetry.log"

  # 4. Evaluate and Log Host-Level Results
  if [ $ELAPSED -ge $MAX_RUNTIME ]; then
    echo "$(date) | SMOKE TEST TIMEOUT: $NAME | Exceeded 15-minute limit." >> /root/smoketest-runs.log
  else
    echo "$(date) | SMOKE TEST COMPLETED: $NAME | Finished in $ELAPSED seconds." >> /root/smoketest-runs.log
  fi
done

# ==========================================
# Final Architecture Teardown
# ==========================================
echo "======================================================="
echo "All scheduled experiments have concluded."
echo "Executing final architecture cleanup..."

qm stop $VM2_ID >/dev/null 2>&1 || true
qm destroy $VM2_ID >/dev/null 2>&1 || true

echo "[+] Ephemeral Cleanroom ($VM2_ID) destroyed."
echo "[+] Pipeline finished successfully. Log Vault is processing final syncs."