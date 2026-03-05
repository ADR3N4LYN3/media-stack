#!/bin/bash
# Set qBittorrent WebUI password from QBIT_PASSWORD env var
# Runs before qBittorrent starts (linuxserver custom-cont-init.d)

CONF="/config/qBittorrent/qBittorrent.conf"

if [ -z "$QBIT_PASSWORD" ]; then
    echo "[custom-init] QBIT_PASSWORD not set, skipping"
    exit 0
fi

if [ ! -f "$CONF" ]; then
    echo "[custom-init] Config file not found, skipping (first run)"
    exit 0
fi

# Generate PBKDF2 hash using Python
HASH=$(python3 -c "
import hashlib, os, base64
password = '$QBIT_PASSWORD'
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac('sha512', password.encode(), salt, 100000, dklen=64)
print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(key).decode()})')
" 2>/dev/null)

if [ -z "$HASH" ]; then
    echo "[custom-init] Failed to generate password hash"
    exit 1
fi

# Remove existing password line if present
sed -i '/^WebUI\\Password_PBKDF2/d' "$CONF"

# Add password after [Preferences] section
if grep -q '^\[Preferences\]' "$CONF"; then
    sed -i "/^\[Preferences\]/a WebUI\\\\Password_PBKDF2=\"$HASH\"" "$CONF"
else
    echo -e "\n[Preferences]\nWebUI\\Password_PBKDF2=\"$HASH\"" >> "$CONF"
fi

echo "[custom-init] qBittorrent password set from QBIT_PASSWORD"
