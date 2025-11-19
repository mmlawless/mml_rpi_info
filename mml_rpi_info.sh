#!/bin/bash
set -euo pipefail

############################################################
# Raspberry Pi Information Collector
# Collects hardware and system information
# Saves to Dropbox with format: SERIAL_YYYY-MM-DD.txt
# Also builds a CSV summary and (optionally) emails:
#   - Subject: Raspberry Pi Info - HOSTNAME - SERIAL - YYYY-MM-DD HH:MM
#   - CSV attachment: filename is exactly the subject line
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

# State file used by your setup script (for PROFILE info)
STATE_FILE="$HOME/.rpi_setup_state"

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

############################################################
# Setup Script Summary (mirrors your setup script settings)
############################################################

get_setup_summary() {
  echo "=== Setup Script Summary ==="

  local boot_config=""
  if [ -f /boot/firmware/config.txt ]; then
    boot_config="/boot/firmware/config.txt"
  elif [ -f /boot/config.txt ]; then
    boot_config="/boot/config.txt"
  fi

  local current_swap
  current_swap=$(free -m | awk '/^Swap:/ {print $2}')
  local swap_state
  swap_state=$([ "$current_swap" -ge 1024 ] && echo "enabled" || echo "disabled")

  local vnc_status
  vnc_status=$(systemctl is-enabled vncserver-x11-serviced.service 2>/dev/null | grep -q enabled && echo "enabled" || echo "disabled")

  local ufw_status
  ufw_status=$(sudo ufw status 2>/dev/null | grep -qw "active" && echo "enabled" || echo "disabled")

  local spi_state
  spi_state=$(grep -q '^dtparam=spi=on' "$boot_config" 2>/dev/null && echo "enabled" || echo "disabled")

  local i2c_state
  i2c_state=$(grep -q '^dtparam=i2c_arm=on' "$boot_config" 2>/dev/null && echo "enabled" || echo "disabled")

  local camera_state
  camera_state=$(vcgencmd get_camera 2>/dev/null | grep -q 'supported=1 detected=1' && echo "enabled" || echo "disabled")

  local git_name
  git_name="$(git config --global user.name 2>/dev/null || echo "not set")"
  local git_email
  git_email="$(git config --global user.email 2>/dev/null || echo "not set")"

  local py_requests
  py_requests=$(pip3 list 2>/dev/null | grep -qw requests && echo "installed" || echo "not installed")

  local profile_status
  profile_status="$(grep PROFILE= "$STATE_FILE" 2>/dev/null | cut -d= -f2 | grep -oE '[^ ]+' || echo "not set")"

  local hostname_disp
  hostname_disp="$(hostname)"

  local network_manager="unknown"
  if systemctl is-active --quiet dhcpcd 2>/dev/null; then
    network_manager="dhcpcd"
  elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
    network_manager="NetworkManager"
  fi

  echo "Hostname: $hostname_disp"
  echo "Profile: $profile_status"
  echo "Swap: $swap_state (${current_swap} MB)"
  echo "SPI: $spi_state"
  echo "I2C: $i2c_state"
  echo "Camera: $camera_state"
  echo "VNC: $vnc_status"
  echo "Firewall (UFW): $ufw_status"
  echo "Git: $git_name <$git_email>"
  echo "Python requests: $py_requests"
  echo "Network manager: $network_manager"
  if [ -n "$boot_config" ]; then
    echo "Boot config file: $boot_config"
  fi
}

############################################################
# CSV helpers
############################################################

csv_escape() {
  # Escape double quotes for CSV
  local s="$1"
  s="${s//\"/\"\"}"
  echo "$s"
}

csv_line() {
  local key="$1"
  local val="$2"
  echo "\"$(csv_escape "$key")\",\"$(csv_escape "$val")\""
}

