#!/usr/bin/env bash
# OpenVPN Bootstrap (Ubuntu) — tls-crypt, NAT, UFW, client export
# Safe to re-run. Won't overwrite existing keys. Defaults: TCP/443 if free, else TCP/8443, else UDP/1194.
# Usage examples:
#   sudo bash openvpn_bootstrap_tlscrypt.sh
#   sudo bash openvpn_bootstrap_tlscrypt.sh --client mylaptop --proto tcp --port 8443
#   sudo bash openvpn_bootstrap_tlscrypt.sh --proto udp --port 1194 --dns 1.1.1.1,9.9.9.9

set -Eeuo pipefail
trap 'echo "[ERR] Failed at line $LINENO"; exit 1' ERR

# ---------- options ----------
CLIENT="client1"
PROTO=""      # auto (tcp if unspecified)
PORT=""       # auto (443/8443/1194)
DNS_CSV="1.1.1.1,8.8.8.8"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client) CLIENT="$2"; shift 2;;
    --proto)  PROTO="$2";  shift 2;;
    --port)   PORT="$2";   shift 2;;
    --dns)    DNS_CSV="$2";shift 2;;
    -h|--help)
      cat <<USAGE
Usage:
  sudo bash $0 [--client NAME] [--proto tcp|udp] [--port N] [--dns A.B.C.D[,E.F.G.H]]
Defaults:
  client=client1, proto=auto, port=auto (tcp/443 -> tcp/8443 -> udp/1194), dns=1.1.1.1,8.8.8.8
USAGE
      exit 0;;
    *) echo "[WARN] Unknown option: $1"; shift;;
  esac
done

must_root(){ [[ $EUID -eq 0 ]] || { echo "[!] Run as root (sudo)"; exit 1; }; }
msg(){ echo -e "\n==> $*"; }
ok(){ echo "[OK] $*"; }
warn(){ echo "[WARN] $*"; }

must_root
export DEBIAN_FRONTEND=noninteractive

OVPN_DIR="/etc/openvpn"
CONF="${OVPN_DIR}/server.conf"
EASYRSA_SYS="/usr/share/easy-rsa"
EASYRSA_HOME="/etc/openvpn/easy-rsa"
UNIT_OLD="openvpn@server"
UNIT_NEW="openvpn-server@server.service"
CLIENT_DIR="/root/client-configs"
SUBNET="10.8.0.0/24"

# ---------- 0) install deps ----------
msg "Installing OpenVPN, Easy-RSA, UFW, and tools…"
apt-get update -y >/dev/null
apt-get install -y openvpn easy-rsa ufw lsof curl >/dev/null

# ---------- 1) layout ----------
systemctl disable --now "$UNIT_NEW" >/dev/null 2>&1 || true
mkdir -p "$OVPN_DIR" "$EASYRSA_HOME" "$CLIENT_DIR"

# ---------- 2) Easy-RSA / PKI (non-destructive) ----------
if [[ ! -f "${EASYRSA_HOME}/easyrsa" ]]; then
  msg "Preparing Easy-RSA workspace at ${EASYRSA_HOME}…"
  cp -a "${EASYRSA_SYS}/." "$EASYRSA_HOME/"
  chmod -R 700 "$EASYRSA_HOME"
fi

cd "$EASYRSA_HOME"
[[ -d pki ]] || { msg "Initializing PKI…"; ./easyrsa --batch init-pki; }
[[ -f pki/ca.crt ]] || { msg "Building CA…"; EASYRSA_REQ_CN="ovpn-ca" ./easyrsa --batch build-ca nopass; }

if [[ ! -f pki/issued/server.crt || ! -f pki/private/server.key ]]; then
  msg "Creating server cert…"
  EASYRSA_REQ_CN="server" ./easyrsa --batch gen-req server nopass
  ./easyrsa --batch sign-req server server
fi
[[ -f pki/dh.pem ]] || { msg "Generating Diffie-Hellman…"; ./easyrsa gen-dh; }

install -m 600 -o root -g root pki/ca.crt             "${OVPN_DIR}/ca.crt"
install -m 600 -o root -g root pki/issued/server.crt  "${OVPN_DIR}/server.crt"
install -m 600 -o root -g root pki/private/server.key "${OVPN_DIR}/server.key"
install -m 600 -o root -g root pki/dh.pem             "${OVPN_DIR}/dh.pem"

# ---------- 3) tls-crypt ----------
if [[ ! -f "${OVPN_DIR}/tls-crypt.key" ]]; then
  msg "Generating tls-crypt.key…"
  openvpn --genkey secret "${OVPN_DIR}/tls-crypt.key"
fi
chmod 600 "${OVPN_DIR}/server.key" "${OVPN_DIR}/tls-crypt.key" || true

# ---------- 4) server.conf (create/normalize) ----------
if [[ ! -f "$CONF" ]]; then
  msg "Creating base server.conf…"
  cat > "$CONF" <<'EOF'
port 1194
proto udp
dev tun

ca ca.crt
cert server.crt
key server.key
dh dh.pem

# TLS
tls-crypt tls-crypt.key
cipher AES-256-GCM

topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup

mssfix 1450

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"

status /var/log/openvpn-status.log
verb 3
EOF
fi

