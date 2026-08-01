#!/usr/bin/env bash
#
# Copyright (C) 2026 Sam Dornan
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
#
# Teardown Script for OSS-CRS Architecture

# ==========================================
# Load Environment Variables
# ==========================================
if [ -f ".env" ]; then
  source .env
else
  echo "[!] FATAL: .env file not found. Cannot load Proxmox configuration."
  exit 1
fi

# Define the cleanup function
cleanup() {
    echo "Executing teardown sequence..."
    
    # 1. Kill specific background relay utilities by name or port
    # Forcefully free up the engine port if it's trapped
    local target_port=$SERIAL_PORT
    local pid
    pid=$(lsof -t -i :$target_port 2>/dev/null || true)
    
    # Use -n to check if the string is NOT empty
    if [ -n "$pid" ]; then
        echo "Killing lingering process ($pid) on port $target_port"
        kill -9 "$pid" 2>/dev/null || true
    else
        echo "Port $target_port is clear."
    fi

    # 2. Stop and destroy the architecture
    echo "Nuking Log Vault (VM $VM1_ID)..."
    qm stop $VM1_ID 2>/dev/null || true
    qm destroy $VM1_ID

    echo "Nuking Cleanroom (VM $VM2_ID)..."
    qm stop $VM2_ID 2>/dev/null || true
    qm destroy $VM2_ID
    
    echo "Teardown complete. Ready for cold boot."
}

# Execute the function
cleanup