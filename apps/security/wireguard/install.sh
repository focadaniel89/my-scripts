#!/bin/bash

# ==============================================================================
# WIREGUARD VPN SERVER (NATIVE)
# Modern, fast, and secure VPN with kernel-level performance
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="wireguard"
WG_CONF_DIR="/etc/wireguard"
WG_INTERFACE="wg0"
WG_PORT=51820
WG_SUBNET="10.13.13.0/24"
WG_SERVER_IP="10.13.13.1"

log_info "═══════════════════════════════════════════"
log_info "  Installing WireGuard VPN Server (Native)"
log_info "═══════════════════════════════════════════"
echo ""

# Detect OS
log_step "Step 1: Detecting operating system"
detect_os
log_success "OS detected: $OS_TYPE"
log_info "Package manager: $PACKAGE_MANAGER"
echo ""

# Check if already installed
if systemctl is-active --quiet wg-quick@$WG_INTERFACE 2>/dev/null; then
    log_warn "WireGuard is already running"
    if confirm_action "Reinstall/Reconfigure?"; then
        log_info "Stopping existing configuration..."
        run_sudo wg-quick down $WG_INTERFACE 2>/dev/null || true
    else
        log_info "Installation cancelled"
        exit 0
    fi
fi
echo ""

# Install WireGuard
log_step "Step 2: Installing WireGuard"
pkg_update

if is_debian_based; then
    pkg_install wireguard wireguard-tools qrencode
elif is_rhel_based; then
    pkg_install epel-release
    pkg_install wireguard-tools qrencode
else
    log_error "Unsupported OS: $OS_ID"
    exit 1
fi

log_success "WireGuard installed"
echo ""

# Get server configuration
log_step "Step 3: Configuring server parameters"

SERVER_IP=$(hostname -I | awk '{print $1}')
log_info "Server IP detected: $SERVER_IP"

read -p "Enter server public IP/domain [$SERVER_IP]: " USER_SERVER_URL
SERVER_URL="${USER_SERVER_URL:-$SERVER_IP}"

read -p "WireGuard port [51820]: " USER_PORT
WG_PORT="${USER_PORT:-51820}"

read -p "Number of peers to create [3]: " USER_PEERS
PEERS="${USER_PEERS:-3}"

log_success "Configuration:"
echo "  Server URL:  $SERVER_URL"
echo "  Port:        $WG_PORT/UDP"
echo "  Interface:   $WG_INTERFACE"
echo "  Subnet:      $WG_SUBNET"
echo "  Peers:       $PEERS"
echo ""

# Enable IP forwarding
log_step "Step 4: Enabling IP forwarding"
run_sudo sysctl -w net.ipv4.ip_forward=1
run_sudo sysctl -w net.ipv6.conf.all.forwarding=1

# Make permanent
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" | run_sudo tee -a /etc/sysctl.conf > /dev/null
fi
if ! grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv6.conf.all.forwarding=1" | run_sudo tee -a /etc/sysctl.conf > /dev/null
fi

log_success "IP forwarding enabled"
echo ""

# Generate server keys
log_step "Step 5: Generating server keys"
run_sudo mkdir -p "$WG_CONF_DIR/keys"
run_sudo chmod 700 "$WG_CONF_DIR/keys"

SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

echo "$SERVER_PRIVATE_KEY" | run_sudo tee "$WG_CONF_DIR/keys/server_private.key" > /dev/null
echo "$SERVER_PUBLIC_KEY" | run_sudo tee "$WG_CONF_DIR/keys/server_public.key" > /dev/null
run_sudo chmod 600 "$WG_CONF_DIR/keys/server_private.key"

log_success "Server keys generated"
echo ""

# Create server configuration
log_step "Step 6: Creating server configuration"

# Detect default network interface
DEFAULT_IF=$(ip route | grep default | awk '{print $5}' | head -1)

# Generate server config with expanded variables
WG_SERVER_CONFIG="[Interface]
Address = $WG_SERVER_IP/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE_KEY

# NAT and forwarding rules
PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o $DEFAULT_IF -j MASQUERADE

# IPv6
PostUp = ip6tables -A FORWARD -i $WG_INTERFACE -j ACCEPT; ip6tables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostDown = ip6tables -D FORWARD -i $WG_INTERFACE -j ACCEPT; ip6tables -t nat -D POSTROUTING -o $DEFAULT_IF -j MASQUERADE
"

