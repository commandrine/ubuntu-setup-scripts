#!/usr/bin/env bash
#
# install_maldet_clamav_server.sh
#
# Installs and configures:
# - Linux Malware Detect, also known as LMD or maldet
# - ClamAV, clamd and freshclam
# - Daily scans of recently modified files
# - Weekly complete scans of configured paths
# - Optional real-time inotify monitoring
# - Optional email alerts
#
# Supported target:
# Ubuntu or Debian server using systemd
#
# Run as root:
# sudo bash install_maldet_clamav_server.sh
#
# IMPORTANT:
# 1. Review all configuration variables before running.
# 2. Test automatic quarantine in a non-production environment first.
# 3. Exclude backup, database, container and mounted-storage paths where
# appropriate for your environment.
 
set -Eeuo pipefail
IFS=$'\n\t'
umask 027
 
# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
 
LMD_INSTALL_DIR="/usr/local/maldetect"
LMD_CONFIG_FILE="${LMD_INSTALL_DIR}/conf.maldet"
 
LMD_DOWNLOAD_URL="https://www.rfxn.com/downloads/maldetect-current.tar.gz"
LMD_CHECKSUM_URL="https://www.rfxn.com/downloads/maldetect-current.tar.gz.md5"
 
INSTALL_LOG="/var/log/maldet-install.log"
SCAN_LOG="/var/log/maldet-scheduled-scan.log"
 
# Paths covered by daily recent-file and weekly full scans.
#
# Remove paths that do not exist or are not relevant to the server.
# Avoid scanning remote mounts, backup repositories, large database data
# directories or container overlay filesystems unless specifically required.
SCAN_PATHS=(
"/var/www"
"/home"
"/tmp"
"/var/tmp"
"/dev/shm"
)
 
# Number of days examined by the daily recent-file scan.
RECENT_SCAN_DAYS=1
 
# Initial scan:
# recent = scan files changed during RECENT_SCAN_DAYS
# full = scan every file under SCAN_PATHS
# none = do not initiate a scan during installation
INITIAL_SCAN_MODE="recent"
 
# Automatic quarantine:
# 1 = automatically quarantine malware hits
# 0 = report only
#
# For a new production deployment, consider starting with 0, reviewing false
# positives, and changing this to 1 only after validation.
AUTO_QUARANTINE=0
 
# Automatic cleaning should normally remain disabled.
# Cleaning modifies quarantined files and can affect forensic evidence.
AUTO_CLEAN=0
 
# Enable the ClamAV engine in Maldet.
ENABLE_CLAMAV_ENGINE=1
 
# Enable native YARA scanning if supported by the installed LMD version.
ENABLE_YARA=1
 
# Email alerts:
# Leave blank to disable email alerting.
# A working local MTA or LMD SMTP relay configuration is required.
ALERT_EMAIL=""
 
# Optional inotify monitoring:
# 1 = enable persistent real-time monitoring
# 0 = do not enable monitoring
#
# Monitor only high-risk writable or upload paths. Do not automatically
# monitor all of /tmp or /var/www unless the additional load is acceptable.
ENABLE_REALTIME_MONITOR=0
 
MONITOR_PATHS=(
"/var/www/uploads"
)
 
MONITOR_PATH_FILE="${LMD_INSTALL_DIR}/monitor_paths.server"
 
# Resource priorities used by scheduled scans.
CPU_NICE_LEVEL=15
IO_PRIORITY_CLASS=2
IO_PRIORITY_LEVEL=7
 
# Cron schedules.
#
# Daily recent scan: 02:15 every day
# Weekly full scan: 03:30 every Sunday
DAILY_CRON_SCHEDULE="15 2 * * *"
WEEKLY_CRON_SCHEDULE="30 3 * * 0"
 
DAILY_RUNNER="/usr/local/sbin/maldet-daily-scan"
WEEKLY_RUNNER="/usr/local/sbin/maldet-weekly-scan"
CRON_FILE="/etc/cron.d/maldet-custom-scans"
 
# Lock prevents daily and weekly scans from running simultaneously.
SCAN_LOCK="/run/lock/maldet-custom-scan.lock"
 
