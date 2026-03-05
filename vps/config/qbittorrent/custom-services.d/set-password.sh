#!/usr/bin/with-contenv sh
# Set qBittorrent WebUI password + disable CSRF via API after startup
# Runs as custom-services.d service (linuxserver) — executes AFTER qBittorrent starts

if [ -z "$QBIT_PASSWORD" ]; then
    echo "[set-password] QBIT_PASSWORD not set, skipping"
    sleep infinity
fi

echo "[set-password] Waiting for qBittorrent API..."

for i in $(seq 1 30); do
    sleep 3

    # Get temporary password from qBittorrent log
    TEMP_PASS=$(grep 'temporary password' /config/qBittorrent/logs/qbittorrent.log 2>/dev/null | tail -1 | awk '{print $NF}')
    [ -z "$TEMP_PASS" ] && continue

    # Try login with temp password
    SID=$(curl -s -c - -d "username=admin&password=$TEMP_PASS" http://localhost:8080/api/v2/auth/login 2>/dev/null | grep SID | awk '{print $NF}')

    # If temp password doesn't work, password was already set — try with QBIT_PASSWORD
    if [ -z "$SID" ]; then
        SID=$(curl -s -c - -d "username=admin&password=$QBIT_PASSWORD" http://localhost:8080/api/v2/auth/login 2>/dev/null | grep SID | awk '{print $NF}')
    fi

    [ -z "$SID" ] && continue

    # Set password + disable CSRF + enable reverse proxy
    curl -s -b "SID=$SID" -d 'json={"web_ui_password":"'"$QBIT_PASSWORD"'","web_ui_csrf_protection_enabled":false,"web_ui_reverse_proxy_enabled":true}' http://localhost:8080/api/v2/app/setPreferences 2>/dev/null

    echo "[set-password] qBittorrent password set + CSRF disabled + reverse proxy enabled"
    # Service done — sleep forever to keep s6 happy
    sleep infinity
done

echo "[set-password] Failed to set qBittorrent password after 90s"
sleep infinity
