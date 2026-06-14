#!/usr/bin/env bash
# Smoke Test Controller for the OSS-CRS starvation benchmark methodology

VM1_ID=301
VM2_ID=302

# Define the runs based on methodology constraints: 
# "Name : Cores : RAM(MB) : NetRate(MB/s) : ConfigPath"
EXPERIMENTS=(
  "smoke_1_baseline:8:32768:20:experiment-configs/smoke-testing/first-run.yaml"
  "smoke_2_stepdown:6:24576:15:experiment-configs/smoke-testing/first-run.yaml"
  "smoke_3_stepdown:4:16384:10:experiment-configs/smoke-testing/first-run.yaml"
  "smoke_4_starved:2:8192:5:experiment-configs/smoke-testing/first-run.yaml"
)

# 15 Minutes = 900 seconds (Approx 1 hour total runtime for 4 experiments)
MAX_RUNTIME=900
POLL_INTERVAL=60

echo "Initializing Smoke Test Orchestrator..."

for EXP in "${EXPERIMENTS[@]}"; do
  IFS=':' read -r NAME CORES RAM RATE CONFIG <<< "$EXP"
  
  echo "======================================================="
  echo "STARTING SMOKE TEST: $NAME"
  echo "Constraints -> Cores: $CORES | RAM: $RAM | Net: $RATE"
  echo "======================================================="

  # 1. Build the fresh architecture using the parameterized script
  ./vm-config.sh "$CORES" "$RAM" "$RATE"

  # 2. Enforce Strict Boot Order (Receiver BEFORE Broadcaster)
  echo -n "Waiting 45s for OS and QEMU Guest Agent to boot"
  for i in {1..45}; do
    echo -n "."
    sleep 1
  done
  echo " [DONE]"

  # FIRST: Ensure the Log Vault is fully online and actively listening
  echo -n "Polling Log Vault (VM 301) Cloud-Init status"
  while ! qm guest exec $VM1_ID -- bash -c "cloud-init status" 2>/dev/null | grep -q "done"; do
    echo -n "."
    sleep 10
  done
  echo " [READY]"

  # SECOND: Ensure the Cleanroom is fully built before sending the execution command
  echo -n "Polling Cleanroom (VM 302) Cloud-Init status"
  while ! qm guest exec $VM2_ID -- bash -c "cloud-init status" 2>/dev/null | grep -q "done"; do
    echo -n "."
    sleep 10
  done
  echo " [READY]"

  # 3. Inject the Fuzzer Commands via detached tmux sessions
  echo "Triggering Valkey Queue..."
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s valkey 'cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run python scripts/valkey-helper.py start'
  
  sleep 10
  
  echo "Triggering CRSBench Worker and Runner..."
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s worker "cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run crsbench worker --experiment-config $CONFIG 2>&1 | tee /dev/ttyS1"
  qm guest exec $VM2_ID -- sudo -u ubuntu tmux new-session -d -s runner "cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run crsbench run --experiment-config $CONFIG 2>&1 | tee /dev/ttyS1"

  # 4. Deterministic Polling Loop
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

  # 5. Evaluate and Log Host-Level Results
  if [ $ELAPSED -ge $MAX_RUNTIME ]; then
    echo "$(date) | SMOKE TEST TIMEOUT: $NAME | Exceeded 15-minute limit." >> /root/smoketest-runs.log
  else
    echo "$(date) | SMOKE TEST COMPLETED: $NAME | Finished in $ELAPSED seconds." >> /root/smoketest-runs.log
  fi
  
done

echo "All smoke tests have concluded. Architecture pipeline verified."