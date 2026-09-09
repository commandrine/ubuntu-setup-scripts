#!/bin/bash

################################################################################
# Malware Scanner Setup and Execution Script
# 
# This script installs and configures malware scanning tools on Ubuntu:
# - ClamAV (antivirus engine) - installed via apt
# - Maldet (Linux malware detector) - installed from official R-fx downloads
#
# Both tools update signatures before every scan to ensure latest definitions.
# This follows the recommended approach used by Ubuntu administrators.
#
# Usage: sudo bash malscan.sh [scan_directory]
# Example: sudo bash malscan.sh /home
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
WGET_TIMEOUT=30

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
    
    log_info "Installing ClamAV via apt..."
    apt-get install -y -qq clamav clamav-daemon clamav-freshclam
    
    log_success "ClamAV installed successfully"
}

update_clamav_signatures() {
    log_info "Updating ClamAV signatures..."
    
    # Stop freshclam service if running to avoid conflicts
    if systemctl is-active --quiet clamav-freshclam; then
        systemctl stop clamav-freshclam
    fi
    
    # Update ClamAV signatures using freshclam
    freshclam --verbose || log_warning "ClamAV signature update encountered an issue"
    
    # Restart freshclam service
    systemctl start clamav-freshclam || true
    
    log_success "ClamAV signatures updated"
}

################################################################################
# Maldet (Linux Malware Detector) Installation and Configuration
# 
# Maldet is installed from official R-fx downloads (not available in apt)
# See: https://www.rfxn.com/projects/linux-malware-detect/
################################################################################

