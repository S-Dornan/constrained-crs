#!/busybox/sh

# Copyright (C) 2026 Sam Dornan
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

# Run once in testing
RUN_ONCE="${RUN_ONCE:-false}"

# Set default push interval to 10 minutes
PUSH_INTERVAL="${PUSH_INTERVAL:-60}"

STATE="up"
MSG="Online"

# The container will run this loop infinitely, unless it is in testing mode.
while true; do
    curl -s -H "Connection: close" \
          -H "Alert-Powered-By: Pi-Undervoltage" \
          -H "Copyright: Copyright (c) 2026 Sam Dornan" \
          -H "Source-Available: https://gitea.samdornan.me/Infrastructure/uptime-kuma-push-monitor" \
          -H "License-URI: https://www.gnu.org/licenses/agpl-3.0.html" \
          -H "CF-Access-Client-Id: ${CF_CLIENT_ID}" \
          -H "CF-Access-Client-Secret: ${CF_CLIENT_SECRET}" \
          "${PUSH_URL}?status=${STATE}&msg=${MSG}&ping="

  # Break the infinite loop if we are running inside the CI test container
  if [ "$RUN_ONCE" = "true" ]; then
    break
  fi
  
  sleep ${PUSH_INTERVAL}
done