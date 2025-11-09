# 🛡️ OpenVPN Auto Installer + Client Generator (Ubuntu)

This project provides **two ready-to-use Bash scripts** for setting up a secure, production-ready **OpenVPN server with `tls-crypt` encryption**, automatic firewall configuration, and easy one-command client generation.

It is perfect for:
- Personal or small team VPN servers
- Secure remote access to your infrastructure
- Learning OpenVPN + DevOps automation

---

## 📂 Included Scripts

| Script | Description |
|--------|-------------|
| [`openvpn_bootstrap_tlscrypt.sh`](./openvpn_bootstrap_tlscrypt.sh) | Full automatic OpenVPN server installer and configuration script |
| [`add_openvpn_client.sh`](./add_openvpn_client.sh) | Interactive client creation tool that generates `.ovpn` files |

---

## ⚙️ Features

✅ Fully automated OpenVPN server setup  
✅ Uses **`tls-crypt`** (modern, secure key protection — no key-direction issues)  
✅ Auto-configures **UFW firewall** and **NAT (MASQUERADE)**  
✅ Supports **TCP (443 / 8443)** and **UDP (1194)** auto-detection  
✅ One-command client certificate + `.ovpn` generator  
✅ Safe to **re-run** — idempotent and non-destructive  
✅ Works on **Ubuntu 20.04+** (tested on 22.04, 24.04)

---

## 🚀 Quick Start (Full Setup)

### 1️⃣ Upload the installer to your Ubuntu server
```bash
scp openvpn_bootstrap_tlscrypt.sh root@YOUR_SERVER_IP:/root/

2️⃣ Run it

ssh root@YOUR_SERVER_IP
sudo bash /root/openvpn_bootstrap_tlscrypt.sh --client mylaptop

This script will:

    Install OpenVPN, Easy-RSA, and UFW

    Create server certificates and Diffie-Hellman parameters

    Enable IP forwarding and NAT

    Start the VPN service

    Create the first client .ovpn file (mylaptop-tcp443.ovpn or mylaptop-tcp8443.ovpn)

3️⃣ Download your client file

scp root@YOUR_SERVER_IP:/root/client-configs/mylaptop-tcp443.ovpn .

Then import it into your VPN client:

    Windows: OpenVPN GUI

macOS: Tunnelblick or Viscosity

Linux: sudo openvpn --config mylaptop.ovpn

Android/iOS: OpenVPN Connect
👤 Add More Clients

Once your server is running, generate additional clients anytime with:

sudo bash /root/add_openvpn_client.sh

You’ll be asked for a client name (e.g., phone, laptop2, work-pc)
A new .ovpn file will be created in:

/root/client-configs/

Example:

scp root@YOUR_SERVER_IP:/root/client-configs/phone-tcp8443.ovpn .

🔐 Security Defaults

The configuration includes:

    AES-256-GCM cipher

    tls-crypt key encryption (hides TLS handshake metadata)

    NAT and IP forwarding for secure routing

    UFW firewall with only 22/tcp + VPN port open

    Client DNS push for Cloudflare (1.1.1.1) + Google DNS (8.8.8.8)

🧩 Script Details
🧰 openvpn_bootstrap_tlscrypt.sh

    Detects best available port (tcp/443, tcp/8443, or udp/1194)

    Automatically sets up:

        /etc/openvpn/server.conf

        /etc/openvpn/easy-rsa/ PKI

        ufw NAT masquerade rules

    Starts openvpn@server service

    Generates an initial client profile automatically

Run options:

sudo bash openvpn_bootstrap_tlscrypt.sh --client mylaptop --proto tcp --port 8443 --dns 1.1.1.1,9.9.9.9

👤 add_openvpn_client.sh

    Asks for client name interactively

    Creates and signs cert via EasyRSA

    Generates .ovpn file with embedded keys

    Supports unlimited clients

🧱 Directory Structure

/etc/openvpn/
 ├── server.conf
 ├── ca.crt
 ├── server.crt
 ├── server.key
 ├── dh.pem
 ├── tls-crypt.key
 └── easy-rsa/
      └── pki/...

/root/client-configs/
 ├── client1-tcp8443.ovpn
 ├── phone-tcp8443.ovpn
 └── laptop-tcp8443.ovpn

📋 Example Output

==> Installing OpenVPN, Easy-RSA, UFW, and tools…
==> Selected TCP/8443 for OpenVPN.
==> Restarting OpenVPN service…
==> Health report
[OK] Done.
Client file: /root/client-configs/mylaptop-tcp8443.ovpn
Download with:
  scp root@130.185.121.198:/root/client-configs/mylaptop-tcp8443.ovpn .

🧹 Uninstall (Optional)

sudo systemctl stop openvpn@server
sudo apt remove --purge -y openvpn easy-rsa
sudo ufw delete allow 443/tcp
sudo rm -rf /etc/openvpn /root/client-configs

🧠 Notes

    All .ovpn files are self-contained (certs + keys embedded)

    You can re-run the installer safely — it won’t overwrite your existing CA or keys

    Works best on Ubuntu 20.04, 22.04, or 24.04

    Compatible with Windows, macOS, Linux, iOS, Android clients

📜 License

MIT License
Copyright © 2025

You are free to use, modify, and distribute this code with attribution.
💬 Author

Amir Moradi
💻 DevOps & Network Engineer
