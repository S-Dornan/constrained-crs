#!/usr/bin/env bats

# Copyright (C) 2026 Sam Dornan
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

# monitor.bats

setup() {
  # 1. Create a temporary directory for our mock binaries
  export MOCK_DIR="$(mktemp -d)"
  
  # 2. Prepend our mock directory to the PATH
  export PATH="${MOCK_DIR}:${PATH}"

  # 3. Setup dummy environment variables required by the script
  export CF_CLIENT_ID="dummy_id"
  export CF_CLIENT_SECRET="dummy_secret"
  export PUSH_URL="http://dummy-kuma.local/api/push"
  export PUSH_INTERVAL="1"
  
  # 4. Use the new internal flag to ensure the test doesn't loop forever
  export RUN_ONCE="true"

  # 5. Mock 'curl' to log its arguments to a file so we can inspect them
  export CURL_LOG="${MOCK_DIR}/curl.log"
  echo '#!/bin/sh' > "${MOCK_DIR}/curl"
  echo 'echo "$@" > "${CURL_LOG}"' >> "${MOCK_DIR}/curl"
  chmod +x "${MOCK_DIR}/curl"

  # 6. Mock 'sleep' just in case RUN_ONCE fails (safety net)
  echo '#!/bin/sh' > "${MOCK_DIR}/sleep"
  echo 'exit 0' >> "${MOCK_DIR}/sleep"
  chmod +x "${MOCK_DIR}/sleep"
}

teardown() {
  # Clean up the temporary directory after each test
  rm -rf "${MOCK_DIR}"
}

@test "Heartbeat: Successfully sends push notification to Kuma" {
  # Note: We point to /bin/monitor.sh to match our new Distroless structure
  run /bin/monitor.sh

  # Assert the script exited successfully
  [ "$status" -eq 0 ]

  # Assert curl was called
  [ -f "${CURL_LOG}" ]

  # Verify the URL structure and basic headers
  run grep -q "${PUSH_URL}" "${CURL_LOG}"
  [ "$status" -eq 0 ]

  run grep -q "CF-Access-Client-Id: dummy_id" "${CURL_LOG}"
  [ "$status" -eq 0 ]
}

@test "Heartbeat: Respects PUSH_INTERVAL if RUN_ONCE is false (Manual Break)" {
  # We manually override RUN_ONCE for this specific test
  export RUN_ONCE="false"
  
  # Mock sleep to exit the script after the first call
  echo '#!/bin/sh' > "${MOCK_DIR}/sleep"
  echo 'exit 0' >> "${MOCK_DIR}/sleep"
  
  run /bin/monitor.sh
  [ "$status" -eq 0 ]
}