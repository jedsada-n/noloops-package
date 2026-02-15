#!/bin/bash
set -euo pipefail

# =============================================================================
# NoLoops Installer (thin bootstrapper)
# Downloads and installs the .deb package, then delegates to `noloops register`.
# =============================================================================

VERSION="0.2.0"
DEB_DOWNLOAD_URL="https://github.com/jedsada-n/noloops-package/releases/download/v${VERSION}/noloops_${VERSION//./-}_arm64.deb"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
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
# 1. Capture Arguments (passed through to `noloops register`)
# =============================================================================

REGISTER_ARGS=()
HAS_TOKEN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --token)
            HAS_TOKEN=true
            REGISTER_ARGS+=("$1" "$2")
            shift 2
            ;;
        --name|--device_generated_id)
            REGISTER_ARGS+=("$1" "$2")
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

if [[ "$HAS_TOKEN" == false ]]; then
    error "Missing required argument: --token"
fi

# =============================================================================
# 2. Pre-flight Checks
# =============================================================================

info "Running pre-flight checks..."

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
fi
success "Running as root"

DOWNLOADER=""
if command -v curl &> /dev/null; then
    DOWNLOADER="curl"
elif command -v wget &> /dev/null; then
    DOWNLOADER="wget"
else
    error "Neither curl nor wget found. Please install one of them."
fi
success "Found downloader: $DOWNLOADER"

if ! command -v systemctl &> /dev/null; then
    error "systemd is required but not found"
fi
success "systemd available"

# =============================================================================
# 3. Check for Existing Installation
# =============================================================================

info "Checking for existing installation..."

if [[ -d "/etc/noloops" ]] || command -v noloops &> /dev/null; then
    error "NoLoops is already installed. Run 'noloops unregister' first."
fi

success "No existing installation found"

# =============================================================================
# 4. Download and Install Package
# =============================================================================

info "Downloading noloops v${VERSION}..."

TMP_DEB="/tmp/noloops.deb"

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
# 5. Register Device (delegate to binary)
# =============================================================================

noloops register "${REGISTER_ARGS[@]}"