build_csv() {
  local serial model revision memory storage hostname os_pretty os_version kernel arch
  local uptime boot_time boot_config network_manager current_swap swap_state
  local spi_state i2c_state camera_state vnc_status ufw_status git_name git_email py_requests profile_status

  serial=$(get_serial)
  model=$(get_model)
  revision=$(get_revision)
  memory=$(get_memory)
  storage=$(get_storage)
  hostname=$(hostname)

  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_pretty="$PRETTY_NAME"
    os_version="$VERSION"
  else
    os_pretty=""
    os_version=""
  fi

  kernel=$(uname -r)
  arch=$(uname -m)
  uptime=$(uptime -p)
  boot_time=$(uptime -s)

  if [ -f /boot/firmware/config.txt ]; then
    boot_config="/boot/firmware/config.txt"
  elif [ -f /boot/config.txt ]; then
    boot_config="/boot/config.txt"
  else
    boot_config=""
  fi

  if systemctl is-active --quiet dhcpcd 2>/dev/null; then
    network_manager="dhcpcd"
  elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
    network_manager="NetworkManager"
  else
    network_manager="unknown"
  fi

  current_swap=$(free -m | awk '/^Swap:/ {print $2}')
  swap_state=$([ "$current_swap" -ge 1024 ] && echo "enabled" || echo "disabled")
  spi_state=$(grep -q '^dtparam=spi=on' "$boot_config" 2>/dev/null && echo "enabled" || echo "disabled")
  i2c_state=$(grep -q '^dtparam=i2c_arm=on' "$boot_config" 2>/dev/null && echo "enabled" || echo "disabled")
  camera_state=$(vcgencmd get_camera 2>/dev/null | grep -q 'supported=1 detected=1' && echo "enabled" || echo "disabled")
  vnc_status=$(systemctl is-enabled vncserver-x11-serviced.service 2>/dev/null | grep -q enabled && echo "enabled" || echo "disabled")
  ufw_status=$(sudo ufw status 2>/dev/null | grep -qw "active" && echo "enabled" || echo "disabled")
  git_name=$(git config --global user.name 2>/dev/null || echo "not set")
  git_email=$(git config --global user.email 2>/dev/null || echo "not set")
  py_requests=$(pip3 list 2>/dev/null | grep -qw requests && echo "installed" || echo "not installed")
  profile_status=$(grep PROFILE= "$STATE_FILE" 2>/dev/null | cut -d= -f2 | grep -oE '[^ ]+' || echo "not set")

  {
    echo "key,value"
    csv_line "serial" "$serial"
    csv_line "model" "$model"
    csv_line "revision" "$revision"
    csv_line "memory" "$memory"
    csv_line "storage" "$storage"
    csv_line "hostname" "$hostname"
    csv_line "os_pretty_name" "$os_pretty"
    csv_line "os_version" "$os_version"
    csv_line "kernel" "$kernel"
    csv_line "architecture" "$arch"
    csv_line "uptime_pretty" "$uptime"
    csv_line "boot_time" "$boot_time"
    csv_line "boot_config_file" "$boot_config"
    csv_line "network_manager" "$network_manager"
    csv_line "swap_state" "$swap_state"
    csv_line "swap_mb" "$current_swap"
    csv_line "spi" "$spi_state"
    csv_line "i2c" "$i2c_state"
    csv_line "camera" "$camera_state"
    csv_line "vnc" "$vnc_status"
    csv_line "ufw" "$ufw_status"
    csv_line "git_name" "$git_name"
    csv_line "git_email" "$git_email"
    csv_line "python_requests" "$py_requests"
    csv_line "profile" "$profile_status"
  }
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

  # Add summary of settings from your setup script
  output+="$(get_setup_summary)\n\n"
  
  output+="============================================\n"
  output+="END OF REPORT\n"
  output+="============================================\n"
  
  echo -e "$output"
}

############################################################
# Email the file (with CSV attachment)
############################################################

