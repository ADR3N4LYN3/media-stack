#!/bin/bash
# Set qBittorrent WebUI password after startup via API
# Runs as custom-cont-init.d script (linuxserver)

if [ -z "$QBIT_PASSWORD" ]; then
    echo "[custom-init] QBIT_PASSWORD not set, skipping"
    exit 0
fi

# Wait for qBittorrent API in background, then set password
(
    # Wait up to 60s for WebUI to be ready
    for i in $(seq 1 30); do
        sleep 2
        # Get temporary password from logs
        TEMP_PASS=$(cat /config/qBittorrent/logs/*.log 2>/dev/null | grep -oP 'temporary password.*: \K\S+' | tail -1)
        [ -z "$TEMP_PASS" ] && continue

        # Try to login with temp password
        COOKIE=$(curl -s -c - -d "username=admin&password=$TEMP_PASS" http://localhost:8080/api/v2/auth/login 2>/dev/null)
        SID=$(echo "$COOKIE" | grep -oP 'SID\s+\K\S+')
        [ -z "$SID" ] && continue

        # Set the permanent password
        RESULT=$(curl -s -b "SID=$SID" -d "json={\"web_ui_password\":\"$QBIT_PASSWORD\"}" http://localhost:8080/api/v2/app/setPreferences 2>/dev/null)
        echo "[custom-init] qBittorrent password set from QBIT_PASSWORD"
        exit 0
    done
    echo "[custom-init] Failed to set qBittorrent password after 60s"
) &

exit 0
