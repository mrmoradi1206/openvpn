#!/usr/bin/env bash
# Add a new OpenVPN client and generate a .ovpn profile
# Compatible with the tls-crypt setup from openvpn_bootstrap_tlscrypt.sh

set -Eeuo pipefail
trap 'echo "[ERR] Failed at line $LINENO"; exit 1' ERR

must_root(){ [[ $EUID -eq 0 ]] || { echo "[!] Run as root (sudo)"; exit 1; }; }
must_root

EASYRSA_HOME="/etc/openvpn/easy-rsa"
OVPN_DIR="/etc/openvpn"
CLIENT_DIR="/root/client-configs"
mkdir -p "$CLIENT_DIR"

echo
read -rp "Enter a name for the new client (no spaces): " CLIENT
[[ -z "$CLIENT" ]] && { echo "❌ Client name cannot be empty"; exit 1; }

cd "$EASYRSA_HOME"

# Generate new cert/key if missing
if [[ -f "pki/issued/${CLIENT}.crt" ]]; then
  echo "⚠️  Client '${CLIENT}' already exists. Overwrite? (y/N)"
  read -r yn
  [[ "${yn,,}" == "y" ]] && ./easyrsa --batch revoke "$CLIENT" && ./easyrsa gen-crl
  rm -f "pki/issued/${CLIENT}.crt" "pki/private/${CLIENT}.key" || true
fi

echo "==> Generating and signing cert for '${CLIENT}'..."
./easyrsa --batch gen-req "$CLIENT" nopass
./easyrsa --batch sign-req client "$CLIENT"

# Detect server info
PORT=$(grep -E '^port ' "$OVPN_DIR/server.conf" | awk '{print $2}')
PROTO=$(grep -E '^proto ' "$OVPN_DIR/server.conf" | awk '{print $2}')
PUB_IP=$(curl -s --max-time 4 ifconfig.me || hostname -I | awk '{print $1}' || echo "YOUR_SERVER_IP")

OUT="${CLIENT_DIR}/${CLIENT}-${PROTO}${PORT}.ovpn"

echo "==> Building .ovpn profile at: $OUT"

cat > "$OUT" <<EOF
client
dev tun
proto $PROTO
remote $PUB_IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
verb 3
EOF

{
  echo "<ca>";        cat "${OVPN_DIR}/ca.crt"; echo "</ca>"
  echo "<cert>";      awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "pki/issued/${CLIENT}.crt"; echo "</cert>"
  echo "<key>";       cat "pki/private/${CLIENT}.key"; echo "</key>"
  echo "<tls-crypt>"; cat "${OVPN_DIR}/tls-crypt.key"; echo "</tls-crypt>"
} >> "$OUT"

chmod 600 "$OUT"

echo
echo "✅ Client profile generated successfully!"
echo "📄 Saved to: $OUT"
echo "📤 To download it:"
echo "   scp root@${PUB_IP}:${OUT} ."
