#!/bin/bash
set -euo pipefail

############################################################
# Raspberry Pi Information Collector
# Collects hardware and system information
# Saves to Dropbox with format: SERIAL_YYYY-MM-DD.txt
# Also emails a text report + CSV attachment (if configured)
############################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

############################################################
# Check if running on Raspberry Pi
############################################################
if [ ! -f /proc/cpuinfo ]; then
  log_error "Cannot read /proc/cpuinfo - are you on a Raspberry Pi?"
  exit 1
fi

############################################################
# Collect Information Functions
############################################################

get_serial() {
  # Try multiple methods to get serial number
  local serial=""
  
  # Method 1: /proc/cpuinfo
  if [ -f /proc/cpuinfo ]; then
    serial=$(grep -i "^Serial" /proc/cpuinfo | awk '{print $3}' | sed 's/^0*//')
  fi
  
  # Method 2: Device tree
  if [ -z "$serial" ] && [ -f /proc/device-tree/serial-number ]; then
    serial=$(tr -d '\0' < /proc/device-tree/serial-number)
  fi
  
  # Fallback: use hostname if no serial found
  if [ -z "$serial" ]; then
    serial="unknown_$(hostname)"
  fi
  
  echo "$serial"
}

get_model() {
  local model=""
  
  # Try device tree first
  if [ -f /proc/device-tree/model ]; then
    model=$(tr -d '\0' < /proc/device-tree/model)
  fi
  
  # Fallback to /proc/cpuinfo
  if [ -z "$model" ] && [ -f /proc/cpuinfo ]; then
    model=$(grep -i "^Model" /proc/cpuinfo | cut -d: -f2 | xargs)
  fi
  
  # Final fallback
  if [ -z "$model" ]; then
    model="Unknown Raspberry Pi"
  fi
  
  echo "$model"
}

get_revision() {
  if [ -f /proc/cpuinfo ]; then
    grep -i "^Revision" /proc/cpuinfo | awk '{print $3}'
  else
    echo "Unknown"
  fi
}

get_memory() {
  # Total RAM in human-readable format
  free -h | awk '/^Mem:/ {print $2}'
}

get_storage() {
  # SD card size and usage
  df -h / | awk 'NR==2 {print $2 " (Used: " $3 ", Available: " $4 ", " $5 " used)"}'
}

get_usb_info() {
  # Count and list USB devices
  if command -v lsusb &> /dev/null; then
    local usb_count
    usb_count=$(lsusb | wc -l)
    echo "USB Devices Found: $usb_count"
    lsusb
  else
    echo "lsusb not available - install usbutils"
  fi
}

get_usb_ports() {
  # Try to determine number of physical USB ports/controllers
  if [ -d /sys/bus/usb/devices ]; then
    local ports
    ports=$(find /sys/bus/usb/devices -name "usb*" -type d | wc -l)
    echo "$ports USB controllers detected"
  else
    echo "Unknown"
  fi
}