install_maldet() {
    if command_exists maldet; then
        log_info "Maldet is already installed"
        return 0
    fi
    
    log_info "Installing Linux Malware Detector (Maldet) from official R-fx downloads..."
    
    # Install dependencies
    apt-get install -y -qq wget tar gzip curl
    
    # Download latest maldet from R-fx
    cd /tmp || exit 1
    
    # Query R-fx website to determine latest version
    log_info "Determining latest Maldet version from R-fx..."
    MALDET_VERSION=$(curl -s --connect-timeout 5 --max-time 10 https://www.rfxn.com/maldet/ 2>/dev/null | grep -oP 'maldet-\d+\.\d+\.\d+' | head -1 || echo "maldet-1.6.4")
    
    if [[ -z "$MALDET_VERSION" ]]; then
        log_warning "Could not determine latest maldet version, using v1.6.4 fallback"
        MALDET_VERSION="maldet-1.6.4"
    fi
    
    log_info "Downloading ${MALDET_VERSION} from official R-fx repository..."
    
    # Try download with timeout and fallback
    if ! wget --connect-timeout=$WGET_TIMEOUT --read-timeout=$WGET_TIMEOUT -q "https://www.rfxn.com/downloads/${MALDET_VERSION}.tar.gz" -O "${MALDET_VERSION}.tar.gz" 2>/dev/null; then
        log_warning "HTTPS download failed, trying HTTP fallback..."
        if ! wget --connect-timeout=$WGET_TIMEOUT --read-timeout=$WGET_TIMEOUT -q "http://www.rfxn.com/downloads/${MALDET_VERSION}.tar.gz" -O "${MALDET_VERSION}.tar.gz" 2>/dev/null; then
            log_error "Failed to download Maldet from R-fx"
            log_warning "Skipping Maldet installation - proceeding with ClamAV scan only"
            return 1
        fi
    fi
    
    # Verify download
    if [[ ! -f "${MALDET_VERSION}.tar.gz" ]] || [[ ! -s "${MALDET_VERSION}.tar.gz" ]]; then
        log_error "Downloaded file is invalid or empty"
        return 1
    fi
    
    # Extract and install using R-fx installer
    tar xzf "${MALDET_VERSION}.tar.gz"
    cd "${MALDET_VERSION}" || exit 1
    ./install.sh
    
    # Cleanup
    cd /tmp || exit 1
    rm -rf "${MALDET_VERSION}" "${MALDET_VERSION}.tar.gz"
    
    log_success "Maldet installed successfully from R-fx"
}

update_maldet_signatures() {
    if ! command_exists maldet; then
        log_warning "Maldet is not installed, skipping signature update"
        return 0
    fi
    
    log_info "Updating Maldet signatures and definitions..."
    
    # Update maldet engine version
    maldet --update-ver || log_warning "Maldet version update encountered an issue"
    
    # Update maldet signature database
    maldet --update-sigs || log_warning "Maldet signature update encountered an issue"
    
    log_success "Maldet signatures updated"
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

perform_clamav_scan() {
    log_info "=========================================="
    log_info "Starting ClamAV scan..."
    log_info "=========================================="
    
    local clamav_log="${LOG_DIR}/clamav_scan_${TIMESTAMP}.log"
    
    # Update signatures immediately before scan
    update_clamav_signatures
    
    # Run ClamAV scan
    if ! clamscan -r "$SCAN_DIRECTORY" 2>&1 | tee -a "$clamav_log"; then
        log_warning "ClamAV scan completed with warnings or detections"
    fi
    
    log_success "ClamAV scan completed. Logs saved to: $clamav_log"
}

perform_maldet_scan() {
    if ! command_exists maldet; then
        log_warning "Maldet is not available, skipping Maldet scan"
        return 0
    fi
    
    log_info "=========================================="
    log_info "Starting Maldet scan..."
    log_info "=========================================="
    
    local maldet_log="${LOG_DIR}/maldet_scan_${TIMESTAMP}.log"
    
    # Update signatures immediately before scan
    update_maldet_signatures
    
    # Run Maldet scan
    if ! maldet --scan-all "$SCAN_DIRECTORY" 2>&1 | tee -a "$maldet_log"; then
        log_warning "Maldet scan completed with warnings or malware detections"
    fi
    
    log_success "Maldet scan completed. Logs saved to: $maldet_log"
}

perform_scan() {
    local scan_dir="$1"
    
    if [[ ! -d "$scan_dir" ]]; then
        log_error "Scan directory does not exist: $scan_dir"
        return 1
    fi
    
    log_info "Starting malware scans..."
    log_info "Scan directory: $scan_dir"
    log_info "This may take a while depending on the directory size..."
    
    # Perform ClamAV scan with signature update
    perform_clamav_scan
    
    # Perform Maldet scan with signature update (if available)
    perform_maldet_scan
    
    log_success "All scans completed"
}

review_findings() {
    log_info "=========================================="
    log_info "Scan Summary"
    log_info "=========================================="
    
    if command_exists maldet; then
        # List all recent scan reports
        log_info "Recent Maldet reports:"
        maldet --report list || log_warning "Could not retrieve Maldet scan reports"
        
        log_info ""
        log_info "To view a specific Maldet report, use:"
        log_info "  maldet --report <report-id>"
        log_info ""
        log_info "To quarantine detected files, use:"
        log_info "  maldet --quarantine <report-id>"
    fi
    
    log_info ""
    log_info "All scan logs are available in: $LOG_DIR"
}

################################################################################
# Main Execution
################################################################################

main() {
    log_info "=========================================="
    log_info "Malware Scanner Setup and Execution"
    log_info "=========================================="
    log_info "Scan directory: $SCAN_DIRECTORY"
    log_info ""
    
    # Verify root access
    check_root
    
    # Setup logging
    setup_logging
    
    # System preparation
    prepare_system
    
    # Install and configure ClamAV (via apt)
    log_info "Processing ClamAV installation..."
    install_clamav
    
    # Install Maldet (from R-fx downloads)
    log_info "Processing Maldet installation..."
    install_maldet || log_warning "Maldet installation failed, will use ClamAV only"
    
    # Perform scans with signature updates before each scan
    perform_scan "$SCAN_DIRECTORY"
    
    # Review findings
    review_findings
    
    log_success "=========================================="
    log_success "Malware Scan Complete"
    log_success "=========================================="
    log_info ""
    log_info "Scan results:"
    log_info "  ClamAV quarantine: /var/lib/clamav/"
    if command_exists maldet; then
        log_info "  Maldet quarantine: /var/lib/maldet/quarantine/"
    fi
    log_info ""
    
    return 0
}

# Run main function
main
