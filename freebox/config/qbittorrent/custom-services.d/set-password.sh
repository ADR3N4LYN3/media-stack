#!/usr/bin/with-contenv sh
# Set qBittorrent WebUI password + disable CSRF via API after startup
# Runs as custom-services.d service (linuxserver) — executes AFTER qBittorrent starts
# Uses bypass_local_auth (enabled by default) so no login needed from localhost

if [ -z "$QBIT_PASSWORD" ]; then
    echo "[set-password] QBIT_PASSWORD not set, skipping"
    sleep infinity
fi

echo "[set-password] Waiting for qBittorrent API..."

for i in $(seq 1 40); do
    sleep 3

    # Check if API is up (bypass_local_auth allows unauthenticated access from localhost)
    VERSION=$(curl -s http://localhost:8080/api/v2/app/version 2>/dev/null)
    [ -z "$VERSION" ] && continue

    echo "[set-password] API is up ($VERSION), configuring..."

    # Set password + disable CSRF + enable reverse proxy (no auth needed from localhost)
    RESULT=$(curl -s -w '%{http_code}' -d 'json={"web_ui_password":"'"$QBIT_PASSWORD"'","web_ui_csrf_protection_enabled":false,"web_ui_reverse_proxy_enabled":true}' http://localhost:8080/api/v2/app/setPreferences 2>/dev/null)

    if echo "$RESULT" | grep -q "200"; then
        echo "[set-password] qBittorrent password set + CSRF disabled + reverse proxy enabled"
        sleep infinity
    fi

    echo "[set-password] API returned: $RESULT, retrying..."
done

echo "[set-password] Failed to configure qBittorrent after 120s"
sleep infinity
