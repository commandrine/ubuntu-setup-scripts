#!/usr/bin/env bash
set -euo pipefail

# Install dependencies if not present
if ! command -v freshclam &> /dev/null; then
    echo "Installing ClamAV..."
    sudo apt update
    sudo apt install -y clamav clamav-daemon
fi

if ! command -v maldet &> /dev/null; then
    echo "Installing Maldet..."
    sudo apt install -y maldet
fi

# Stop ClamAV daemon to avoid lock conflicts during update
sudo systemctl stop clamav-daemon || true

# Update ClamAV signatures
sudo freshclam

# Restart ClamAV daemon
sudo systemctl start clamav-daemon || true

# Update Maldet
sudo maldet --update-ver
sudo maldet --update-sigs

# Scan home directory
sudo maldet --scan-all /home

# Review findings manually
sudo maldet --report list