echo "$WG_SERVER_CONFIG" | run_sudo tee "$WG_CONF_DIR/$WG_INTERFACE.conf" > /dev/null

run_sudo chmod 600 "$WG_CONF_DIR/$WG_INTERFACE.conf"
log_success "Server configuration created"
echo ""

# Generate peer configurations
log_step "Step 7: Generating peer configurations ($PEERS peers)"

run_sudo mkdir -p "$WG_CONF_DIR/peers"
run_sudo mkdir -p "$WG_CONF_DIR/clients"

for i in $(seq 1 $PEERS); do
    PEER_NAME="peer$i"
    PEER_IP="10.13.13.$((i + 1))"
    
    # Generate peer keys
    PEER_PRIVATE_KEY=$(wg genkey)
    PEER_PUBLIC_KEY=$(echo "$PEER_PRIVATE_KEY" | wg pubkey)
    PEER_PRESHARED_KEY=$(wg genpsk)
    
    # Save peer keys
    echo "$PEER_PRIVATE_KEY" | run_sudo tee "$WG_CONF_DIR/keys/${PEER_NAME}_private.key" > /dev/null
    echo "$PEER_PUBLIC_KEY" | run_sudo tee "$WG_CONF_DIR/keys/${PEER_NAME}_public.key" > /dev/null
    echo "$PEER_PRESHARED_KEY" | run_sudo tee "$WG_CONF_DIR/keys/${PEER_NAME}_preshared.key" > /dev/null
    
    # Add peer to server config
    PEER_SERVER_CONFIG="
# $PEER_NAME
[Peer]
PublicKey = $PEER_PUBLIC_KEY
PresharedKey = $PEER_PRESHARED_KEY
AllowedIPs = $PEER_IP/32
"
    echo "$PEER_SERVER_CONFIG" | run_sudo tee -a "$WG_CONF_DIR/$WG_INTERFACE.conf" > /dev/null
    
    # Create client configuration
    PEER_CLIENT_CONFIG="[Interface]
PrivateKey = $PEER_PRIVATE_KEY
Address = $PEER_IP/24
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $PEER_PRESHARED_KEY
Endpoint = $SERVER_URL:$WG_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25"
    echo "$PEER_CLIENT_CONFIG" | run_sudo tee "$WG_CONF_DIR/clients/${PEER_NAME}.conf" > /dev/null
    
    # Generate QR code
    run_sudo qrencode -t PNG -o "$WG_CONF_DIR/clients/${PEER_NAME}.png" < "$WG_CONF_DIR/clients/${PEER_NAME}.conf"
    
    log_info "  ✓ $PEER_NAME configured ($PEER_IP)"
done

run_sudo chmod 600 "$WG_CONF_DIR/keys/"*
run_sudo chmod 644 "$WG_CONF_DIR/clients/"*

log_success "All peer configurations created"
echo ""

# Start WireGuard
log_step "Step 8: Starting WireGuard service"
run_sudo systemctl enable wg-quick@$WG_INTERFACE
run_sudo wg-quick up $WG_INTERFACE

if systemctl is-active --quiet wg-quick@$WG_INTERFACE; then
    log_success "WireGuard is running"
else
    log_error "Failed to start WireGuard"
    exit 1
fi
echo ""

# Create management script
log_step "Step 9: Creating management script"
run_sudo tee /usr/local/bin/wg-manage > /dev/null <<'EOFSCRIPT'
#!/bin/bash
set -e

WG_IF="wg0"
WG_DIR="/etc/wireguard"

