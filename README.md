# Ubuntu Setup Scripts

A collection of setup and utility scripts for Ubuntu systems.

## Scripts

### malscan.sh - Malware Scanner Setup and Execution

A comprehensive malware scanning utility that installs and manages multiple antivirus engines on Ubuntu systems. It supports both ClamAV and Maldet (Linux Malware Detector) with flexible command-line options to run them individually or together.

#### Features

- **Dual-Engine Support**
  - ClamAV (antivirus engine) - installed via apt
  - Maldet (Linux Malware Detector) - installed from official GitHub repository
  
- **Selective Scanning** - Run individual engines or both via command-line flags
- **Automatic Signature Updates** - Both tools update definitions before every scan
- **Color-Coded Output** - Clear visual indicators for scan results
- **Comprehensive Logging** - All scan results saved to `/var/log/malscan/`
- **Flexible Directory Targeting** - Scan any directory on the system

#### Requirements

- Ubuntu/Debian Linux system
- Root or sudo privileges
- Internet connection (for signature updates and Maldet installation)
- Disk space for tool installation and logging

#### Installation

1. Clone or download the script:
```bash
git clone https://github.com/commandrine/ubuntu-setup-scripts.git
cd ubuntu-setup-scripts
```

2. Make the script executable:
```bash
chmod +x malscan.sh
```

#### Usage

```bash
sudo bash malscan.sh [OPTIONS] [scan_directory]
```

##### Options

| Option | Description |
|--------|-------------|
| `-c, --clamav` | Run ClamAV scan only |
| `-m, --maldet` | Run Maldet scan only |
| `-a, --all` | Run both ClamAV and Maldet scans (default) |
| `-h, --help` | Display help message |

##### Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `scan_directory` | Directory path to scan | `/home` |

#### Examples

**Scan /home with all engines (default):**
```bash
sudo bash malscan.sh /home
```

**Scan /home with ClamAV only:**
```bash
sudo bash malscan.sh -c /home
```

**Scan /var/www with Maldet only:**
```bash
sudo bash malscan.sh -m /var/www
```

**Scan entire filesystem with both engines:**
```bash
sudo bash malscan.sh -a /
```

**Use long-form flags (ClamAV only):**
```bash
sudo bash malscan.sh --clamav /home
```

**Display help:**
```bash
sudo bash malscan.sh -h
```

#### How It Works

1. **System Preparation** - Updates package lists and installs required dependencies
2. **Engine Installation** - Installs only the requested scanning engines:
   - ClamAV via apt package manager
   - Maldet from official GitHub repository (rfxn/linux-malware-detect)
3. **Signature Updates** - Downloads latest malware definitions before scanning
4. **Scanning Phase** - Recursively scans the target directory with enabled engines
5. **Results Processing** - Color-codes and displays findings with human-readable formatting
6. **Review Summary** - Provides next steps for threat handling and quarantine options

#### Output and Results

**Scan Results Display:**
- ✓ Green checkmark indicates clean scans (no threats detected)
- ⚠ Red warning symbol indicates detections requiring review
- Summary statistics (files scanned, malware hits, data scanned)
- Detailed threat listings with file paths

**Log Files Location:**
All scan logs are saved to `/var/log/malscan/`:
- `clamav_scan_YYYYMMDD_HHMMSS.log` - ClamAV scan results
- `maldet_scan_YYYYMMDD_HHMMSS.log` - Maldet scan results
- `maldet_update_ver_YYYYMMDD_HHMMSS.log` - Maldet version updates
- `maldet_update_sigs_YYYYMMDD_HHMMSS.log` - Maldet signature updates
- `maldet_clone.log` - Maldet repository clone log
- `maldet_install.log` - Maldet installation log

#### Post-Scan Actions

**View Maldet Reports:**
```bash
sudo maldet --report list
sudo maldet --report <report-id>
```

**Quarantine Suspicious Files:**
```bash
sudo maldet --quarantine <report-id>
```

**View Maldet Scan Details:**
```bash
cat /usr/local/maldetect/sess/*
```

**ClamAV Quarantine Location:**
```bash
ls -la /var/lib/clamav/
```

#### Cron Job Examples

**Weekly scan of /home with ClamAV only (every Sunday at 2 AM):**
```bash
0 2 * * 0 root /usr/bin/bash /path/to/malscan.sh -c /home >> /var/log/malscan/cron.log 2>&1
```

**Daily Maldet-only scan of /var/www (every day at 3 AM):**
```bash
0 3 * * * root /usr/bin/bash /path/to/malscan.sh -m /var/www >> /var/log/malscan/cron.log 2>&1
```

**Monthly full system scan with both engines (first day at 4 AM):**
```bash
0 4 1 * * root /usr/bin/bash /path/to/malscan.sh -a / >> /var/log/malscan/cron.log 2>&1
```

#### Troubleshooting

**Script fails with "must be run as root":**
- Ensure you're using `sudo bash malscan.sh ...`
- Do not try to run with `bash sudo malscan.sh` (incorrect order)

**Maldet installation fails:**
- Check internet connection for GitHub access
- Verify `/tmp` has sufficient free space
- Review `/var/log/malscan/maldet_clone.log` and `/var/log/malscan/maldet_install.log`
- If only Maldet is requested (-m flag), the script will exit with an error

**ClamAV installation fails:**
- Ensure apt repositories are configured correctly
- Run `sudo apt-get update` before executing the script
- Check disk space for signature database downloads

**Scan takes too long:**
- Large directories with many files take proportionally longer
- Consider scanning specific subdirectories instead of root (/)
- Monitor disk I/O and system load with `top` or `iotop`

**Permission denied errors during scanning:**
- Some directories require root access to scan
- The script must be run with `sudo` for full system access
- Some files may be locked by running processes (this is normal and won't cause errors)

#### Officials Sources

- **ClamAV Documentation:** https://www.clamav.net/
- **Maldet Repository:** https://github.com/rfxn/linux-malware-detect
- **ClamAV Package:** https://packages.ubuntu.com/search?keywords=clamav

#### Performance Considerations

- **First Run:** Takes longer due to engine installations and initial signature downloads
- **Large Directories:** Scanning `/` or other large directories may take 30+ minutes
- **System Impact:** Heavy I/O usage during scanning; consider running during off-peak hours
- **Signature Updates:** Each scan updates signatures, adding 1-2 minutes to execution time
- **Disk Space:** Ensure adequate space for logs in `/var/log/malscan/`

#### License

These scripts are provided as-is for Ubuntu system administration.

---

Execute the specific scripts from Terminal.