# Common paths generally worth excluding from broad scans.
#
# These entries use Maldet's ignore-path file. Review before deployment.
EXCLUDED_PATHS=(
"/proc"
"/sys"
"/run"
"/var/lib/docker"
"/var/lib/containerd"
"/var/lib/lxc"
"/var/lib/libvirt/images"
"/var/lib/mysql"
"/var/lib/postgresql"
"/var/cache"
"/var/backups"
"/backup"
"/backups"
"/mnt"
"/media"
)
 
# ---------------------------------------------------------------------------
# General functions
# ---------------------------------------------------------------------------
 
timestamp() {
date '+%Y-%m-%d %H:%M:%S%z'
}
 
log() {
printf '[%s] %s\n' "$(timestamp)" "$*"
}
 
fatal() {
log "ERROR: $*"
exit 1
}
 
on_error() {
local exit_code=$?
local line_number=${1:-unknown}
 
log "ERROR: Script failed at line ${line_number}, exit code ${exit_code}."
exit "$exit_code"
}
 
trap 'on_error "$LINENO"' ERR
 
require_root() {
if [[ "${EUID}" -ne 0 ]]; then
fatal "Run this script as root, for example: sudo bash $0"
fi
}
 
validate_platform() {
[[ -r /etc/os-release ]] || fatal "/etc/os-release is unavailable."
 
# shellcheck disable=SC1091
source /etc/os-release
 
case "${ID:-}" in
ubuntu|debian)
;;
*)
if [[ "${ID_LIKE:-}" != *debian* ]]; then
fatal "This script is intended for Ubuntu or Debian systems."
fi
;;
esac
 
command -v systemctl >/dev/null 2>&1 ||
fatal "systemd is required by this script."
}
 
path_exists() {
[[ -e "$1" ]]
}
 
set_lmd_config() {
local key="$1"
local value="$2"
local escaped_value
 
[[ -f "$LMD_CONFIG_FILE" ]] ||
fatal "Maldet configuration not found: ${LMD_CONFIG_FILE}"
 
# Escape characters that are significant in the sed replacement.
escaped_value=$(printf '%s' "$value" | sed 's/[&|\]/\\&/g')
 
if grep -Eq "^[[:space:]#]*${key}[[:space:]]*=" \
"$LMD_CONFIG_FILE"; then
sed -Ei \
"s|^[[:space:]#]*${key}[[:space:]]*=.*|${key}=${escaped_value}|" \
"$LMD_CONFIG_FILE"
else
printf '\n%s=%s\n' "$key" "$value" >> "$LMD_CONFIG_FILE"
fi
}
 
maldet_scan_exit_handler() {
local exit_code="$1"
local description="$2"
 
case "$exit_code" in
0)
log "${description}: completed with no malware hits."
;;
2)
log "WARNING: ${description}: malware hits were detected."
log "Review the report with: maldet --report latest"
;;
*)
log "ERROR: ${description}: scan failed with exit code ${exit_code}."
return "$exit_code"
;;
esac
}
 
# ---------------------------------------------------------------------------
# Initial setup and logging
# ---------------------------------------------------------------------------
 
require_root
validate_platform
 
touch "$INSTALL_LOG"
chmod 0640 "$INSTALL_LOG"
 
exec > >(tee -a "$INSTALL_LOG") 2>&1
 
log "Starting Maldet and ClamAV server installation."
log "Installation log: ${INSTALL_LOG}"
 
# ---------------------------------------------------------------------------
# Install operating-system packages
# ---------------------------------------------------------------------------
 
log "Updating package indexes."
 
export DEBIAN_FRONTEND=noninteractive
 
apt-get update
 
log "Installing ClamAV and required utilities."
 
apt-get install -y \
ca-certificates \
clamav \
clamav-daemon \
clamav-freshclam \
curl \
inotify-tools \
util-linux
 
# nice is provided by coreutils and ionice by util-linux.
command -v nice >/dev/null 2>&1 ||
fatal "The nice command is unavailable."
 
command -v ionice >/dev/null 2>&1 ||
fatal "The ionice command is unavailable."
 
# ---------------------------------------------------------------------------
# Update ClamAV signatures
# ---------------------------------------------------------------------------
 