get_network_interfaces() {
  echo "=== Network Interfaces ==="
  ip -br addr show | grep -v "^lo" || echo "No interfaces found"
  echo ""
  
  # MAC addresses
  echo "=== MAC Addresses ==="
  for iface in /sys/class/net/*; do
    if [ "$(basename "$iface")" != "lo" ]; then
      local mac
      mac=$(cat "$iface/address" 2>/dev/null || echo "N/A")
      echo "$(basename "$iface"): $mac"
    fi
  done
}

get_wifi_info() {
  echo "=== WiFi Information ==="
  
  # Check if WiFi interface exists
  local wifi_iface
  wifi_iface=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
  
  if [ -n "$wifi_iface" ]; then
    echo "WiFi Interface: $wifi_iface"
    
    # Current connection
    if command -v iwgetid &> /dev/null; then
      local ssid
      ssid=$(iwgetid -r 2>/dev/null || echo "Not connected")
      echo "Connected SSID: $ssid"
    fi
    
    # WiFi power
    local wifi_power
    wifi_power=$(iw dev "$wifi_iface" info 2>/dev/null | grep "txpower" | awk '{print $2, $3}')
    if [ -n "$wifi_power" ]; then
      echo "TX Power: $wifi_power"
    fi
    
    # Link quality
    if [ -f "/proc/net/wireless" ]; then
      echo ""
      echo "=== Wireless Signal ==="
      cat /proc/net/wireless
    fi
  else
    echo "No WiFi interface detected"
  fi
}

get_bluetooth_info() {
  echo "=== Bluetooth Information ==="
  
  if command -v hciconfig &> /dev/null; then
    hciconfig -a 2>/dev/null || echo "Bluetooth not available or disabled"
  else
    echo "hciconfig not available - install bluez"
  fi
}

get_os_info() {
  echo "=== Operating System ==="
  
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    echo "Distribution: $PRETTY_NAME"
    echo "Version: $VERSION"
    echo "ID: $ID"
    echo "Codename: $VERSION_CODENAME"
  fi
  
  echo "Kernel: $(uname -r)"
  echo "Architecture: $(uname -m)"
  echo "Hostname: $(hostname)"
}

get_boot_info() {
  echo "=== Boot Configuration ==="
  
  # Check both possible locations for config.txt
  local config_file=""
  if [ -f /boot/firmware/config.txt ]; then
    config_file="/boot/firmware/config.txt"
  elif [ -f /boot/config.txt ]; then
    config_file="/boot/config.txt"
  fi
  
  if [ -n "$config_file" ]; then
    echo "Config file: $config_file"
    echo ""
    grep -v "^#" "$config_file" | grep -v "^$" || echo "No active settings"
  else
    echo "Config file not found"
  fi
}

get_temperature() {
  if command -v vcgencmd &> /dev/null; then
    vcgencmd measure_temp 2>/dev/null || echo "N/A"
  else
    echo "vcgencmd not available"
  fi
}

get_cpu_info() {
  echo "=== CPU Information ==="
  
  if [ -f /proc/cpuinfo ]; then
    echo "Model: $(grep "^model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "Hardware: $(grep "^Hardware" /proc/cpuinfo | cut -d: -f2 | xargs)"
    echo "Cores: $(nproc)"
    echo "BogoMIPS: $(grep "^BogoMIPS" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
  fi
  
  # CPU frequency
  if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
    local freq
    freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
    echo "Current Frequency: $((freq / 1000)) MHz"
  fi
  
  # Temperature
  echo "Temperature: $(get_temperature)"
}

get_gpio_info() {
  echo "=== GPIO Information ==="
  
  if command -v pinout &> /dev/null; then
    echo "GPIO layout available via 'pinout' command"
    echo "Run 'pinout' on the Pi to see the full layout"
  fi
  
  # List available GPIO pins
  if [ -d /sys/class/gpio ]; then
    echo "GPIO sysfs available at /sys/class/gpio"
  fi
}

get_installed_packages() {
  echo "=== Key Installed Packages ==="
  
  local packages=("python3" "git" "nodejs" "docker" "nginx" "apache2")
  
  for pkg in "${packages[@]}"; do
    if command -v "$pkg" &> /dev/null; then
      local version
      version=$($pkg --version 2>&1 | head -1)
      echo "$pkg: $version"
    fi
  done
}

get_uptime_info() {
  echo "=== System Uptime ==="
  uptime -p
  echo "Boot time: $(uptime -s)"
}

get_setup_settings() {
  echo "=== Setup Script Related Settings ==="
  
  # Boot config file
  local config_file=""
  if [ -f /boot/firmware/config.txt ]; then
    config_file="/boot/firmware/config.txt"
  elif [ -f /boot/config.txt ]; then
    config_file="/boot/config.txt"
  else
    config_file="Not found"
  fi
  echo "Boot Config File: $config_file"
  
  # SPI / I2C / Camera
  local spi_state="unknown"
  local i2c_state="unknown"
  local cam_state="unknown"
  
  if [ -f "$config_file" ]; then
    if grep -q '^dtparam=spi=on' "$config_file" 2>/dev/null; then
      spi_state="enabled"
    else
      spi_state="disabled"
    fi
    if grep -q '^dtparam=i2c_arm=on' "$config_file" 2>/dev/null; then
      i2c_state="enabled"
    else
      i2c_state="disabled"
    fi
  fi
  
  if command -v vcgencmd >/dev/null 2>&1; then
    if vcgencmd get_camera 2>/dev/null | grep -q 'supported=1 detected=1'; then
      cam_state="enabled"
    else
      cam_state="disabled"
    fi
  fi
  
  echo "SPI: $spi_state"
  echo "I2C: $i2c_state"
  echo "Camera: $cam_state"
  
  # Swap
  local swap_total_mb
  swap_total_mb=$(free -m | awk '/^Swap:/ {print $2}')
  local swap_state="disabled"
  if [ -n "${swap_total_mb:-}" ] && [ "$swap_total_mb" -gt 0 ]; then
    swap_state="enabled"
  fi
  echo "Swap: $swap_state (${swap_total_mb:-0} MB)"
  
  # VNC
  local vnc_state="unknown"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled vncserver-x11-serviced.service 2>/dev/null | grep -q enabled; then
      vnc_state="enabled"
    else
      vnc_state="disabled"
    fi
  fi
  echo "VNC: $vnc_state"
  
  # Firewall (UFW)
  local ufw_state="not installed"
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qw "active"; then
      ufw_state="enabled"
    else
      ufw_state="disabled"
    fi
  fi
  echo "Firewall (UFW): $ufw_state"
  
  # Git config
  local git_user git_
  git_user="$(git config --global user.name 2>/dev/null || echo "not set")"
  git_="$(git config --global user. 2>/dev/null || echo "not set")"
  echo "Git User: $git_user"
  echo "Git : $git_"
  
  # Python requests package
  local requests_state="not installed"
  if command -v pip3 >/dev/null 2>&1; then
    if pip3 list 2>/dev/null | grep -qw requests; then
      requests_state="installed"
    fi
  fi
  echo "Python 'requests' package: $requests_state"
  
  # Setup profile
  local profile
  profile="$(grep PROFILE= "$HOME/.rpi_setup_state" 2>/dev/null | cut -d= -f2 | grep -oE '[^ ]+' || echo "not set")"
  echo "Setup Profile: $profile"
  
  # Network manager
  local net_mgr="unknown"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet dhcpcd 2>/dev/null; then
      net_mgr="dhcpcd"
    elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
      net_mgr="NetworkManager"
    fi
  fi
  echo "Network Manager: $net_mgr"
}

############################################################
# CSV helper (for attachment)
############################################################

csv_escape() {
  local s="$1"
  s="${s//\"/\"\"}"
  echo "$s"
}

collect_csv_info() {
  local csv=""
  csv+="\"Key\",\"Value\"\n"
  
  local serial model revision mem
  serial=$(get_serial)
  model=$(get_model)
  revision=$(get_revision)
  mem=$(get_memory)
  
  # Root filesystem stats
  local root_size root_used root_avail root_usepct
  read -r _ root_size root_used root_avail root_usepct _ < <(df -h / | awk 'NR==2 {print $1, $2, $3, $4, $5, $6}')
  
  # OS info
  local distro version id codename
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    distro="$PRETTY_NAME"
    version="$VERSION"
    id="$ID"
    codename="$VERSION_CODENAME"
  fi
  local kernel arch hostname_full
  kernel=$(uname -r)
  arch=$(uname -m)
  hostname_full=$(hostname)
  
  local uptime_human boot_time
  uptime_human=$(uptime -p)
  boot_time=$(uptime -s)
  
  # Swap info
  local swap_total_mb swap_state
  swap_total_mb=$(free -m | awk '/^Swap:/ {print $2}')
  swap_state="disabled"
  if [ -n "${swap_total_mb:-}" ] && [ "$swap_total_mb" -gt 0 ]; then
    swap_state="enabled"
  fi
  
  # WiFi info
  local wifi_iface wifi_ssid
  wifi_iface=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}') || true
  if [ -n "${wifi_iface:-}" ] && command -v iwgetid &> /dev/null; then
    wifi_ssid=$(iwgetid -r 2>/dev/null || echo "Not connected")
  else
    wifi_ssid="N/A"
  fi
  
  # USB controllers count
  local usb_ctrl="Unknown"
  if [ -d /sys/bus/usb/devices ]; then
    usb_ctrl=$(find /sys/bus/usb/devices -name "usb*" -type d | wc -l)
  fi
  
  # Add basic hardware/OS/system info
  csv+="\"Serial Number\",\"$(csv_escape "$serial")\"\n"
  csv+="\"Hostname\",\"$(csv_escape "$hostname_full")\"\n"
  csv+="\"Model\",\"$(csv_escape "$model")\"\n"
  csv+="\"Revision\",\"$(csv_escape "$revision")\"\n"
  csv+="\"Memory\",\"$(csv_escape "$mem")\"\n"
  csv+="\"Root FS Total\",\"$(csv_escape "$root_size")\"\n"
  csv+="\"Root FS Used\",\"$(csv_escape "$root_used")\"\n"
  csv+="\"Root FS Available\",\"$(csv_escape "$root_avail")\"\n"
  csv+="\"Root FS Use %\",\"$(csv_escape "$root_usepct")\"\n"
  csv+="\"Swap Total (MB)\",\"$(csv_escape "${swap_total_mb:-0}")\"\n"
  csv+="\"Swap State\",\"$(csv_escape "$swap_state")\"\n"
  csv+="\"OS Distribution\",\"$(csv_escape "$distro")\"\n"
  csv+="\"OS Version\",\"$(csv_escape "$version")\"\n"
  csv+="\"OS ID\",\"$(csv_escape "$id")\"\n"
  csv+="\"OS Codename\",\"$(csv_escape "$codename")\"\n"
  csv+="\"Kernel\",\"$(csv_escape "$kernel")\"\n"
  csv+="\"Architecture\",\"$(csv_escape "$arch")\"\n"
  csv+="\"Uptime\",\"$(csv_escape "$uptime_human")\"\n"
  csv+="\"Boot Time\",\"$(csv_escape "$boot_time")\"\n"
  csv+="\"USB Controllers\",\"$(csv_escape "$usb_ctrl")\"\n"
  csv+="\"WiFi Interface\",\"$(csv_escape "${wifi_iface:-N/A}")\"\n"
  csv+="\"WiFi SSID\",\"$(csv_escape "$wifi_ssid")\"\n"
  
  # Parse setup-related settings into CSV
  local setup_lines
  setup_lines=$(get_setup_settings)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == ===* ]] && continue
    if [[ "$line" == *:* ]]; then
      local key="${line%%:*}"
      local val="${line#*: }"
      csv+="\"$(csv_escape "$key")\",\"$(csv_escape "$val")\"\n"
    fi
  done <<< "$setup_lines"
  
  echo -e "$csv"
}

############################################################
# Main Collection Function
############################################################

collect_all_info() {
  local output=""
  
  output+="============================================\n"
  output+="RASPBERRY PI SYSTEM INFORMATION\n"
  output+="============================================\n"
  output+="Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')\n"
  output+="============================================\n\n"
  
  output+="=== Hardware Identification ===\n"
  output+="Serial Number: $(get_serial)\n"
  output+="Model: $(get_model)\n"
  output+="Revision: $(get_revision)\n"
  output+="Memory: $(get_memory)\n"
  output+="Storage: $(get_storage)\n"
  output+="\n"
  
  output+="$(get_cpu_info)\n\n"
  output+="$(get_os_info)\n\n"
  output+="$(get_uptime_info)\n\n"
  
  output+="=== USB Information ===\n"
  output+="$(get_usb_ports)\n"
  output+="$(get_usb_info)\n\n"
  
  output+="$(get_network_interfaces)\n\n"
  output+="$(get_wifi_info)\n\n"
  output+="$(get_bluetooth_info)\n\n"
  output+="$(get_gpio_info)\n\n"
  output+="$(get_boot_info)\n\n"
  output+="$(get_installed_packages)\n\n"
  output+="$(get_setup_settings)\n\n"
  
  output+="============================================\n"
  output+="END OF REPORT\n"
  output+="============================================\n"
  
  echo -e "$output"
}

############################################################
#  the file (text + CSV attachment)
############################################################

send_() {
  local content_text="$1"
  local content_csv="$2"
  local subject="$3"
  local email_to="$4"
  local csvsubject="$4"
  
  local serial="$5"      # just for logging if needed
  local date_stamp="$6"  # just for logging if needed
  
  # Create temporary files
  local tmp_text tmp_csv
  tmp_text=$(mktemp)
  tmp_csv=$(mktemp)
  
  echo -e "$content_text" > "$tmp_text"
  echo -e "$content_csv" > "$tmp_csv"
  
  local hostname_full
  hostname_full=$(hostname)
  
  local boundary="====MIME_BOUNDARY_$$_${RANDOM}===="
  local csv_filename="${csvsubject}.csv"
  
  log_info "Sending email to: $email_to"
  log_info "Email subject: $subject"
  
  # Method 1: msmtp (preferred, since your setup script configures it)
  if command -v msmtp &> /dev/null; then
    (
      echo "To: $email_to"
      echo "From: pi@${hostname_full}"
      echo "Subject: $subject"
      echo "MIME-Version: 1.0"
      echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
      echo
      echo "--$boundary"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 7bit"
      echo
      cat "$tmp_text"
      echo
      echo "--$boundary"
      echo "Content-Type: text/csv; name=\"$csv_filename\""
      echo "Content-Disposition: attachment; filename=\"$csv_filename\""
      echo "Content-Transfer-Encoding: 7bit"
      echo
      cat "$tmp_csv"
      echo
      echo "--$boundary--"
    ) | msmtp "$email_to"
    
    if [ $? -eq 0 ]; then
      rm -f "$tmp_text" "$tmp_csv"
      log_success "Email (with CSV attachment) sent successfully via msmtp"
      return 0
    fi
  fi
  
  # Method 2: sendmail
  if command -v sendmail &> /dev/null; then
    (
      echo "To: $email_to"
      echo "From: pi@${hostname_full}"
      echo "Subject: $subject"
      echo "MIME-Version: 1.0"
      echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
      echo
      echo "--$boundary"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 7bit"
      echo
      cat "$tmp_text"
      echo
      echo "--$boundary"
      echo "Content-Type: text/csv; name=\"$csv_filename\""
      echo "Content-Disposition: attachment; filename=\"$csv_filename\""
      echo "Content-Transfer-Encoding: 7bit"
      echo
      cat "$tmp_csv"
      echo
      echo "--$boundary--"
    ) | sendmail -t
    
    if [ $? -eq 0 ]; then
      rm -f "$tmp_text" "$tmp_csv"
      log_success "Email (with CSV attachment) sent successfully via sendmail"
      return 0
    fi
  fi
  
  # Method 3: mail/mailx (using -a for attachment if available)
  if command -v mail &> /dev/null; then
    if mail -V 2>&1 | grep -qi "GNU Mailutils"; then
      # GNU mailutils supports -a for attachments
      mail -s "$subject" -a "$tmp_csv" "$email_to" < "$tmp_text"
    else
      # Fallback: send text only, mention that CSV attachment is skipped
      log_warning "mail command does not support -a attachment; sending text-only email"
      mail -s "$subject" "$email_to" < "$tmp_text"
    fi
    
    if [ $? -eq 0 ]; then
      rm -f "$tmp_text" "$tmp_csv"
      log_success "Email sent via mail/mailx (CSV may or may not be attached depending on implementation)"
      return 0
    fi
  fi
  
  rm -f "$tmp_text" "$tmp_csv"
  log_error "No suitable email client found or sending failed. Install and configure msmtp, sendmail, or mailx."
  log_info "To install msmtp: sudo apt-get install msmtp msmtp-mta"
  return 1
}

############################################################
# Save to Dropbox
############################################################

save_to_dropbox() {
  local content="$1"
  local serial="$2"
  local date_stamp="$3"
  local filename="${serial}_${date_stamp}.txt"
  
  # Check if Dropbox folder exists
  local dropbox_paths=(
    "$HOME/Dropbox"
    "$HOME/dropbox"
    "/mnt/dropbox"
  )
  
  local dropbox_dir=""
  for path in "${dropbox_paths[@]}"; do
    if [ -d "$path" ]; then
      dropbox_dir="$path"
      break
    fi
  done
  
  if [ -z "$dropbox_dir" ]; then
    log_warning "Dropbox folder not found at standard locations"
    log_info "Attempting to create ~/Dropbox directory..."
    mkdir -p "$HOME/Dropbox"
    dropbox_dir="$HOME/Dropbox"
  fi
  
  # Create subdirectory for Pi info
  local save_dir="$dropbox_dir/RaspberryPi_Info"
  mkdir -p "$save_dir"
  
  local filepath="$save_dir/$filename"
  
  # Save the file
  echo -e "$content" > "$filepath"
  
  if [ -f "$filepath" ]; then
    log_success "Information saved to: $filepath"
    echo ""
    echo "File details:"
    ls -lh "$filepath"
    return 0
  else
    log_error "Failed to save file to: $filepath"
    return 1
  fi
}

############################################################
# Main Execution
############################################################

# Parse command line arguments
EMAIL_ADDRESS=""
SKIP_DROPBOX=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --email|-e)
      EMAIL_ADDRESS="$2"
      shift 2
      ;;
    --no-dropbox)
      SKIP_DROPBOX=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  -e, --email EMAIL        Send results to email address"
      echo "  --no-dropbox             Skip saving to Dropbox"
      echo "  -h, --help               Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                              # Save to Dropbox only"
      echo "  $0 --email user@example.com     # Email and save to Dropbox"
      echo "  $0 -e user@example.com --no-dropbox  # Email only"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

echo "=========================================="
echo "Raspberry Pi Information Collector"
echo "=========================================="
echo ""

log_info "Collecting system information..."

# Get serial number and date/time
SERIAL=$(get_serial)
DATE_STAMP=$(date '+%Y-%m-%d')
TIME_STAMP=$(date '+%H:%M')
HOSTNAME_FULL=$(hostname)

# Build email/CSV subject:
# Raspberry Pi Info - <hostname> - <serial> - YYYY-MM-DD HH:MM
EMAIL_SUBJECT="Raspberry Pi Info - ${HOSTNAME_FULL} - ${SERIAL} - ${DATE_STAMP} ${TIME_STAMP}"
CSVSUBJECT=${HOSTNAME_FULL}
log_info "Serial Number: $SERIAL"
log_info "Date: $DATE_STAMP"
log_info "Time: $TIME_STAMP"
log_info "Email Subject / CSV Filename base: $EMAIL_SUBJECT"
echo ""

# Collect all information (text report)
INFO=$(collect_all_info)

# Collect CSV info
CSV_INFO=$(collect_csv_info)

# Display to screen
echo "$INFO"
echo ""

# Save to Dropbox (text report only)
if [ "$SKIP_DROPBOX" = false ]; then
  log_info "Saving to Dropbox..."
  save_to_dropbox "$INFO" "$SERIAL" "$DATE_STAMP"
fi

# Send email if requested (text + CSV attachment)
if [ -n "$EMAIL_ADDRESS" ]; then
  echo ""
  send_email "$INFO" "$CSV_INFO" "$EMAIL_SUBJECT" "$EMAIL_ADDRESS" "$SERIAL" "$DATE_STAMP"
fi

echo ""
log_success "Collection complete!"
echo ""
log_info "You can also save this output with:"
echo "  ./$(basename "$0") > ~/rpi_info_${SERIAL}_${DATE_STAMP}.txt"
