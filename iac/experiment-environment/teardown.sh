#!/usr/bin/env bash

# Define the cleanup function
cleanup() {
    echo "Executing teardown sequence..."
    
    # 1. Kill specific background relay utilities by name or port
    # Forcefully free up the engine port if it's trapped
    local target_port=9001
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
    echo "Nuking Log Vault (VM 301)..."
    qm stop 301 2>/dev/null || true
    qm destroy 301

    echo "Nuking Cleanroom (VM 302)..."
    qm stop 302 2>/dev/null || true
    qm destroy 302
    
    echo "Teardown complete. Ready for cold boot."
}

# Execute the function
cleanup
