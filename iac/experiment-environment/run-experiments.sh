#!/usr/bin/env bash
# Experiment Controller for the OSS-CRS starvation benchmark methodology

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
# Taguchi L16 Orthogonal Array
EXPERIMENTS=(
  # Peak CPU Group
  "L16_01_baseline:8:32768:20:experiment-configs/L16-testing/run.yaml"
  "L16_02_stepdown:8:24576:15:experiment-configs/L16-testing/run.yaml"
  "L16_03_stepdown:8:16384:10:experiment-configs/L16-testing/run.yaml"
  "L16_04_starved:8:8192:5:experiment-configs/L16-testing/run.yaml"

  # High-Mid CPU Group
  "L16_05_stepdown:6:24576:20:experiment-configs/L16-testing/run.yaml"
  "L16_06_baseline:6:32768:15:experiment-configs/L16-testing/run.yaml"
  "L16_07_starved:6:8192:10:experiment-configs/L16-testing/run.yaml"
  "L16_08_stepdown:6:16384:5:experiment-configs/L16-testing/run.yaml"

  # Low-Mid CPU Group
  "L16_09_stepdown:4:16384:20:experiment-configs/L16-testing/run.yaml"
  "L16_10_starved:4:8192:15:experiment-configs/L16-testing/run.yaml"
  "L16_11_baseline:4:32768:10:experiment-configs/L16-testing/run.yaml"
  "L16_12_stepdown:4:24576:5:experiment-configs/L16-testing/run.yaml"

  # Starved CPU Group
  "L16_13_starved:2:8192:20:experiment-configs/L16-testing/run.yaml"
  "L16_14_stepdown:2:16384:15:experiment-configs/L16-testing/run.yaml"
  "L16_15_stepdown:2:24576:10:experiment-configs/L16-testing/run.yaml"
  "L16_16_baseline:2:32768:5:experiment-configs/L16-testing/run.yaml"
)

# 24 Hours = 86400 seconds (Approx 384 hours total runtime for 16 experiments)
MAX_RUNTIME=86400
POLL_INTERVAL=60

echo "Initializing Experiment Orchestrator..."

for EXP in "${EXPERIMENTS[@]}"; do
  IFS=':' read -r NAME CORES RAM RATE CONFIG <<< "$EXP"
  
  echo "======================================================="
  echo "STARTING EXPERIMENT: $NAME"
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
  
  echo "Triggering CRSBench Worker and Runner..."
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s worker "cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run crsbench worker --experiment-config $CONFIG 2>&1 | sudo tee /dev/ttyS1"
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s runner "cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run crsbench run --experiment-config $CONFIG 2>&1 | sudo tee /dev/ttyS1"

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

  # Push the structured trial framework artifacts over the isolated backplane using the injected SSH key
  echo "Exfiltrating structured framework artifacts to Log Vault..."
  qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "cd /home/ubuntu/CRSBench/results && rsync -avz -e 'ssh -i /home/ubuntu/.ssh/id_ed25519 -o StrictHostKeyChecking=no' . ubuntu@172.16.255.20:/home/ubuntu/vault-results/$NAME/"

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
    echo "$(date) | EXPERIMENT TIMEOUT: $NAME | Exceeded 15-minute limit." >> /root/experiment-runs.log
  else
    echo "$(date) | EXPERIMENT COMPLETED: $NAME | Finished in $ELAPSED seconds." >> /root/experiment-runs.log
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