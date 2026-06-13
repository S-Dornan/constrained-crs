#!/usr/bin/env bash
# Master controller for the OSS-CRS starvation benchmark methodology

# Define the runs based on methodology constraints: 
# "Name : Cores : RAM(MB) : NetRate(MB/s) : ConfigPath"
EXPERIMENTS=(
  "run_1_baseline:8:32768:20:experiment-configs/smoke-testing/first-run.yaml"
  "run_2_stepdown:6:24576:15:experiment-configs/smoke-testing/first-run.yaml"
  "run_3_stepdown:4:16384:10:experiment-configs/smoke-testing/first-run.yaml"
  "run_4_starved:2:8192:5:experiment-configs/smoke-testing/first-run.yaml"
)

# 24 Hours = 86400 seconds
MAX_RUNTIME=86400
POLL_INTERVAL=60

echo "Initializing MSc Thesis Orchestrator..."

for EXP in "${EXPERIMENTS[@]}"; do
  IFS=':' read -r NAME CORES RAM RATE CONFIG <<< "$EXP"
  
  echo "======================================================="
  echo "STARTING EXPERIMENT: $NAME"
  echo "Constraints -> Cores: $CORES | RAM: $RAM | Net: $RATE"
  echo "======================================================="

  # 1. Build the fresh architecture using the parameterized script
  ./vm-config.sh "$CORES" "$RAM" "$RATE"

  # 2. Wait for Cloud-Init to finish
  echo "Waiting for OS and QEMU Guest Agent to boot..."
  sleep 45
  
  echo "Polling Cloud-Init status..."
  while ! qm guest exec 302 -- bash -c "cloud-init status" 2>/dev/null | grep -q "done"; do
    sleep 30
  done
  echo "Cloud-Init complete."

  # 3. Inject the Fuzzer Commands via detached tmux sessions
  echo "Triggering Valkey Queue..."
  qm guest exec 302 -- sudo -u ubuntu tmux new-session -d -s valkey 'cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run python scripts/valkey-helper.py start'
  
  sleep 10
  
  echo "Triggering CRSBench Worker and Runner..."
  qm guest exec 302 -- sudo -u ubuntu tmux new-session -d -s worker "cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run crsbench worker --experiment-config $CONFIG 2>&1 | tee /dev/ttyS1"
  qm guest exec 302 -- sudo -u ubuntu tmux new-session -d -s runner "cd /home/ubuntu/CRSBench && /home/ubuntu/.local/bin/uv run crsbench run --experiment-config $CONFIG 2>&1 | tee /dev/ttyS1"

  # 4. Deterministic Polling Loop
  ELAPSED=0
  echo "Experiments running. Vault is logging. Entering deterministic monitor loop..."

  while [ $ELAPSED -lt $MAX_RUNTIME ]; do
    # Check if 'runner' is still in the active tmux session list
    if ! qm guest exec 302 -- sudo -u ubuntu tmux ls 2>/dev/null | grep -q "runner"; then
      echo "Runner session terminated (completed or crashed) at $ELAPSED seconds."
      break
    fi
    
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
  done

  # 5. Evaluate and Log Host-Level Results
  if [ $ELAPSED -ge $MAX_RUNTIME ]; then
    echo "$(date) | FAILURE: $NAME | Exceeded 24-hour limit." >> /root/thesis-runs.log
  else
    echo "$(date) | COMPLETED: $NAME | Finished in $ELAPSED seconds." >> /root/thesis-runs.log
  fi
  
done

echo "All experimental runs have concluded. Data collection complete."