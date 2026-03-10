#!/bin/sh
#
# tailscale-ssl-kvm.sh
#
# Manually run every ~90 days to refresh the cert.
#

set -e

BACKUP_DIR="/root/ssl-backup"
CRT_DST="/etc/kvmd/user/ssl/server.crt"
KEY_DST="/etc/kvmd/user/ssl/server.key"

WORK_DIR="$(mktemp -d /tmp/tailscale-cert.XXXXXX)"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

echo "[*] Using temp working dir: $WORK_DIR"
cd "$WORK_DIR"

echo "[*] Running 'tailscale cert' to determine Tailnet domain and generate cert..."

# Run once, capture output, and allow parsing even if tailscale returns non-zero
CERT_OUT="$(tailscale cert 2>&1 || true)"

TAILNET_DOMAIN="$(printf '%s\n' "$CERT_OUT" | grep -Eo '[A-Za-z0-9.-]+\.ts\.net' | head -n1)"

if [ -z "$TAILNET_DOMAIN" ]; then
    echo "[!] Could not detect Tailnet domain from 'tailscale cert' output."
    echo "---- tailscale cert output ----"
    printf '%s\n' "$CERT_OUT"
    echo "------------------------------"
    exit 1
fi

echo "[*] Detected Tailnet domain: $TAILNET_DOMAIN"

CRT_SRC="$WORK_DIR/${TAILNET_DOMAIN}.crt"
KEY_SRC="$WORK_DIR/${TAILNET_DOMAIN}.key"

# If first run didn't leave the files behind for some reason, run again explicitly
if [ ! -f "$CRT_SRC" ] || [ ! -f "$KEY_SRC" ]; then
    echo "[*] Cert files not present yet, running 'tailscale cert $TAILNET_DOMAIN' explicitly..."
    tailscale cert "$TAILNET_DOMAIN"
fi

if [ ! -f "$CRT_SRC" ] || [ ! -f "$KEY_SRC" ]; then
    echo "[!] Expected cert files not found:"
    echo "    $CRT_SRC"
    echo "    $KEY_SRC"
    echo
    echo "---- tailscale cert output ----"
    printf '%s\n' "$CERT_OUT"
    echo "------------------------------"
    exit 1
fi

echo "[*] Backing up existing SSL certs..."
mkdir -p "$BACKUP_DIR"
cp -a "$CRT_DST" "$BACKUP_DIR/server.crt.bak" 2>/dev/null || true
cp -a "$KEY_DST" "$BACKUP_DIR/server.key.bak" 2>/dev/null || true

echo "[*] Installing Tailscale SSL cert into kvmd..."
cp -f "$CRT_SRC" "$CRT_DST"
cp -f "$KEY_SRC" "$KEY_DST"
chmod 600 "$CRT_DST" "$KEY_DST"

echo "[*] Restarting kvmd..."
/etc/init.d/kvmd restart 2>/dev/null || service kvmd restart 2>/dev/null || true

echo "[*] Reloading nginx..."
/etc/init.d/nginx restart 2>/dev/null || killall -HUP nginx 2>/dev/null || true

echo "[*] Confirming certs are valid..."
openssl s_client -connect 127.0.0.1:443 -servername "$TAILNET_DOMAIN" </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates || true

echo "[✓] Done. Test in browser: https://${TAILNET_DOMAIN}"