log "Updating ClamAV signatures."
 
# A running freshclam daemon can hold the database-update lock. Stop it
# temporarily for the initial manual update, then start it again.
systemctl stop clamav-freshclam.service 2>/dev/null || true
 
FRESHCLAM_EXIT=0
freshclam || FRESHCLAM_EXIT=$?
 
if [[ "$FRESHCLAM_EXIT" -ne 0 ]]; then
log "WARNING: The initial freshclam update returned exit code ${FRESHCLAM_EXIT}."
log "Existing ClamAV signatures, if present, will be retained."
fi
 
systemctl enable clamav-freshclam.service
systemctl start clamav-freshclam.service
 
systemctl enable clamav-daemon.service
 
if systemctl restart clamav-daemon.service; then
log "ClamAV daemon is enabled and running."
else
log "WARNING: clamav-daemon did not start successfully."
log "Check: journalctl -u clamav-daemon.service"
fi
 
# ---------------------------------------------------------------------------
# Download and verify Linux Malware Detect
# ---------------------------------------------------------------------------
 
WORK_DIR=$(mktemp -d -t maldet-install.XXXXXXXX)
 
cleanup() {
rm -rf "$WORK_DIR"
}
 
trap cleanup EXIT
 
log "Downloading Linux Malware Detect over HTTPS."
 
curl \
--fail \
--silent \
--show-error \
--location \
--proto '=https' \
--tlsv1.2 \
--output "${WORK_DIR}/maldetect-current.tar.gz" \
"$LMD_DOWNLOAD_URL"
 
[[ -s "${WORK_DIR}/maldetect-current.tar.gz" ]] ||
fatal "Downloaded Maldet archive is empty."
 
log "Downloading the vendor-provided checksum."
 
curl \
--fail \
--silent \
--show-error \
--location \
--proto '=https' \
--tlsv1.2 \
--output "${WORK_DIR}/maldetect-current.tar.gz.md5" \
"$LMD_CHECKSUM_URL"
 
[[ -s "${WORK_DIR}/maldetect-current.tar.gz.md5" ]] ||
fatal "Downloaded checksum file is empty."
 
log "Validating the Maldet archive checksum."
 
(
cd "$WORK_DIR"
 
# Vendor checksum files can contain either:
# HASH filename
# or only:
# HASH
#
# Extract the first 32-character hexadecimal hash and validate it
# against the known local filename.
EXPECTED_MD5=$(
grep -Eio '[a-f0-9]{32}' maldetect-current.tar.gz.md5 |
head -n 1
)
 
[[ -n "$EXPECTED_MD5" ]] ||
fatal "No MD5 checksum could be parsed from the vendor checksum file."
 
printf '%s %s\n' \
"$EXPECTED_MD5" \
"maldetect-current.tar.gz" |
md5sum --check --strict -
)
 
log "Maldet archive checksum validated."
 
# ---------------------------------------------------------------------------
# Extract and install Linux Malware Detect
# ---------------------------------------------------------------------------
 
log "Extracting Linux Malware Detect."
 
tar \
--extract \
--gzip \
--file "${WORK_DIR}/maldetect-current.tar.gz" \
--directory "$WORK_DIR" \
--no-same-owner
 
LMD_SOURCE_DIR=$(
find "$WORK_DIR" \
-mindepth 1 \
-maxdepth 1 \
-type d \
-name 'maldetect-*' \
-print |
sort |
head -n 1
)
 
[[ -n "$LMD_SOURCE_DIR" ]] ||
fatal "Could not locate the extracted Maldet source directory."
 
[[ -x "${LMD_SOURCE_DIR}/install.sh" ]] ||
chmod 0755 "${LMD_SOURCE_DIR}/install.sh"
 
log "Installing Linux Malware Detect."
 
(
cd "$LMD_SOURCE_DIR"
./install.sh
)
 
[[ -x /usr/local/sbin/maldet ]] ||
fatal "The Maldet executable was not installed in /usr/local/sbin."
 
[[ -f "$LMD_CONFIG_FILE" ]] ||
fatal "Maldet configuration was not installed at ${LMD_CONFIG_FILE}."
 
