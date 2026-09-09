#!/bin/bash

################################################################################
# Malware Scanner Setup and Execution Script
# 
# This script installs and configures malware scanning tools on Ubuntu:
# - ClamAV (antivirus engine) - installed via apt
# - Maldet (Linux malware detector) - installed from official GitHub rfxn/linux-malware-detect
#
# Both tools update signatures before every scan to ensure latest definitions.
# This follows the recommended approach used by Ubuntu administrators.
#
# Official Maldet Repository: https://github.com/rfxn/linux-malware-detect
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
MALDET_REPO="https://github.com/rfxn/linux-malware-detect.git"
MALDET_INSTALL_DIR="/usr/local/maldetect"

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

# Color code for scan results - Green for OK
result_ok() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Color code for scan results - Red for requires review
result_alert() {
    echo -e "${RED}⚠ $1${NC}"
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
# Maldet is installed from the official GitHub repository (rfxn/linux-malware-detect)
# See: https://github.com/rfxn/linux-malware-detect
################################################################################

install_maldet() {
    if command_exists maldet; then
        log_info "Maldet is already installed at $(command -v maldet)"
        return 0
    fi
    
    log_info "Installing Linux Malware Detector (Maldet) from official GitHub repository..."
    log_info "Repository: $MALDET_REPO"
    
    # Install dependencies
    log_info "Installing Maldet dependencies (git, perl)..."
    apt-get install -y -qq git perl
    
    # Clone the official Maldet repository
    log_info "Cloning official Maldet repository..."
    cd /tmp || exit 1
    
    # Remove any existing clone
    if [[ -d "linux-malware-detect" ]]; then
        log_info "Removing existing linux-malware-detect directory..."
        rm -rf linux-malware-detect
    fi
    
    # Clone repository with depth for faster cloning
    if ! git clone --depth 1 "$MALDET_REPO" 2>&1 | tee -a "${LOG_DIR}/maldet_clone.log"; then
        log_error "Failed to clone Maldet repository from GitHub"
        log_error "Repository: $MALDET_REPO"
        log_error "Clone log saved to: ${LOG_DIR}/maldet_clone.log"
        return 1
    fi
    
    log_success "Repository cloned successfully"
    
    # Enter the cloned directory and run installer
    cd linux-malware-detect || exit 1
    
    log_info "Running Maldet installer..."
    if ! ./install.sh 2>&1 | tee -a "${LOG_DIR}/maldet_install.log"; then
        local install_exit_code=$?
        log_error "Maldet installer failed with exit code: $install_exit_code"
        log_error "Installation log saved to: ${LOG_DIR}/maldet_install.log"
        cd /tmp || exit 1
        rm -rf linux-malware-detect
        return 1
    fi
    
    log_success "Maldet installer completed successfully"
    log_info "Maldet installed to: $MALDET_INSTALL_DIR"
    
    # Verify installation
    if [[ -f "${MALDET_INSTALL_DIR}/maldet" ]]; then
        log_success "Maldet binary verified at: ${MALDET_INSTALL_DIR}/maldet"
    fi
    
    if command_exists maldet; then
        log_success "Maldet command is available in PATH"
    fi
    
    # Cleanup
    cd /tmp || exit 1
    rm -rf linux-malware-detect
    
    log_success "Maldet installed successfully from GitHub"
}

update_maldet() {
    if ! command_exists maldet; then
        log_warning "Maldet is not installed, skipping update"
        return 0
    fi
    
    log_info "Updating Maldet engine and signatures..."
    
    # Update maldet engine version
    log_info "Updating Maldet engine version..."
    if ! maldet --update-ver 2>&1 | tee -a "${LOG_DIR}/maldet_update_ver_${TIMESTAMP}.log"; then
        log_warning "Maldet version update encountered an issue"
        log_warning "Check log: ${LOG_DIR}/maldet_update_ver_${TIMESTAMP}.log"
    else
        log_success "Maldet engine version updated"
    fi
    
    # Update maldet signature database
    log_info "Updating Maldet signature database..."
    if ! maldet --update-sigs 2>&1 | tee -a "${LOG_DIR}/maldet_update_sigs_${TIMESTAMP}.log"; then
        log_warning "Maldet signature update encountered an issue"
        log_warning "Check log: ${LOG_DIR}/maldet_update_sigs_${TIMESTAMP}.log"
    else
        log_success "Maldet signatures updated"
    fi
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
# Scan Result Processing and Color Coding
################################################################################

process_clamav_results() {
    local clamav_log="$1"
    
    log_info ""
    log_info "=========================================="
    log_info "ClamAV Scan Results - Color Coded"
    log_info "=========================================="
    
    if [[ ! -f "$clamav_log" ]]; then
        log_warning "ClamAV log file not found: $clamav_log"
        return
    fi
    
    # Extract summary line from ClamAV output
    local known_viruses=$(grep "Known viruses" "$clamav_log" | tail -1)
    local engine_version=$(grep "Engine version" "$clamav_log" | tail -1)
    local scanned_files=$(grep "Scanned files" "$clamav_log" | tail -1)
    local infected_files=$(grep "Infected files" "$clamav_log" | tail -1)
    local data_scanned=$(grep "Data scanned" "$clamav_log" | tail -1)
    
    [[ -n "$known_viruses" ]] && log_info "$known_viruses"
    [[ -n "$engine_version" ]] && log_info "$engine_version"
    [[ -n "$scanned_files" ]] && log_info "$scanned_files"
    [[ -n "$data_scanned" ]] && log_info "$data_scanned"
    
    # Check for infected files
    if grep -q "Infected files: 0" "$clamav_log"; then
        result_ok "No malware detected - Clean scan"
    else
        if [[ -n "$infected_files" ]]; then
            result_alert "$infected_files - REQUIRES REVIEW"
        fi
        
        # Extract and color code each detected threat
        log_info ""
        log_info "Detected threats (requires review):"
        grep ": " "$clamav_log" | grep -E "(FOUND|Detected)" | while read -r line; do
            result_alert "$line"
        done
    fi
    
    log_info ""
}

process_maldet_results() {
    local maldet_log="$1"
    
    log_info "=========================================="
    log_info "Maldet Scan Results - Color Coded"
    log_info "=========================================="
    
    if [[ ! -f "$maldet_log" ]]; then
        log_warning "Maldet log file not found: $maldet_log"
        return
    fi
    
    # Extract summary information from Maldet output
    local scan_summary=$(grep -E "files scanned|scan report|detection count" "$maldet_log" | tail -5)
    
    if [[ -n "$scan_summary" ]]; then
        echo "$scan_summary" | while read -r line; do
            log_info "$line"
        done
    fi
    
    # Check for detections
    if grep -qiE "malware|detected|threat" "$maldet_log"; then
        log_info ""
        log_info "Threats detected (requires review):"
        grep -iE "malware|detected|threat" "$maldet_log" | head -20 | while read -r line; do
            result_alert "$line"
        done
        result_alert "Additional detections logged - See $maldet_log for full details"
    else
        if grep -q "0.*detect" "$maldet_log" || grep -q "no malware" "$maldet_log"; then
            result_ok "No malware detected - Clean scan"
        else
            result_ok "Scan completed - Check logs for detailed results"
        fi
    fi
    
    log_info ""
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
    log_info "Scanning with ClamAV (recursive mode)..."
    if ! clamscan -r "$SCAN_DIRECTORY" 2>&1 | tee -a "$clamav_log"; then
        log_warning "ClamAV scan completed with warnings or detections"
    fi
    
    log_success "ClamAV scan completed. Logs saved to: $clamav_log"
    
    # Process and display color-coded results
    process_clamav_results "$clamav_log"
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
    update_maldet
    
    # Run Maldet scan
    log_info "Scanning with Maldet (all files mode)..."
    if ! maldet --scan-all "$SCAN_DIRECTORY" 2>&1 | tee -a "$maldet_log"; then
        log_warning "Maldet scan completed with warnings or malware detections"
    fi
    
    log_success "Maldet scan completed. Logs saved to: $maldet_log"
    
    # Process and display color-coded results
    process_maldet_results "$maldet_log"
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
    log_info ""
    
    # Perform ClamAV scan with signature update
    perform_clamav_scan
    
    log_info ""
    
    # Perform Maldet scan with signature update (if available)
    perform_maldet_scan
    
    log_success "All scans completed"
}

review_findings() {
    log_info "=========================================="
    log_info "Scan Summary and Next Steps"
    log_info "=========================================="
    log_info ""
    
    if command_exists maldet; then
        # List all recent scan reports
        log_info "Recent Maldet reports:"
        if maldet --report list 2>&1 | tee -a "${LOG_DIR}/maldet_reports_${TIMESTAMP}.log"; then
            log_info ""
            log_info "To view a specific Maldet report, use:"
            log_info "  sudo maldet --report <report-id>"
            log_info ""
            log_info "To quarantine detected files, use:"
            log_info "  sudo maldet --quarantine <report-id>"
            log_info ""
            log_info "To view scan details:"
            log_info "  cat /usr/local/maldetect/sess/*"
        else
            log_warning "Could not retrieve Maldet scan reports"
        fi
    fi
    
    log_info ""
    log_info "ClamAV scan logs:"
    log_info "  $(ls -1 ${LOG_DIR}/clamav_scan*.log 2>/dev/null | tail -1)"
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
    log_info "Log directory: $LOG_DIR"
    log_info ""
    
    # Verify root access
    check_root
    
    # Setup logging
    setup_logging
    
    # System preparation
    prepare_system
    
    # Install and configure ClamAV (via apt)
    log_info "=========================================="
    log_info "Phase 1: ClamAV Installation"
    log_info "=========================================="
    install_clamav
    log_info ""
    
    # Install Maldet (from GitHub)
    log_info "=========================================="
    log_info "Phase 2: Maldet Installation"
    log_info "=========================================="
    if ! install_maldet; then
        local maldet_exit_code=$?
        log_error "Maldet installation failed with exit code: $maldet_exit_code"
        log_error "Installation log: ${LOG_DIR}/maldet_install.log"
        log_error "Clone log: ${LOG_DIR}/maldet_clone.log"
        log_warning "Continuing with ClamAV-only scanning"
    fi
    log_info ""
    
    # Perform scans with signature updates before each scan
    log_info "=========================================="
    log_info "Phase 3: Malware Scanning"
    log_info "=========================================="
    perform_scan "$SCAN_DIRECTORY"
    
    log_info ""
    
    # Review findings
    review_findings
    
    log_success "=========================================="
    log_success "Malware Scan Complete"
    log_success "=========================================="
    log_info ""
    log_info "Scan Results Summary:"
    log_info "  ClamAV quarantine: /var/lib/clamav/"
    if command_exists maldet; then
        log_info "  Maldet quarantine: /usr/local/maldetect/quarantine/"
        log_info "  Maldet installation: $MALDET_INSTALL_DIR"
    fi
    log_info ""
    log_info "All logs saved to: $LOG_DIR"
    log_info ""
    log_info "Legend:"
    result_ok "Result requires no action"
    result_alert "Result requires human review"
    log_info ""
    
    return 0
}

# Run main function
main
