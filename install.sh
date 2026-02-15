#!/bin/bash
set -euo pipefail

# =============================================================================
# NoLoops Daemon Installer
# =============================================================================

VERSION="0.1.0"
API_BASE_URL="https://api.noloops.io"
DEB_DOWNLOAD_URL="https://github.com/jedsada-n/noloops-package/releases/download/v${VERSION}/noloops_0-1-0_arm64.deb"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
    cat <<EOF
Usage: install.sh --token <token> [OPTIONS]

Required:
  --token <token>              Registration token from NoLoops dashboard

Optional:
  --name <name>                Device display name
  --device_generated_id <id>   Custom device identifier

Example:
  curl -o- https://raw.githubusercontent.com/noloops/package/v${VERSION}/install.sh \\
    | bash -s -- --token abc123 --name "my-device"
EOF
    exit 1
}

# =============================================================================
# 1. Parse Arguments
# =============================================================================

TOKEN=""
NAME=""
DEVICE_GENERATED_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --token)
            TOKEN="$2"
            shift 2
            ;;
        --name)
            NAME="$2"
            shift 2
            ;;
        --device_generated_id)
            DEVICE_GENERATED_ID="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

if [[ -z "$TOKEN" ]]; then
    error "Missing required argument: --token"
fi

# =============================================================================
# 2. Pre-flight Checks
# =============================================================================

info "Running pre-flight checks..."

# 2a. Check root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
fi
success "Running as root"

# 2b. Check curl or wget
DOWNLOADER=""
if command -v curl &> /dev/null; then
    DOWNLOADER="curl"
elif command -v wget &> /dev/null; then
    DOWNLOADER="wget"
else
    error "Neither curl nor wget found. Please install one of them."
fi
success "Found downloader: $DOWNLOADER"

# 2c. Check systemd
if ! command -v systemctl &> /dev/null; then
    error "systemd is required but not found"
fi
success "systemd available"

# =============================================================================
# 3. Check for Existing Installation
# =============================================================================

info "Checking for existing installation..."

if [[ -d "/etc/noloops" ]]; then
    error "NoLoops config directory already exists at /etc/noloops. Uninstall first."
fi

if systemctl list-unit-files noloops.service &> /dev/null && \
   systemctl list-unit-files noloops.service | grep -q "noloops.service"; then
    error "NoLoops service already installed. Uninstall first with: apt remove noloops"
fi

success "No existing installation found"

# =============================================================================
# 4. Register Device
# =============================================================================

info "Registering device with NoLoops..."

# Build JSON payload
JSON_PAYLOAD="{\"token\":\"${TOKEN}\""
if [[ -n "$NAME" ]]; then
    JSON_PAYLOAD+=",\"name\":\"${NAME}\""
fi
if [[ -n "$DEVICE_GENERATED_ID" ]]; then
    JSON_PAYLOAD+=",\"device_generated_id\":\"${DEVICE_GENERATED_ID}\""
fi
JSON_PAYLOAD+="}"

# Make API request
RESPONSE=""
HTTP_CODE=""

if [[ "$DOWNLOADER" == "curl" ]]; then
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD" \
        "${API_BASE_URL}/api/devices/register") || error "Failed to connect to API"
else
    # wget version
    RESPONSE=$(wget -q -O - --header="Content-Type: application/json" \
        --post-data="$JSON_PAYLOAD" \
        "${API_BASE_URL}/api/devices/register" 2>&1) || error "Failed to connect to API"
fi

# Parse response (curl returns body + http_code on separate lines)
if [[ "$DOWNLOADER" == "curl" ]]; then
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')
else
    HTTP_CODE="200"  # wget exits non-zero on error
    RESPONSE_BODY="$RESPONSE"
fi

# Check for success
if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
    # Try to extract error message from JSON response
    ERROR_MSG=$(echo "$RESPONSE_BODY" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 || echo "$RESPONSE_BODY")
    error "Device registration failed: $ERROR_MSG"
fi

# Parse successful response
DEVICE_ID=$(echo "$RESPONSE_BODY" | grep -o '"device_id":"[^"]*"' | cut -d'"' -f4)
DEVICE_SECRET=$(echo "$RESPONSE_BODY" | grep -o '"device_secret":"[^"]*"' | cut -d'"' -f4)
PROJECT_ID=$(echo "$RESPONSE_BODY" | grep -o '"project_id":"[^"]*"' | cut -d'"' -f4)
MQTT_BROKER_URL=$(echo "$RESPONSE_BODY" | grep -o '"mqtt_broker_url":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$DEVICE_ID" || -z "$DEVICE_SECRET" ]]; then
    error "Invalid response from API: missing device credentials"
fi

success "Device registered: $DEVICE_ID"

# =============================================================================
# 5. Download and Install Daemon
# =============================================================================

info "Downloading noloops daemon..."

TMP_DEB="/tmp/noloops-daemon.deb"

if [[ "$DOWNLOADER" == "curl" ]]; then
    curl -fsSL -o "$TMP_DEB" "$DEB_DOWNLOAD_URL" || error "Failed to download package"
else
    wget -q -O "$TMP_DEB" "$DEB_DOWNLOAD_URL" || error "Failed to download package"
fi

success "Downloaded package"

info "Installing package..."
dpkg -i "$TMP_DEB" || error "Failed to install package"
rm -f "$TMP_DEB"

success "Package installed"

# =============================================================================
# 6. Write Config
# =============================================================================

info "Writing configuration..."

mkdir -p /etc/noloops

cat > /etc/noloops/.env <<EOF
DEVICE_ID=${DEVICE_ID}
DEVICE_SECRET=${DEVICE_SECRET}
PROJECT_ID=${PROJECT_ID}
MQTT_BROKER_URL=${MQTT_BROKER_URL}
EOF

# Set secure permissions
chown root:root /etc/noloops/.env
chmod 600 /etc/noloops/.env

success "Configuration written to /etc/noloops/.env"

# =============================================================================
# 7. Enable and Start Service
# =============================================================================

info "Enabling and starting service..."

systemctl enable noloops || error "Failed to enable service"
systemctl start noloops || error "Failed to start service"

# Give it a moment to start
sleep 2

success "Service started"

# =============================================================================
# 8. Print Summary
# =============================================================================

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  NoLoops Daemon Installed Successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Device ID:    ${BLUE}${DEVICE_ID}${NC}"
echo -e "  Project ID:   ${BLUE}${PROJECT_ID}${NC}"
echo -e "  Service:      $(systemctl is-active noloops 2>/dev/null || echo "unknown")"
echo ""
echo -e "  Run '${YELLOW}systemctl status noloops${NC}' to check connection"
echo ""