log "Linux Malware Detect installed successfully."
 
# ---------------------------------------------------------------------------
# Back up and configure Maldet
# ---------------------------------------------------------------------------
 
CONFIG_BACKUP="${LMD_CONFIG_FILE}.before-server-config.$(date '+%Y%m%d%H%M%S')"
 
cp --preserve=mode,ownership,timestamps \
"$LMD_CONFIG_FILE" \
"$CONFIG_BACKUP"
 
log "Original Maldet configuration backed up to ${CONFIG_BACKUP}."
 
# Automatic updates and routine maintenance.
set_lmd_config "autoupdate_signatures" "1"
set_lmd_config "autoupdate_version" "1"
set_lmd_config "autoupdate_version_hashed" "1"
set_lmd_config "cron_daily_scan" "0"
set_lmd_config "cron_prune_days" "30"
set_lmd_config "scan_days" "$RECENT_SCAN_DAYS"
 
# Explicit custom cron jobs are installed later. Disable the default LMD
# daily scan to avoid duplicate scanning. Signature and version updates
# remain enabled through LMD's signature updater and maintenance mechanisms.
#
# If you prefer Maldet's control-panel-aware daily scan, set
# cron_daily_scan=1 and remove the custom daily scan from CRON_FILE.
 
# ClamAV and YARA integration.
if [[ "$ENABLE_CLAMAV_ENGINE" -eq 1 ]]; then
set_lmd_config "scan_clamscan" "1"
else
set_lmd_config "scan_clamscan" "0"
fi
 
if [[ "$ENABLE_YARA" -eq 1 ]]; then
set_lmd_config "scan_yara" "1"
else
set_lmd_config "scan_yara" "0"
fi
 
# Quarantine and cleaning.
set_lmd_config "quarantine_hits" "$AUTO_QUARANTINE"
set_lmd_config "quarantine_clean" "$AUTO_CLEAN"
 
# Do not suspend hosting accounts automatically.
set_lmd_config "quarantine_suspend_user" "0"
 
# Avoid quarantining files purely because the scan engine encountered an
# error. Report and investigate engine errors instead.
set_lmd_config "quarantine_on_error" "0"
 
# Email alerting.
if [[ -n "$ALERT_EMAIL" ]]; then
set_lmd_config "email_alert" "1"
set_lmd_config "email_addr" "\"${ALERT_EMAIL}\""
log "Maldet email alerts enabled for ${ALERT_EMAIL}."
else
set_lmd_config "email_alert" "0"
log "Maldet email alerts disabled because ALERT_EMAIL is empty."
fi
 
chmod 0600 "$LMD_CONFIG_FILE"
 
# ---------------------------------------------------------------------------
# Configure ignore paths
# ---------------------------------------------------------------------------
 
IGNORE_PATH_FILE="${LMD_INSTALL_DIR}/ignore_paths"
 
touch "$IGNORE_PATH_FILE"
cp \
"$IGNORE_PATH_FILE" \
"${IGNORE_PATH_FILE}.before-server-config.$(date '+%Y%m%d%H%M%S')" ||
true
 
log "Adding configured exclusions to ${IGNORE_PATH_FILE}."
 
for excluded_path in "${EXCLUDED_PATHS[@]}"; do
if ! grep -Fqx "$excluded_path" "$IGNORE_PATH_FILE"; then
printf '%s\n' "$excluded_path" >> "$IGNORE_PATH_FILE"
fi
done
 
sort -u -o "$IGNORE_PATH_FILE" "$IGNORE_PATH_FILE"
chmod 0600 "$IGNORE_PATH_FILE"
 
# ---------------------------------------------------------------------------
# Validate configured scan paths
# ---------------------------------------------------------------------------
 
VALID_SCAN_PATHS=()
 
for scan_path in "${SCAN_PATHS[@]}"; do
if path_exists "$scan_path"; then
VALID_SCAN_PATHS+=("$scan_path")
else
log "WARNING: Scan path does not exist and will be skipped: ${scan_path}"
fi
done
 
if [[ "${#VALID_SCAN_PATHS[@]}" -eq 0 ]]; then
fatal "None of the configured scan paths exists."
fi
 
