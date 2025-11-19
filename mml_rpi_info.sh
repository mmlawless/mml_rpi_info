#!/bin/bash
set -euo pipefail

############################################################
# Raspberry Pi Information Collector
# Collects hardware and system information
# Saves to Dropbox with format: SERIAL_YYYY-MM-DD.txt
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
    serial=$(cat /proc/device-tree/serial-number | tr -d '\0')
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
    model=$(cat /proc/device-tree/model | tr -d '\0')
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

############################################################
# Setup Script Configuration Summary
# Mirrors the key settings from your setup script
############################################################

get_setup_config_summary() {
  echo "=== Setup Script Configuration Summary ==="

  # Boot config path
  local boot_config=""
  if [ -f /boot/firmware/config.txt ]; then
    boot_config="/boot/firmware/config.txt"
  elif [ -f /boot/config.txt ]; then
    boot_config="/boot/config.txt"
  else
    boot_config="(not found)"
  fi
  echo "Boot config: $boot_config"

  # Network manager (dhcpcd / NetworkManager / unknown)
  local network_manager="unknown"
  if systemctl is-active --quiet dhcpcd 2>/dev/null; then
    network_manager="dhcpcd"
  elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
    network_manager="NetworkManager"
  fi
  echo "Network manager: $network_manager"

  # OS codename
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    echo "OS codename: $VERSION_CODENAME"
  fi

  # Swap
  local current_swap
  current_swap=$(free -m | awk '/^Swap:/ {print $2}')
  local swap_state="disabled"
  if [ "$current_swap" -ge 1024 ]; then
    swap_state="enabled"
  fi
  echo "Swap: $swap_state (${current_swap} MB)"

  # SPI / I2C (from boot config)
  if [ -f "$boot_config" ] && [ "$boot_config" != "(not found)" ]; then
    local spi_state="disabled"
    local i2c_state="disabled"
    grep -q '^dtparam=spi=on' "$boot_config" 2>/dev/null && spi_state="enabled"
    grep -q '^dtparam=i2c_arm=on' "$boot_config" 2>/dev/null && i2c_state="enabled"
    echo "SPI: $spi_state"
    echo "I2C: $i2c_state"
  fi

  # Camera (via vcgencmd)
  if command -v vcgencmd >/dev/null 2>&1; then
    local cam_state="disabled or not detected"
    if vcgencmd get_camera 2>/dev/null | grep -q 'supported=1 detected=1'; then
      cam_state="enabled and detected"
    fi
    echo "Camera: $cam_state"
  fi

  # VNC service
  local vnc_state="unknown"
  if systemctl list-unit-files vncserver-x11-serviced.service >/dev/null 2>&1; then
    if systemctl is-enabled vncserver-x11-serviced.service 2>/dev/null | grep -q enabled; then
      vnc_state="enabled"
    else
      vnc_state="disabled"
    fi
  fi
  echo "VNC service: $vnc_state"

  # Firewall (UFW)
  local ufw_state="disabled"
  if command -v ufw >/dev/null 2>&1; then
    if sudo ufw status 2>/dev/null | grep -qw "active"; then
      ufw_state="enabled"
    fi
  fi
  echo "Firewall (UFW): $ufw_state"

  # Git global config
  local git_name git_email
  git_name="$(git config --global user.name 2>/dev/null || echo "not set")"
  git_email="$(git config --global user.email 2>/dev/null || echo "not set")"
  echo "Git user: $git_name"
  echo "Git email: $git_email"

  # Python 'requests'
  local requests_state="not installed"
  if command -v pip3 >/dev/null 2>&1 && pip3 list 2>/dev/null | grep -qw requests; then
    requests_state="installed"
  fi
  echo "Python 'requests' package: $requests_state"

  # Setup profile from state file
  local profile_state="not set"
  local state_file="$HOME/.rpi_setup_state"
  if [ -f "$state_file" ]; then
    profile_state=$(grep PROFILE= "$state_file" 2>/dev/null | cut -d= -f2 | grep -oE '[^ ]+' || echo "not set")
  fi
  echo "Setup profile: $profile_state"

  # Hostname (for completeness)
  echo "Hostname: $(hostname)"
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
  output+="$(get_setup_config_summary)\n\n"
  output+="$(get_installed_packages)\n\n"
  
  output+="============================================\n"
  output+="END OF REPORT\n"
  output+="============================================\n"
  
  echo -e "$output"
}

############################################################
# Email the file
############################################################

send_email() {
  local content="$1"
  local serial="$2"
  local date_stamp="$3"
  local email_to="$4"
  local filename="${serial}_${date_stamp}.txt"

  # For subject line: include hostname, serial, date and time (HH:MM)
  local host
  host=$(hostname)
  local time_stamp
  time_stamp=$(date '+%H:%M')
  local subject="Raspberry Pi Info - ${host} - ${serial} - ${date_stamp} ${time_stamp}"
  
  # Create temporary file
  local tmpfile
  tmpfile=$(mktemp)
  echo -e "$content" > "$tmpfile"
  
  log_info "Sending email to: $email_to"
  
  # Method 1: Try msmtp (recommended - simple to configure)
  if command -v msmtp &> /dev/null; then
    (
      echo "To: $email_to"
      echo "From: pi@$(hostname)"
      echo "Subject: $subject"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo ""
      cat "$tmpfile"
    ) | msmtp "$email_to"
    
    if [ $? -eq 0 ]; then
      rm "$tmpfile"
      log_success "Email sent successfully via msmtp"
      return 0
    fi
  fi
  
  # Method 2: Try sendmail
  if command -v sendmail &> /dev/null; then
    (
      echo "To: $email_to"
      echo "Subject: $subject"
      echo ""
      cat "$tmpfile"
    ) | sendmail -t
    
    if [ $? -eq 0 ]; then
      rm "$tmpfile"
      log_success "Email sent successfully via sendmail"
      return 0
    fi
  fi
  
  # Method 3: Try mail/mailx
  if command -v mail &> /dev/null; then
    mail -s "$subject" "$email_to" < "$tmpfile"
    
    if [ $? -eq 0 ]; then
      rm "$tmpfile"
      log_success "Email sent successfully via mail"
      return 0
    fi
  fi
  
  rm "$tmpfile"
  log_error "No email client found. Install msmtp, sendmail, or mailx"
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
      echo "  -e, --email EMAIL    Send results to email address"
      echo "  --no-dropbox         Skip saving to Dropbox"
      echo "  -h, --help           Show this help message"
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

# Get serial number and date
SERIAL=$(get_serial)
DATE_STAMP=$(date '+%Y-%m-%d')

log_info "Serial Number: $SERIAL"
log_info "Date: $DATE_STAMP"
echo ""

# Collect all information
INFO=$(collect_all_info)

# Display to screen
echo "$INFO"
echo ""

# Save to Dropbox
if [ "$SKIP_DROPBOX" = false ]; then
  log_info "Saving to Dropbox..."
  save_to_dropbox "$INFO" "$SERIAL" "$DATE_STAMP"
fi

# Send email if requested
if [ -n "$EMAIL_ADDRESS" ]; then
  echo ""
  send_email "$INFO" "$SERIAL" "$DATE_STAMP" "$EMAIL_ADDRESS"
fi

echo ""
log_success "Collection complete!"
echo ""
log_info "You can also save this output with:"
echo "  ./$(basename "$0") > ~/rpi_info_${SERIAL}_${DATE_STAMP}.txt"
