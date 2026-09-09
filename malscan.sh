#!/bin/bash

################################################################################
# Malware Scanner Setup and Execution Script
# 
# This script installs and configures malware scanning tools on Ubuntu:
# - ClamAV (antivirus engine)
# - Maldet (Linux malware detector)
#
# It updates all signatures and performs a comprehensive scan of the home
# directory, with options for manual review of findings.
#
# Usage: sudo bash malscan.sh
################################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Configuration
SCAN_DIRECTORY="${1:-/home}"
LOG_DIR="/var/log/malscan"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

################################################################################
# Helper Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

################################################################################
# System Preparation
################################################################################

prepare_system() {
    log_info "Preparing system..."
    
    # Update package managers
    log_info "Updating package lists..."
    apt-get update -qq
    
    # Upgrade packages
    log_info "Upgrading packages..."
    apt-get upgrade -y -qq
    
    log_success "System preparation complete"
}

################################################################################
# ClamAV Installation and Configuration
################################################################################

install_clamav() {
    if command_exists clamscan; then
        log_info "ClamAV is already installed"
        return 0
    fi
    
    log_info "Installing ClamAV..."
    apt-get install -y -qq clamav clamav-daemon clamav-freshclam
    
    log_success "ClamAV installed successfully"
}

update_clamav_signatures() {
    log_info "Updating ClamAV signatures..."
    
    # Stop freshclam service if running to avoid conflicts
    if systemctl is-active --quiet clamav-freshclam; then
        systemctl stop clamav-freshclam
    fi
    
    # Update ClamAV signatures
    freshclam --verbose
    
    # Restart freshclam service
    systemctl start clamav-freshclam || true
    
    log_success "ClamAV signatures updated"
}

################################################################################
# Maldet (Linux Malware Detector) Installation and Configuration
################################################################################

install_maldet() {
    if command_exists maldet; then
        log_info "Maldet is already installed"
        return 0
    fi
    
    log_info "Installing Linux Malware Detector (Maldet)..."
    
    # Install dependencies
    apt-get install -y -qq wget tar gzip
    
    # Download latest maldet
    cd /tmp || exit 1
    MALDET_VERSION=$(curl -s https://www.rfxn.com/maldet/ | grep -oP 'maldet-\d+\.\d+\.\d+' | head -1 || echo "maldet-1.6.4")
    
    if [[ -z "$MALDET_VERSION" ]]; then
        log_warning "Could not determine latest maldet version, using v1.6.4"
        MALDET_VERSION="maldet-1.6.4"
    fi
    
    log_info "Downloading ${MALDET_VERSION}..."
    wget -q "https://www.rfxn.com/downloads/${MALDET_VERSION}.tar.gz" -O "${MALDET_VERSION}.tar.gz"
    
    # Extract and install
    tar xzf "${MALDET_VERSION}.tar.gz"
    cd "${MALDET_VERSION}" || exit 1
    ./install.sh
    
    # Cleanup
    cd /tmp || exit 1
    rm -rf "${MALDET_VERSION}" "${MALDET_VERSION}.tar.gz"
    
    log_success "Maldet installed successfully"
}

update_maldet() {
    log_info "Updating Maldet version and signatures..."
    
    # Update maldet version
    maldet --update-ver
    
    # Update maldet signatures
    maldet --update-sigs
    
    log_success "Maldet updated successfully"
}

################################################################################
# Logging Setup
################################################################################

setup_logging() {
    log_info "Setting up logging directory..."
    
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    
    log_success "Logging directory created: $LOG_DIR"
}

################################################################################
# Malware Scanning
################################################################################

perform_scan() {
    local scan_dir="$1"
    
    if [[ ! -d "$scan_dir" ]]; then
        log_error "Scan directory does not exist: $scan_dir"
        return 1
    fi
    
    log_info "Scanning directory: $scan_dir"
    log_info "This may take a while depending on the directory size..."
    
    # Create scan log file
    local scan_log="${LOG_DIR}/maldet_scan_${TIMESTAMP}.log"
    
    # Perform maldet scan
    log_info "Starting Maldet scan..."
    maldet --scan-all "$scan_dir" | tee -a "$scan_log"
    
    log_success "Scan completed. Logs saved to: $scan_log"
}

review_findings() {
    log_info "Reviewing scan findings..."
    
    # List all recent scan reports
    maldet --report list
    
    log_info "To view a specific report, use: maldet --report <report-id>"
    log_info "To quarantine detected files, use: maldet --quarantine <report-id>"
}

################################################################################
# Main Execution
################################################################################

main() {
    log_info "Starting Malware Scanner Setup and Execution"
    log_info "Scan directory: $SCAN_DIRECTORY"
    
    # Verify root access
    check_root
    
    # Setup logging
    setup_logging
    
    # System preparation
    prepare_system
    
    # Install and configure ClamAV
    log_info "Processing ClamAV..."
    install_clamav
    update_clamav_signatures
    
    # Install and configure Maldet
    log_info "Processing Maldet..."
    install_maldet
    update_maldet
    
    # Perform scan
    perform_scan "$SCAN_DIRECTORY"
    
    # Review findings
    review_findings
    
    log_success "=== Malware Scan Complete ==="
    log_info "Scan logs are available in: $LOG_DIR"
    log_info "ClamAV quarantine location: /var/lib/clamav/"
    log_info "Maldet quarantine location: /var/lib/maldet/quarantine/"
    
    return 0
}

# Run main function
main