log "Validated scan paths:"
 
for scan_path in "${VALID_SCAN_PATHS[@]}"; do
log " ${scan_path}"
done
 
# ---------------------------------------------------------------------------
# Update Maldet version and signatures
# ---------------------------------------------------------------------------
 
log "Checking for Maldet version updates."
 
UPDATE_VERSION_EXIT=0
maldet --update-ver || UPDATE_VERSION_EXIT=$?
 
if [[ "$UPDATE_VERSION_EXIT" -ne 0 ]]; then
log "WARNING: Maldet version update returned exit code ${UPDATE_VERSION_EXIT}."
fi
 
log "Updating Maldet signatures."
 
UPDATE_SIGNATURE_EXIT=0
maldet --update-sigs || UPDATE_SIGNATURE_EXIT=$?
 
if [[ "$UPDATE_SIGNATURE_EXIT" -ne 0 ]]; then
fatal "Maldet signature update failed with exit code ${UPDATE_SIGNATURE_EXIT}."
fi
 
# Reload ClamAV after LMD updates and links its signatures.
if systemctl is-active --quiet clamav-daemon.service; then
systemctl reload clamav-daemon.service 2>/dev/null ||
systemctl restart clamav-daemon.service 2>/dev/null ||
log "WARNING: Could not reload or restart clamav-daemon."
fi
 
# ---------------------------------------------------------------------------
# Create daily recent-file scan runner
# ---------------------------------------------------------------------------
 
log "Creating daily scan runner: ${DAILY_RUNNER}"
 
cat > "$DAILY_RUNNER" <<EOF
#!/usr/bin/env bash
 
set -uo pipefail
IFS=\$'\n\t'
umask 027
 
LOG_FILE="${SCAN_LOG}"
LOCK_FILE="${SCAN_LOCK}"
RECENT_DAYS="${RECENT_SCAN_DAYS}"
NICE_LEVEL="${CPU_NICE_LEVEL}"
IO_CLASS="${IO_PRIORITY_CLASS}"
IO_LEVEL="${IO_PRIORITY_LEVEL}"
 
SCAN_PATHS=(
$(printf ' %q\n' "${VALID_SCAN_PATHS[@]}")
)
 
timestamp() {
date '+%Y-%m-%d %H:%M:%S%z'
}
 
log() {
printf '[%s] %s\n' "\$(timestamp)" "\$*" >> "\$LOG_FILE"
}
 
touch "\$LOG_FILE"
chmod 0640 "\$LOG_FILE"
 
exec 9>"\$LOCK_FILE"
 
if ! flock -n 9; then
log "Daily scan skipped because another custom Maldet scan is running."
exit 0
fi
 
log "Starting daily recent-file Maldet scan."
log "Recent-file window: \${RECENT_DAYS} day(s)."
 
overall_status=0
 
/usr/local/sbin/maldet --update-sigs >> "\$LOG_FILE" 2>&1 || {
update_status=\$?
log "WARNING: Maldet signature update returned exit code \${update_status}."
}
 
for scan_path in "\${SCAN_PATHS[@]}"; do
if [[ ! -e "\$scan_path" ]]; then
log "WARNING: Scan path no longer exists: \$scan_path"
continue
fi
 
log "Scanning recently modified files under: \$scan_path"
 
scan_status=0
 
ionice -c "\$IO_CLASS" -n "\$IO_LEVEL" \
nice -n "\$NICE_LEVEL" \
/usr/local/sbin/maldet \
--scan-recent "\$scan_path" "\$RECENT_DAYS" \
>> "\$LOG_FILE" 2>&1 || scan_status=\$?
 
case "\$scan_status" in
0)
log "Recent scan completed cleanly: \$scan_path"
;;
2)
log "WARNING: Malware hit detected during recent scan: \$scan_path"
overall_status=2
;;
*)
log "ERROR: Recent scan failed for \$scan_path with exit code \$scan_status."
if [[ "\$overall_status" -ne 2 ]]; then
overall_status=1
fi
;;
esac
done
 
log "Daily recent-file Maldet scan finished with status \$overall_status."
exit "\$overall_status"
EOF
 