send_email() {
  local content="$1"
  local serial="$2"
  local date_stamp="$3"
  local email_to="$4"
  local csv_content="$5"

  local hostname_full
  hostname_full="$(hostname)"
  local time_stamp
  time_stamp=$(date '+%H:%M')

  # Subject: include hostname, serial, date and time
  local subject="Raspberry Pi Info - ${hostname_full} - ${serial} - ${date_stamp} ${time_stamp}"

  # CSV filename must be exactly the subject line (no extra extension)
  local csv_filename="$subject"

  # Temporary files
  local tmp_body tmp_csv
  tmp_body=$(mktemp)
  tmp_csv=$(mktemp)

  echo -e "$content" > "$tmp_body"
  echo -e "$csv_content" > "$tmp_csv"

  log_info "Sending email to: $email_to"
  log_info "Email subject: $subject"
  log_info "CSV attachment filename: $csv_filename"

  local boundary="=====RPIINFO_BOUNDARY_$$====="

  # Helper to build MIME message with attachment
  build_mime_message() {
    echo "To: $email_to"
    echo "From: pi@$hostname_full"
    echo "Subject: $subject"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
    echo
    echo "This is a multi-part message in MIME format."
    echo
    echo "--$boundary"
    echo "Content-Type: text/plain; charset=\"UTF-8\""
    echo "Content-Transfer-Encoding: 8bit"
    echo
    cat "$tmp_body"
    echo
    echo "--$boundary"
    echo "Content-Type: text/csv; name=\"$csv_filename\""
    echo "Content-Transfer-Encoding: base64"
    echo "Content-Disposition: attachment; filename=\"$csv_filename\""
    echo
    base64 "$tmp_csv"
    echo
    echo "--$boundary--"
  }

  # Method 1: msmtp (recommended)
  if command -v msmtp &> /dev/null; then
    if build_mime_message | msmtp "$email_to"; then
      rm -f "$tmp_body" "$tmp_csv"
      log_success "Email sent successfully via msmtp (with CSV attachment)"
      return 0
    else
      log_warning "msmtp send failed, trying other methods..."
    fi
  fi
  
  # Method 2: sendmail
  if command -v sendmail &> /dev/null; then
    if build_mime_message | sendmail -t; then
      rm -f "$tmp_body" "$tmp_csv"
      log_success "Email sent successfully via sendmail (with CSV attachment)"
      return 0
    else
      log_warning "sendmail send failed, trying mail/mailx..."
    fi
  fi
  
  # Method 3: mail/mailx (fallback, plain body only, no attachment)
  if command -v mail &> /dev/null; then
    if mail -s "$subject" "$email_to" < "$tmp_body"; then
      rm -f "$tmp_body" "$tmp_csv"
      log_success "Email sent successfully via mail (WITHOUT attachment fallback)"
      log_warning "Install msmtp or sendmail for CSV attachment support."
      return 0
    fi
  fi
  
  rm -f "$tmp_body" "$tmp_csv"
  log_error "No suitable email client found or all methods failed."
  log_info "To get attachments, install and configure msmtp (recommended) or sendmail."
  return 1
}

############################################################
# Save to Dropbox (text report only)
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
      echo "  -e, --email EMAIL    Send results to email address (with CSV attachment)"
      echo "  --no-dropbox         Skip saving to Dropbox"
      echo "  -h, --help           Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                              # Save to Dropbox only"
      echo "  $0 --email user@example.com     # Email (with CSV) and save to Dropbox"
      echo "  $0 -e user@example.com --no-dropbox  # Email only (with CSV)"
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
echo "MML Raspberry Pi Information Collector 1a"
echo "=========================================="
echo ""

log_info "Collecting system information..."

# Get serial number and date
SERIAL=$(get_serial)
DATE_STAMP=$(date '+%Y-%m-%d')

log_info "Serial Number: $SERIAL"
log_info "Date: $DATE_STAMP"
echo ""

# Collect all information (text report)
INFO=$(collect_all_info)

# Build CSV summary
CSV_CONTENT=$(build_csv)

# Display to screen
echo "$INFO"
echo ""

# Save to Dropbox (text file)
if [ "$SKIP_DROPBOX" = false ]; then
  log_info "Saving to Dropbox..."
  save_to_dropbox "$INFO" "$SERIAL" "$DATE_STAMP"
fi

# Send email if requested (text + CSV attachment)
if [ -n "$EMAIL_ADDRESS" ]; then
  echo ""
  send_email "$INFO" "$SERIAL" "$DATE_STAMP" "$EMAIL_ADDRESS" "$CSV_CONTENT"
fi

echo ""
log_success "Collection complete!"
echo ""
log_info "You can also save this output with:"
echo "  ./$(basename "$0") > ~/rpi_info_${SERIAL}_${DATE_STAMP}.txt"