# normalize one-time toggles
sed -i 's/^\s*topology\s\+.*/topology subnet/' "$CONF"
sed -i '/^\s*tls-auth\s/d' "$CONF"
grep -q '^tls-crypt ' "$CONF" || echo 'tls-crypt tls-crypt.key' >> "$CONF"
grep -q '^mssfix ' "$CONF" || echo 'mssfix 1450' >> "$CONF"

# replace DNS pushes with custom DNS if provided
# clear existing DNS push lines
sed -i '/^push "dhcp-option DNS /d' "$CONF"
IFS=',' read -r -a DNS_ARR <<< "$DNS_CSV"
for d in "${DNS_ARR[@]}"; do
  echo "push \"dhcp-option DNS ${d}\"" >> "$CONF"
done

# ---------- 5) choose proto/port ----------
tcp_busy(){ ss -ltnp | grep -E ":$1\b" -q; }
udp_busy(){ ss -lunp | grep -E ":$1\b" -q; }

if [[ -z "$PROTO" || -z "$PORT" ]]; then
  # auto
  if [[ -z "$PROTO" ]]; then PROTO="tcp"; fi
  if [[ -z "$PORT" ]]; then
    if ! tcp_busy 443 && ! (lsof -iTCP:443 -sTCP:LISTEN -n -P 2>/dev/null | grep -q docker-proxy); then
      PORT=443
    elif ! tcp_busy 8443; then
      PORT=8443
    elif ! udp_busy 1194; then
      PROTO="udp"; PORT=1194
    else
      PORT=10443; PROTO="tcp"
    fi
  fi
fi

msg "Selected ${PROTO^^}/$PORT for OpenVPN."
sed -i "s/^proto .*/proto $PROTO/" "$CONF"
sed -i "s/^port .*/port $PORT/" "$CONF"

if [[ "$PROTO" == "udp" ]]; then
  grep -q '^explicit-exit-notify' "$CONF" || echo 'explicit-exit-notify 1' >> "$CONF"
else
  sed -i 's/^explicit-exit-notify.*/# explicit-exit-notify 1/' "$CONF" || true
fi

# ---------- 6) IP forward + UFW + MASQUERADE ----------
msg "Enabling IPv4 forwarding / UFW / MASQUERADE…"
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn.conf
sysctl --system >/dev/null

ufw allow 22/tcp >/dev/null || true
ufw allow "${PORT}/${PROTO}" >/dev/null || true
ufw --force enable >/dev/null || true

WAN_IF=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[[ -n "${WAN_IF:-}" ]] || { echo "[!] Could not detect WAN interface"; exit 1; }

BEFORE="/etc/ufw/before.rules"
if ! grep -q 'OVPN-BS NAT BEGIN' "$BEFORE" 2>/dev/null; then
  cp -a "$BEFORE" "/root/before.rules.$(date +%s).bak" || true
  awk -v wan="$WAN_IF" '
    BEGIN{done=0}
    /^\*filter/ && !done {
      print "*nat"
      print ":POSTROUTING ACCEPT [0:0]"
      print "-A POSTROUTING -s 10.8.0.0/24 -o " wan " -j MASQUERADE"
      print "COMMIT"
      print "# OVPN-BS NAT BEGIN"
      print "# managed block"
      print "# OVPN-BS NAT END"
      done=1
    }
    {print}
  ' "$BEFORE" > "$BEFORE.tmp" && mv "$BEFORE.tmp" "$BEFORE"
else
  sed -i "0,/-A POSTROUTING/s#-A POSTROUTING -s 10\.8\.0\.0/24 -o .* -j MASQUERADE#-A POSTROUTING -s 10.8.0.0/24 -o ${WAN_IF} -j MASQUERADE#" "$BEFORE"
fi
ufw reload >/dev/null || true

# ---------- 7) start service ----------
msg "Starting OpenVPN service (openvpn@server)…"
systemctl enable "$UNIT_OLD" >/dev/null || true
systemctl restart "$UNIT_OLD"
sleep 1

# ---------- 8) client cert + .ovpn (tls-crypt) ----------
cd "$EASYRSA_HOME"
if [[ ! -f "pki/issued/${CLIENT}.crt" ]]; then
  msg "Creating client cert '${CLIENT}'…"
  ./easyrsa --batch gen-req "$CLIENT" nopass
  ./easyrsa --batch sign-req client "$CLIENT"
fi

PUB_IP=$(curl -s --max-time 4 ifconfig.me || hostname -I | awk '{print $1}' || echo "YOUR_PUBLIC_IP")
OUT="${CLIENT_DIR}/${CLIENT}-${PROTO}${PORT}.ovpn"

msg "Writing client profile: $OUT"
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

# ---------- 9) health ----------
msg "Health report"
echo "[*] Unit status: $(systemctl is-active $UNIT_OLD)"
echo "[*] Listening TCP:"; ss -ltnp | awk 'NR==1 || /openvpn/'; echo
echo "[*] Listening UDP:"; ss -lunp | awk 'NR==1 || /openvpn/'; echo
echo "[*] tun0:"; ip -brief addr show tun0 || true; echo
echo "[*] Route ${SUBNET}:"; ip route | grep "${SUBNET%/*}" || echo "no route yet"; echo
echo "[*] UFW (first lines):"; ufw status verbose | sed -n '1,60p'

ok "Done."
echo "Client file: $OUT"
echo "Download with:"
echo "  scp root@${PUB_IP}:${OUT} ."
