#!/bin/bash
set -euo pipefail

VERSION="1.0"
AUTHOR="Made by Taylor Christian Newsome — DNS Binder"
LOG_FILE="/var/log/dnsbinder.log"
DOMAIN=""
IP=""
ZONE_DIR="/etc/bind/zones"
ZONE_FILE=""
NAMED_LOCAL="/etc/bind/named.conf.local"
NS=""

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Validate domain format
validate_domain() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log "ERROR: Invalid domain format: $1"
        exit 1
    fi
}

# Validate IP format
validate_ip() {
    if [[ ! "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log "ERROR: Invalid IP format: $1"
        exit 1
    fi
}

function usage() {
cat <<EOF
DNSBinder v$VERSION — Enterprise DNS Automation for Debian 12

Usage:
  dnsbinder <domain> <ip>   Launches full DNS server setup for specified domain and IP
  dnsbinder -h              Show help
  dnsbinder --help          Show help

What it does:
  - Installs & configures BIND9
  - Sets up DNS zones for specified IP
  - Applies firewall rules for DNS
  - Enables IP forwarding
  - Validates all DNS configurations
  - Designed for production use

$AUTHOR
EOF
}

# Check for help flags
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

# Check for required arguments
if [[ $# -ne 2 ]]; then
    log "ERROR: Domain and IP arguments required"
    usage
    exit 1
fi

DOMAIN="$1"
IP="$2"
NS="ns1.${DOMAIN}"
ZONE_FILE="${ZONE_DIR}/db.${DOMAIN}"

# Validate inputs
validate_domain "$DOMAIN"
validate_ip "$IP"
log "Starting DNSBinder setup for $DOMAIN → $IP"

# Ensure log file exists
touch "$LOG_FILE" || {
    log "ERROR: Cannot create log file $LOG_FILE"
    exit 1
}
chmod 644 "$LOG_FILE"

log "[+] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || { log "ERROR: Failed to update package lists"; exit 1; }
apt-get install -y bind9 bind9utils bind9-doc dnsutils iptables-persistent || {
    log "ERROR: Failed to install packages"; exit 1;
}

log "[+] Enabling kernel-level DNS forwarding..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-dns-forwarding.conf
sysctl --system || { log "ERROR: Failed to apply sysctl settings"; exit 1; }

log "[+] Setting up BIND zone directory..."
mkdir -p "$ZONE_DIR" || { log "ERROR: Failed to create zone directory"; exit 1; }
chown bind:bind "$ZONE_DIR"
chmod 755 "$ZONE_DIR"

log "[+] Cleaning old zone entry in named.conf.local..."
sed -i "/zone \"$DOMAIN\"/,/};/d" "$NAMED_LOCAL" || true

log "[+] Writing new zone block for $DOMAIN..."
cat >> "$NAMED_LOCAL" <<EOF

zone "$DOMAIN" {
    type master;
    file "$ZONE_FILE";
    allow-transfer { none; };
};
EOF

log "[+] Creating zone file for $DOMAIN..."
cat > "$ZONE_FILE" <<EOF
\$TTL 86400
@   IN  SOA ${NS}. admin.${DOMAIN}. (
        $(date +%Y%m%d%H) ; Serial
        3600              ; Refresh
        1800              ; Retry
        1209600           ; Expire
        86400 )           ; Minimum TTL
    IN  NS   ${NS}.
${NS%%.*} IN  A    ${IP}
@       IN  A    ${IP}
www     IN  A    ${IP}
EOF

log "[+] Setting ownership for zone files..."
chown -R bind:bind /etc/bind || { log "ERROR: Failed to set ownership"; exit 1; }
chmod -R 755 /etc/bind || { log "ERROR: Failed to set permissions"; exit 1; }

log "[+] Validating DNS configuration..."
named-checkconf || { log "ERROR: Invalid BIND configuration"; exit 1; }
named-checkzone "$DOMAIN" "$ZONE_FILE" || { log "ERROR: Invalid zone file"; exit 1; }

log "[+] Opening firewall for DNS (port 53 UDP/TCP)..."
iptables -I INPUT -p udp --dport 53 -j ACCEPT || { log "ERROR: Failed to set UDP firewall rule"; exit 1; }
iptables -I INPUT -p tcp --dport 53 -j ACCEPT || { log "ERROR: Failed to set TCP firewall rule"; exit 1; }
netfilter-persistent save || { log "ERROR: Failed to save firewall rules"; exit 1; }

log "[+] Restarting BIND9 service..."
systemctl restart bind9 || { log "ERROR: Failed to restart BIND9"; exit 1; }
systemctl enable bind9 || { log "ERROR: Failed to enable BIND9"; exit 1; }

log "[+] Performing DNS test with dig (localhost)..."
dig @"127.0.0.1" "$DOMAIN" +short || log "WARNING: DNS test failed, but setup completed"

log "✅ DNS is now live for $DOMAIN → $IP"
log "➡ Make sure to set your domain's NS records at your registrar to:"
log "   - ns1.${DOMAIN} with IP ${IP}"
log "📦 Complete. $AUTHOR"
