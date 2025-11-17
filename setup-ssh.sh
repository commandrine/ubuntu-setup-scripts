#!/bin/bash

# --- SSH Server Setup Script for Ubuntu Desktop ---
# This script performs the following actions:
# 1. Updates the local package list.
# 2. Installs the OpenSSH server package.
# 3. Ensures the SSH service is running and configured to start on boot.
# 4. Configures the Uncomplicated Firewall (UFW) to allow SSH connections on port 22.

# --- Configuration ---
SSH_PORT=22

# 1. Update package index
echo "--> Step 1/5: Updating package list..."
sudo apt update

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to update package lists. Please check your network connection and permissions."
    exit 1
fi

# 2. Install OpenSSH Server
echo "--> Step 2/5: Installing OpenSSH server (openssh-server)..."
# The -y flag automatically confirms installation
sudo apt install openssh-server -y

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to install openssh-server. Exiting."
    exit 1
fi

# 3. Enable and check SSH service status
echo "--> Step 3/5: Starting and enabling the SSH service..."

# Ensure the service is started immediately
sudo systemctl start ssh

# Enable the service to start automatically on boot
sudo systemctl enable ssh

# Check status
status_output=$(sudo systemctl status ssh | grep "Active:")

echo "SSH Service Status Check:"
echo "$status_output"

if [[ $status_output == *"active (running)"* ]]; then
    echo "SUCCESS: OpenSSH server is installed and running."
else
    echo "WARNING: SSH service status is NOT running. Please check logs manually using 'sudo systemctl status ssh'."
fi

# 4. Configure UFW (Uncomplicated Firewall)
echo "--> Step 4/5: Configuring Uncomplicated Firewall (UFW)..."

# Check if UFW is active
if sudo ufw status | grep -q "Status: active"; then
    echo "UFW is active. Allowing incoming traffic on port $SSH_PORT for SSH."
    
    # Allow incoming traffic on the specified SSH port
    sudo ufw allow $SSH_PORT/tcp comment 'SSH Access'

    # Check the new rule
    echo "Current UFW status (should show 'ALLOW' for $SSH_PORT/tcp):"
    sudo ufw status | grep "$SSH_PORT/tcp"
else
    echo "UFW is inactive or not installed. Skipping firewall configuration."
    echo "RECOMMENDATION: Install and enable UFW to secure your system if you plan to access it externally."
fi

# 5. Display connectivity information
echo " "
echo "========================================================="
echo "✅ SSH Server Setup Complete!"
echo " "
# Get the primary internal IP address
LOCAL_IP=$(hostname -I | awk '{print $1}')
USERNAME=$(whoami)

echo "You can now connect to this machine from another system using the command:"
echo "ssh $USERNAME@$LOCAL_IP -p $SSH_PORT"
echo " "
echo "Username: $USERNAME"
echo "Local IP: $LOCAL_IP (This may change, use 'ip a' to confirm)"
echo "Port: $SSH_PORT"
echo "========================================================="
