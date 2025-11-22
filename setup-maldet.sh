#!/bin/bash
# install_maldet_clamav.sh
# Automated script to install and configure Linux Malware Detect (LMD/maldet)
# and ClamAV on an Ubuntu/Debian-based system.

# --- Configuration Variables ---
LMD_INSTALL_DIR="/usr/local/maldetect"
LMD_CONFIG_FILE="${LMD_INSTALL_DIR}/conf.maldet"
SCAN_PATH="/home" # Directory to scan daily (e.g., /home, /var/www, or /)

# Function to check for script success and exit if a command fails
check_exit() {
    if [ $? -ne 0 ]; then
        echo "ERROR: $1 failed. Exiting script."
        exit 1
    fi
}

echo "--- 1. Starting System Update and Package Installation ---"

# Update package lists
sudo apt update
check_exit "Package list update"

# Install ClamAV, its daemon, and necessary utilities
echo "Installing ClamAV (for superior scanning) and dependencies..."
sudo apt install -y clamav clamav-daemon build-essential wget
check_exit "ClamAV installation"

# Ensure ClamAV service is running and enabled
sudo systemctl enable clamav-daemon
sudo systemctl start clamav-daemon
echo "ClamAV daemon (clamd) is installed and running."

echo "--- 2. Installing Linux Malware Detect (maldet) ---"

# Download the latest LMD release
LATEST_VERSION=$(wget -q -O - http://www.rfxn.com/downloads/maldetect-current.tar.gz)
check_exit "Downloading LMD latest version info"

wget -q http://www.rfxn.com/downloads/maldetect-current.tar.gz
check_exit "Downloading maldetect-current.tar.gz"

# Extract and install LMD
tar -xzf maldetect-current.tar.gz
LMD_DIR=$(find . -maxdepth 1 -type d -name "maldetect-*" | head -n 1)

if [ -z "$LMD_DIR" ]; then
    echo "ERROR: Could not find extracted maldetect directory."
    exit 1
fi

cd "$LMD_DIR"
sudo ./install.sh
check_exit "maldet installation"
cd - > /dev/null # Go back to original directory
rm -rf maldetect-current.tar.gz "$LMD_DIR"

echo "maldet successfully installed to ${LMD_INSTALL_DIR}"

echo "--- 3. Configuring maldet to use ClamAV and set scanning parameters ---"

# Ensure the configuration file exists
if [ ! -f "$LMD_CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found at ${LMD_CONFIG_FILE}"
    exit 1
fi

# Configuration changes using sed
# 1. Enable ClamAV integration (default: 0 -> 1)
sudo sed -i 's/^#*clamexec=0/clamexec=1/' "$LMD_CONFIG_FILE"
# 2. Set the default scan path (change if necessary)
sudo sed -i "s|^#*scan_tmpdir=.*|scan_tmpdir=${SCAN_PATH}|" "$LMD_CONFIG_FILE"
# 3. Quarantining malware on detection (default: 0 -> 1)
sudo sed -i 's/^#*quarantine_hits=0/quarantine_hits=1/' "$LMD_CONFIG_FILE"
# 4. Clean up the scan report after successful email delivery (default: 0 -> 1)
sudo sed -i 's/^#*quarantine_clean=0/quarantine_clean=1/' "$LMD_CONFIG_FILE"
# 5. Alert the user via email (replace 'you@domain.com' with a valid address)
sudo sed -i 's/^#*email_alert=0/email_alert=1/' "$LMD_CONFIG_FILE"
sudo sed -i 's/^#*email_addr="you@domain.com"/email_addr="root"/' "$LMD_CONFIG_FILE"
echo "NOTE: Email alerts are enabled and set to email the 'root' user. Configure a proper MTA or change 'email_addr' manually."

# Manually update LMD signatures for first use
echo "Updating maldet signatures..."
sudo maldet --update
check_exit "maldet signature update"

# Configure a daily cron job to run LMD scans (using the LMD's default cron)
# The LMD installer usually sets up a daily cron, but we ensure it targets the correct path.
echo "maldet is configured to run daily via cron. Scanning path: ${SCAN_PATH}"

echo "--- 4. Initial Test Scan ---"
echo "Running an initial full scan on the configured path: ${SCAN_PATH}"
# Run an initial scan in the background
sudo maldet --scan-all ${SCAN_PATH} &
MALDET_PID=$!
echo "maldet initial scan started in the background (PID: $MALDET_PID). This may take some time."
echo "You can check the progress with: ps -p $MALDET_PID"
echo "Scan results will be logged in: ${LMD_INSTALL_DIR}/event_log"

echo "--- 5. Installation Complete! ---"
echo "To view the configuration file, run: sudo nano ${LMD_CONFIG_FILE}"
echo "To run a manual scan on a directory: sudo maldet -a /path/to/scan"
echo "To view last scan reports: sudo maldet --report list"