case "$1" in
    status)
        echo "WireGuard Status:"
        wg show $WG_IF
        ;;
    list)
        echo "Available peer configurations:"
        ls -1 $WG_DIR/clients/*.conf 2>/dev/null | xargs -n1 basename | sed 's/.conf$//' || echo "No peers found"
        ;;
    show)
        [ -z "$2" ] && echo "Usage: wg-manage show <peer_name>" && exit 1
        if [ -f "$WG_DIR/clients/$2.conf" ]; then
            echo "Configuration for $2:"
            cat "$WG_DIR/clients/$2.conf"
        else
            echo "Peer $2 not found"
            exit 1
        fi
        ;;
    qr)
        [ -z "$2" ] && echo "Usage: wg-manage qr <peer_name>" && exit 1
        if [ -f "$WG_DIR/clients/$2.conf" ]; then
            qrencode -t ansiutf8 < "$WG_DIR/clients/$2.conf"
        else
            echo "Peer $2 not found"
            exit 1
        fi
        ;;
    restart)
        echo "Restarting WireGuard..."
        wg-quick down $WG_IF 2>/dev/null || true
        wg-quick up $WG_IF
        echo "✓ WireGuard restarted"
        ;;
    *)
        echo "WireGuard Management Tool"
        echo "Usage: wg-manage {status|list|show|qr|restart} [peer_name]"
        echo ""
        echo "Commands:"
        echo "  status          - Show WireGuard status"
        echo "  list            - List all peers"
        echo "  show <name>     - Show peer configuration"
        echo "  qr <name>       - Display QR code for peer"
        echo "  restart         - Restart WireGuard"
        ;;
esac
EOFSCRIPT

run_sudo chmod +x /usr/local/bin/wg-manage
log_success "Management script created"
echo ""

# Display installation summary
log_success "═══════════════════════════════════════════"
log_success "  WireGuard VPN Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

log_info "🌐 Server details:"
echo "  Server URL:   $SERVER_URL"
echo "  Server Port:  $WG_PORT/UDP"
echo "  VPN Subnet:   $WG_SUBNET"
echo "  Interface:    $WG_INTERFACE"
echo "  Peers:        $PEERS"
echo ""

log_info "📁 Configuration files:"
echo "  Server config:     $WG_CONF_DIR/$WG_INTERFACE.conf"
echo "  Client configs:    $WG_CONF_DIR/clients/*.conf"
echo "  QR codes:          $WG_CONF_DIR/clients/*.png"
echo "  Keys:              $WG_CONF_DIR/keys/"
echo ""

log_info "🔧 Peer management:"
echo "  List peers:        sudo wg-manage list"
echo "  Show config:       sudo wg-manage show peer1"
echo "  Display QR:        sudo wg-manage qr peer1"
echo "  Show status:       sudo wg-manage status"
echo "  Restart:           sudo wg-manage restart"
echo ""

log_info "📱 Client setup:"
echo "  1. Install WireGuard client:"
echo "     - Android/iOS: WireGuard app from store"
echo "     - Windows/Mac/Linux: https://www.wireguard.com/install/"
echo ""
echo "  2. Import configuration:"
echo "     - Scan QR code: sudo wg-manage qr peer1"
echo "     - Or copy from: $WG_CONF_DIR/clients/peer1.conf"
echo ""
echo "  3. Activate connection in WireGuard client"
echo ""

log_info "🔍 Useful commands:"
echo "  sudo wg                                # Show status"
echo "  sudo wg show $WG_INTERFACE             # Detailed status"
echo "  sudo systemctl status wg-quick@$WG_INTERFACE  # Service status"
echo "  sudo systemctl restart wg-quick@$WG_INTERFACE # Restart"
echo "  sudo wg-quick down $WG_INTERFACE      # Stop"
echo "  sudo wg-quick up $WG_INTERFACE        # Start"
echo "  sudo journalctl -u wg-quick@$WG_INTERFACE -f  # View logs"
echo ""

log_warn "⚠️  Important notes:"
echo "  • Port $WG_PORT/UDP must be open in firewall"
echo "  • Run: sudo ufw allow $WG_PORT/udp"
echo "  • Each peer has unique keys - never share"
echo "  • Backup $WG_CONF_DIR directory regularly"
echo "  • Configuration files contain private keys - keep secure"
echo ""

log_info "🔥 Firewall configuration:"
echo "  UFW:       sudo ufw allow $WG_PORT/udp"
echo "  firewalld: sudo firewall-cmd --add-port=$WG_PORT/udp --permanent && sudo firewall-cmd --reload"
echo "  iptables:  sudo iptables -A INPUT -p udp --dport $WG_PORT -j ACCEPT"
echo ""

log_info "💡 Next steps:"
echo "  1. Configure firewall: sudo ufw allow $WG_PORT/udp"
echo "  2. List peers: sudo wg-manage list"
echo "  3. Get QR code: sudo wg-manage qr peer1"
echo "  4. Install WireGuard app on devices"
echo "  5. Scan QR code or import configuration"
echo "  6. Connect and test: ping $WG_SERVER_IP"
echo ""


