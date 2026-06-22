#!/usr/bin/env bash
# Smoke Test Controller for the OSS-CRS starvation benchmark methodology

VM1_ID=301
VM2_ID=302
SCRIPT_DIR=$(dirname "$0")

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
  "l16-smoke_1_baseline:8:32768:20:experiment-configs/L16-QA:smoke-finding.yaml:smoke-fixing.yaml"
  "l16-smoke_2_stepdown:6:24576:15:experiment-configs/L16-QA:smoke-finding.yaml:smoke-fixing.yaml"
  "l16-smoke_3_stepdown:4:16384:10:experiment-configs/L16-QA:smoke-finding.yaml:smoke-fixing.yaml"
  "l16-smoke_4_starved:2:8192:5:experiment-configs/L16-QA:smoke-finding.yaml:smoke-fixing.yaml"
)

# 15 Minutes = 900 seconds (Approx 1 hour total runtime for 4 experiments)
MAX_RUNTIME=900
POLL_INTERVAL=60

echo "Initializing Smoke Test Orchestrator..."

for EXP in "${EXPERIMENTS[@]}"; do
  # 1. Parse the array
  IFS=':' read -r NAME CORES RAM RATE REL_DIR FIND_YAML FIX_YAML <<< "$EXP"
  
  # 2. Define Guest Paths (Absolute paths inside the Cleanroom)
  GUEST_DIR="/home/ubuntu/$REL_DIR"
  FIND_CONFIG="$GUEST_DIR/$FIND_YAML"
  FIX_CONFIG="$GUEST_DIR/$FIX_YAML"
  
  # 3. Define Host Paths (Where the files live on your Proxmox server)
  HOST_FIND="$SCRIPT_DIR/$REL_DIR/$FIND_YAML"
  HOST_FIX="$SCRIPT_DIR/$REL_DIR/$FIX_YAML"

  echo "======================================================="
  echo "STARTING CHAINED SMOKE TEST: $NAME"
  echo "Constraints -> Cores: $CORES | RAM: $RAM | Net: $RATE"
  echo "======================================================="

  # Build the fresh architecture using the parameterized script
  ./vm-config.sh "$CORES" "$RAM" "$RATE"

  # Prepare the unique directory on the Log Vault for this run
  qm guest exec $VM1_ID -- sudo -u ubuntu mkdir -p /home/ubuntu/vault-results/$NAME

  # Start the Valkey Queue
  echo "Triggering Valkey Queue..."
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s valkey 'cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run python scripts/valkey-helper.py start'
  
  sleep 30
  
  # ====================
  # THE NEW VARIABLE: Dual Absolute Path Injection
  # ====================
  echo "[*] Injecting offline configurations into absolute safe-path..."
  
  # Create the destination folder in the guest
  qm guest exec $VM2_ID -- sudo -u ubuntu mkdir -p "$GUEST_DIR"
  
  # Base64 encode from the HOST, decode into the GUEST
  B64_FIND=$(base64 -w 0 "$HOST_FIND")
  qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "echo '$B64_FIND' | base64 -d > $FIND_CONFIG"

  B64_FIX=$(base64 -w 0 "$HOST_FIX")
  qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "echo '$B64_FIX' | base64 -d > $FIX_CONFIG"

  echo "[+] Configurations successfully injected to $GUEST_DIR"

  # ==========================================
  # EXECUTION: Chained Phases
  # ==========================================
  echo "Triggering CRSBench Worker and Runner..."
  
  # The Worker daemon only needs the Finding config to initialize
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s worker "cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run crsbench worker --experiment-config $FIND_CONFIG 2>&1 | sudo tee /dev/ttyS1"
  
  # The Runner actively chains Phase 1 (Finding) into Phase 2 (Fixing)
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s runner "cd /home/ubuntu/CRSBench && \
    echo '[*] PHASE 1: BUG FINDING' | sudo tee -a /dev/ttyS1 && \
    /home/ubuntu/.local/bin/uv run crsbench run --experiment-config $FIND_CONFIG 2>&1 | sudo tee -a /dev/ttyS1 && \
    echo '[*] PHASE 2: BUG FIXING' | sudo tee -a /dev/ttyS1 && \
    /home/ubuntu/.local/bin/uv run crsbench run --experiment-config $FIX_CONFIG 2>&1 | sudo tee -a /dev/ttyS1"

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
  # NEW: Secure Data Exfiltration & Log Slicing
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