#!/bin/sh
# Set qBittorrent WebUI password after startup via API
# Runs as custom-cont-init.d script (linuxserver)

if [ -z "$QBIT_PASSWORD" ]; then
    echo "[custom-init] QBIT_PASSWORD not set, skipping"
    exit 0
fi

# Wait for qBittorrent API in background, then set password
(
    for i in $(seq 1 30); do
        sleep 2

        # Get temporary password from qBittorrent log
        TEMP_PASS=$(grep 'temporary password' /config/qBittorrent/logs/qbittorrent.log 2>/dev/null | tail -1 | awk '{print $NF}')
        [ -z "$TEMP_PASS" ] && continue

        # Login
        SID=$(curl -s -c - -d "username=admin&password=$TEMP_PASS" http://localhost:8080/api/v2/auth/login 2>/dev/null | grep SID | awk '{print $NF}')
        [ -z "$SID" ] && continue

        # Set the permanent password
        curl -s -b "SID=$SID" -d "json={\"web_ui_password\":\"$QBIT_PASSWORD\"}" http://localhost:8080/api/v2/app/setPreferences 2>/dev/null
        echo "[custom-init] qBittorrent password set from QBIT_PASSWORD"
        exit 0
    done
    echo "[custom-init] Failed to set qBittorrent password after 60s"
) &

exit 0
