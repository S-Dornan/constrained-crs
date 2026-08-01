#!/usr/bin/env bash
# Smoke Test Controller for the OSS-CRS starvation benchmark methodology

# ==========================================
# Load Environment Variables
# ==========================================
if [ -f ".env" ]; then
  source .env
else
  echo "[!] FATAL: .env file not found. Cannot load Proxmox configuration."
  exit 1
fi

SCRIPT_DIR=$(dirname "$0")

# Extract raw IP without CIDR notation for Rsync targets
VM1_IP_RAW=${VM1_IP%/*}

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
  # Peak CPU Group
  "throwaway-L16_03_stepdown:8:16384:10:experiment-configs/L16-testing:L16-finding-8c.yaml:L16-fixing-8c.yaml"
  "throwaway2-L16_03_stepdown:8:16384:10:experiment-configs/L16-testing:L16-finding-8c.yaml:L16-fixing-8c.yaml"
  "rerun-L16_01_baseline:8:32768:20:experiment-configs/L16-testing:L16-finding-8c.yaml:L16-fixing-8c.yaml"
  "rerun-L16_02_stepdown:8:24576:15:experiment-configs/L16-testing:L16-finding-8c.yaml:L16-fixing-8c.yaml"

  # High-Mid CPU Group
  "throwaway-L16_05_stepdown:6:24576:20:experiment-configs/L16-testing:L16-finding-6c.yaml:L16-fixing-6c.yaml"
  "rerun-L16_06_baseline:6:32768:15:experiment-configs/L16-testing:L16-finding-6c.yaml:L16-fixing-6c.yaml"

  # Low-Mid CPU Group
  "throwaway-L16_09_stepdown:4:16384:20:experiment-configs/L16-testing:L16-finding-4c.yaml:L16-fixing-4c.yaml"
  "rerun-L16_12_stepdown:4:24576:5:experiment-configs/L16-testing:L16-finding-4c.yaml:L16-fixing-4c.yaml"

  # Starved CPU Group
  "rerun-L16_13_starved:2:8192:20:experiment-configs/L16-testing:L16-finding-2c.yaml:L16-fixing-2c.yaml"
  "rerun-L16_15_stepdown:2:24576:10:experiment-configs/L16-testing:L16-finding-2c.yaml:L16-fixing-2c.yaml"
  "throwaway-L16_16_baseline:2:32768:5:experiment-configs/L16-testing:L16-finding-2c.yaml:L16-fixing-2c.yaml"
)

# 15 Minutes = 900 seconds (Approx 1 hour total runtime for 4 experiments)
MAX_RUNTIME=86400
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

  # ====================
  # NEW: Wait for Guest OS (With Circuit Breaker)
  # ====================
  echo -n "[*] Waiting for QEMU Guest Agent to boot"
  MAX_RETRIES=90 # 3 minutes total wait time
  RETRY_COUNT=0

  until qm agent "$VM2_ID" ping >/dev/null 2>&1; do
    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
      echo " [TIMEOUT]"
      echo "Error: Guest Agent on VM $VM2_ID failed to respond within 180 seconds."
      exit 1 # Or trigger your cleanup() function here if you want it to teardown and continue
    fi
    
    echo -n "."
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT + 1))
  done

  echo " [ONLINE]"
  
  # Give Cloud-Init an extra 15 seconds to finish mounting directories after the agent boots
  sleep 15

  # Prepare the unique directory on the Log Vault for this run
  qm guest exec $VM1_ID -- sudo -u ubuntu mkdir -p /home/ubuntu/vault-results/$NAME

  # DROP THE FAILSAFE: Seed the serial log so rclone GUARANTEES a sync
  qm guest exec $VM1_ID -- sudo -u ubuntu bash -c "echo 'STATUS: RUN INITIALIZED' > /home/ubuntu/vault-results/$NAME/serial-console.log"

  # DROP THE STATE TRACKER: Update the global pointer for immediate visibility
  qm guest exec $VM1_ID -- sudo -u ubuntu bash -c "echo 'ACTIVE EXPERIMENT: $NAME' > /home/ubuntu/vault-results/current-run.txt"

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
  # [MODIFIED: Added tee intercept to write crash-log.txt to local SSD]
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s runner "cd /home/ubuntu/CRSBench && \
    echo '[*] PHASE 1: BUG FINDING' | tee -a /home/ubuntu/crash-log.txt | sudo tee -a /dev/ttyS1 && \
    /home/ubuntu/.local/bin/uv run crsbench run --experiment-config $FIND_CONFIG 2>&1 | tee -a /home/ubuntu/crash-log.txt | sudo tee -a /dev/ttyS1 && \
    echo '[*] PHASE 2: BUG FIXING' | tee -a /home/ubuntu/crash-log.txt | sudo tee -a /dev/ttyS1 && \
    /home/ubuntu/.local/bin/uv run crsbench run --experiment-config $FIX_CONFIG 2>&1 | tee -a /home/ubuntu/crash-log.txt | sudo tee -a /dev/ttyS1"

  # 3. Deterministic Polling Loop with 30-Minute Atomic Snapshots
  ELAPSED=0
  AGENT_STRIKES=0
  STRIKE_LIMIT=10 # 10 consecutive failures = 10 minutes of unresponsiveness
  
  echo -n "Experiments running. Vault is logging. Monitoring progress"

  while [ $ELAPSED -lt $MAX_RUNTIME ]; do
    
    # 1. Independent Agent Health Check with Strike Counter
    if ! qm agent "$VM2_ID" ping >/dev/null 2>&1; then
      AGENT_STRIKES=$((AGENT_STRIKES + 1))
      echo -n "[Agent Stutter: Strike $AGENT_STRIKES]"
      
      # If we hit the strike limit, the VM is a Zombie. Execute Forensic Reboot.
      if [ "$AGENT_STRIKES" -ge "$STRIKE_LIMIT" ]; then
        echo ""
        echo "[FATAL] Guest Agent dead for $STRIKE_LIMIT consecutive checks. Kernel Panic assumed."
        echo "[*] Initiating Forensic Reboot to scavenge local disk data..."
        
        # 1. Pull the virtual power cord and turn it back on
        qm stop $VM2_ID >/dev/null 2>&1 || true
        qm start $VM2_ID >/dev/null 2>&1
        
        # 2. Wait for the fresh OS to boot and the agent to wake up
        echo -n "[*] Waiting for Zombie VM to resurrect"
        RESURRECT_RETRIES=60 # 2 minutes to boot
        RESURRECT_COUNT=0
        
        until qm agent "$VM2_ID" ping >/dev/null 2>&1; do
          if [ "$RESURRECT_COUNT" -ge "$RESURRECT_RETRIES" ]; then
             echo " [FAILED]"
             echo "[!] File system likely corrupted (fsck hang). Scavenge impossible."
             break 2 # Break out of the until loop AND the main while loop
          fi
          echo -n "."
          sleep 2
          RESURRECT_COUNT=$((RESURRECT_COUNT + 1))
        done
        
        # Give SSH and Cloud-Init 15 seconds to fully bind after ping succeeds
        sleep 15
        echo " [RESURRECTED]"
        echo "[*] Disk accessible. Proceeding to autopsy."
        break # Break the main while loop to trigger the Double-Tap extraction
      fi
    else
      # 2. The agent responded! Reset the strike counter and check the process.
      AGENT_STRIKES=0 
      
      if ! qm guest exec $VM2_ID -- sudo -u ubuntu tmux ls 2>/dev/null | grep -q "runner"; then
        echo "" 
        echo "Runner session terminated (completed or crashed) at $ELAPSED seconds."
        break
      fi
    fi
    
    # 3. Check if exactly 30 minutes (1800 seconds) have passed
    if (( ELAPSED > 0 && ELAPSED % 1800 == 0 )); then
      echo ""
      echo "[*] Taking 30-minute atomic snapshot for $NAME..."
      TIMESTAMP=$(date +%H%M)
      
      # Copy current telemetry into the run-specific folder
      qm guest exec $VM1_ID -- sudo -u ubuntu bash -c "cp /home/ubuntu/experiment-telemetry.log /home/ubuntu/vault-results/$NAME/telemetry_${TIMESTAMP}.log"
      
      echo -n "Monitoring progress"
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
  
  # 1. DOUBLE-TAP LOGGING: Force exfiltrate the raw text log first, regardless of fuzzer state
  qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "rsync -avz --bwlimit=2000 -e 'ssh -i /home/ubuntu/.ssh/id_ed25519 -o StrictHostKeyChecking=no' /home/ubuntu/crash-log.txt ubuntu@${VM1_IP_RAW}:/home/ubuntu/vault-results/$NAME/raw-crash-log.txt || true"

  # 2. Extract full results if the fuzzer survived long enough to create them
  qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "if [ -d /home/ubuntu/CRSBench/results ]; then cd /home/ubuntu/CRSBench/results && rsync -avz --bwlimit=2000 -e 'ssh -i /home/ubuntu/.ssh/id_ed25519 -o StrictHostKeyChecking=no' . ubuntu@${VM1_IP_RAW}:/home/ubuntu/vault-results/$NAME/; else echo 'WARNING: Results directory not found, fuzzer likely OOM killed.'; fi"
  
  set +x # Turn off debugging

  # Wait dynamically for the SSH/Rsync TCP connection to drop from ESTABLISHED
  echo -n "Waiting for network buffer flush and TCP connection closure"
  while qm guest exec $VM2_ID -- sudo -u ubuntu ss -tn 2>/dev/null | grep -q "${VM1_IP_RAW}:22.*ESTABLISHED"; do
    echo -n "."
    sleep 2
  done
  echo " [DATA EXFILTRATION COMPLETE]"

  # Archive the serial telemetry into the folder, then truncate the original file so it's clean for the next run
  echo "Archiving serial telemetry for $NAME..."
  qm guest exec $VM1_ID -- sudo -u ubuntu bash -c "cat /home/ubuntu/experiment-telemetry.log >> /home/ubuntu/vault-results/$NAME/serial-console.log && > /home/ubuntu/experiment-telemetry.log"

  # 4. Evaluate and Log Host-Level Results
  if [ $ELAPSED -ge $MAX_RUNTIME ]; then
    echo "$(date) | SMOKE TEST TIMEOUT: $NAME | Exceeded 20-minute limit." >> /root/smoketest-runs.log
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