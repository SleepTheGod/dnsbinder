#!/bin/bash
set -euo pipefail

VERSION="1.0"
AUTHOR="Made by Taylor Christian Newsome — DNS Binder"
LOG_FILE="/var/log/dnsbinder.log"

ZONE_DIR="/etc/bind/zones"
NAMED_LOCAL="/etc/bind/named.conf.local"

function usage() {
cat <<EOF
DNSBinder v$VERSION — Enterprise DNS Automation for Debian 12

Usage:
  dnsbinder <domain> <ip>   Launches full DNS server setup for specified domain and IP
  dnsbinder -h              Show help
  dnsbinder --help          Show help

What it does:
  - Installs & configures BIND9
  - Sets up DNS zones for specified domain/IP
  - Applies firewall rules
  - Enables kernel-level IP forwarding
  - Validates all configurations
  - Designed for production-grade enterprise use

$AUTHOR
EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

validate_domain() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log "ERROR: Invalid domain format: $1"
        exit 1
    fi
}

validate_ip() {
    if [[ ! "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        log "ERROR: Invalid IP format: $1"
        exit 1
    fi
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ $# -ne 2 ]]; then
        log "ERROR: Domain and IP arguments required"
        usage
        exit 1
    fi

    DOMAIN="$1"
    IP="$2"
    NS="ns1.${DOMAIN}"
    ZONE_FILE="${ZONE_DIR}/db.${DOMAIN}"

    validate_domain "$DOMAIN"
    validate_ip "$IP"

    log "🚀 Starting DNSBinder setup for $DOMAIN → $IP"

    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    log "📦 Installing required packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y bind9 bind9utils bind9-doc dnsutils iptables-persistent

    log "🔧 Enabling kernel-level DNS forwarding..."
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-dns-forwarding.conf
    sysctl --system

    log "📁 Setting up BIND zone directory..."
    mkdir -p "$ZONE_DIR"
    chown bind:bind "$ZONE_DIR"
    chmod 755 "$ZONE_DIR"

    log "🧹 Cleaning old zone entry in named.conf.local..."
    sed -i "/zone \"$DOMAIN\"/,/};/d" "$NAMED_LOCAL" || true

    log "📝 Writing new zone block for $DOMAIN..."
    cat >> "$NAMED_LOCAL" <<EOF

zone "$DOMAIN" {
    type master;
    file "$ZONE_FILE";
    allow-transfer { none; };
};
EOF

    log "📄 Creating zone file for $DOMAIN..."
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

    log "🔐 Setting ownership and permissions..."
    chown -R bind:bind /etc/bind
    chmod -R 755 /etc/bind

    log "🔍 Validating BIND configuration..."
    named-checkconf
    named-checkzone "$DOMAIN" "$ZONE_FILE"

    log "🛡️  Applying firewall rules for DNS (UDP/TCP 53)..."
    iptables -I INPUT -p udp --dport 53 -j ACCEPT
    iptables -I INPUT -p tcp --dport 53 -j ACCEPT
    netfilter-persistent save

    log "🚀 Restarting and enabling BIND9..."
    systemctl restart bind9
    systemctl enable bind9

    log "✅ DNSBinder setup complete for $DOMAIN"
}

main "$@"