chmod 0750 "$DAILY_RUNNER"
chown root:root "$DAILY_RUNNER"
 
# ---------------------------------------------------------------------------
# Create weekly complete scan runner
# ---------------------------------------------------------------------------
 
log "Creating weekly scan runner: ${WEEKLY_RUNNER}"
 
cat > "$WEEKLY_RUNNER" <<EOF
#!/usr/bin/env bash
 
set -uo pipefail
IFS=\$'\n\t'
umask 027
 
LOG_FILE="${SCAN_LOG}"
LOCK_FILE="${SCAN_LOCK}"
NICE_LEVEL="${CPU_NICE_LEVEL}"
IO_CLASS="${IO_PRIORITY_CLASS}"
IO_LEVEL="${IO_PRIORITY_LEVEL}"
 
SCAN_PATHS=(
$(printf ' %q\n' "${VALID_SCAN_PATHS[@]}")
)
 
timestamp() {
date '+%Y-%m-%d %H:%M:%S%z'
}
 
log() {
printf '[%s] %s\n' "\$(timestamp)" "\$*" >> "\$LOG_FILE"
}
 
touch "\$LOG_FILE"
chmod 0640 "\$LOG_FILE"
 
exec 9>"\$LOCK_FILE"
 
if ! flock -n 9; then
log "Weekly scan skipped because another custom Maldet scan is running."
exit 0
fi
 
log "Starting weekly complete Maldet scan."
 
overall_status=0
 
/usr/bin/freshclam >> "\$LOG_FILE" 2>&1 || {
freshclam_status=\$?
log "WARNING: freshclam returned exit code \${freshclam_status}."
}
 
/usr/local/sbin/maldet --update-sigs >> "\$LOG_FILE" 2>&1 || {
update_status=\$?
log "WARNING: Maldet signature update returned exit code \${update_status}."
}
 
for scan_path in "\${SCAN_PATHS[@]}"; do
if [[ ! -e "\$scan_path" ]]; then
log "WARNING: Scan path no longer exists: \$scan_path"
continue
fi
 
log "Running complete scan under: \$scan_path"
 
scan_status=0
 
ionice -c "\$IO_CLASS" -n "\$IO_LEVEL" \
nice -n "\$NICE_LEVEL" \
/usr/local/sbin/maldet \
--scan-all "\$scan_path" \
>> "\$LOG_FILE" 2>&1 || scan_status=\$?
 
case "\$scan_status" in
0)
log "Complete scan finished cleanly: \$scan_path"
;;
2)
log "WARNING: Malware hit detected during complete scan: \$scan_path"
overall_status=2
;;
*)
log "ERROR: Complete scan failed for \$scan_path with exit code \$scan_status."
if [[ "\$overall_status" -ne 2 ]]; then
overall_status=1
fi
;;
esac
done
 
log "Weekly complete Maldet scan finished with status \$overall_status."
exit "\$overall_status"
EOF
 
chmod 0750 "$WEEKLY_RUNNER"
chown root:root "$WEEKLY_RUNNER"
 
# ---------------------------------------------------------------------------
# Configure cron
# ---------------------------------------------------------------------------
 
log "Creating custom Maldet scan schedule: ${CRON_FILE}"
 
cat > "$CRON_FILE" <<EOF
# Managed by install_maldet_clamav_server.sh
#
# Daily recent-file scan
${DAILY_CRON_SCHEDULE} root ${DAILY_RUNNER}
#
# Weekly complete scan
${WEEKLY_CRON_SCHEDULE} root ${WEEKLY_RUNNER}
EOF
 
chmod 0644 "$CRON_FILE"
chown root:root "$CRON_FILE"
 
# Verify cron syntax format at a basic level.
grep -Fq "$DAILY_RUNNER" "$CRON_FILE" ||
fatal "Daily cron entry was not created correctly."
 
grep -Fq "$WEEKLY_RUNNER" "$CRON_FILE" ||
fatal "Weekly cron entry was not created correctly."
 
systemctl enable cron.service
systemctl restart cron.service
 
log "Custom daily and weekly scans have been scheduled."
 
# -----------------------------

