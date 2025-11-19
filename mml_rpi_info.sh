#!/bin/bash
set -euo pipefail

############################################################
# Raspberry Pi Information Collector
# Collects hardware and system information
# Saves to Dropbox
# Sends email with text body + CSV attachment
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

STATE_FILE="$HOME/.rpi_setup_state"

############################################################
# Check if running on Raspberry Pi
############################################################
if [ ! -f /proc/cpuinfo ]; then
  log_error "Cannot read /proc/cpuinfo - are you on a Raspberry Pi?"
  exit 1
fi

############################################################
# Helper / detection functions
############################################################

csv_escape() {
  # Escape a value for CSV (wrap in quotes if needed, escape quotes)
  local s="$1"
  s=${s//\"/\"\"}
  if [[ "$s" == *","* || "$s" == *$'\n'* || "$s" == *$'\r'* || "$s" == *"\""* ]]; then
    printf '"%s"' "$s"
  else
    printf '%s' "$s"
  fi
}

get_boot_config_file() {
  if [ -f /boot/firmware/config.txt ]; then
    echo "/boot/firmware/config.txt"
  elif [ -f /boot/config.txt ]; then
    echo "/boot/config.txt"
  else
    echo ""
  fi
}

detect_network_manager() {
  if systemctl is-active --quiet dhcpcd 2>/dev/null; then
    echo "dhcpcd"
  elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "NetworkManager"
  else
    echo "unknown"
  fi
}

get_spi_state() {
  local cfg
  cfg="$(get_boot_config_file)"
  if [ -n "$cfg" ] && grep -q '^dtparam=spi=on' "$cfg" 2>/dev/null; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

get_i2c_state() {
  local cfg
  cfg="$(get_boot_config_file)"
  if [ -n "$cfg" ] && grep -q '^dtparam=i2c_arm=on' "$cfg" 2>/dev/null; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

get_camera_state() {
  if command -v vcgencmd >/dev/null 2>&1; then
    if vcgencmd get_camera 2>/dev/null | grep -q 'supported=1 detected=1'; then
      echo "enabled"
    else
      echo "disabled"
    fi
  else
    echo "unknown"
  fi
}

get_swap_total_mb() {
  free -m | awk '/^Swap:/ {print $2}'
}

get_swap_state() {
  local total
  total=$(get_swap_total_mb)
  if [ "$total" -ge 1024 ]; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

get_root_fs_stats() {
  # Returns: total,used,available,use%
  df -h / | awk 'NR==2 {print $2","$3","$4","$5}'
}

get_usb_controllers_count() {
  if [ -d /sys/bus/usb/devices ]; then
    find /sys/bus/usb/devices -maxdepth 1 -name "usb*" -type d | wc -l
  else
    echo "unknown"
  fi
}

get_wifi_interface() {
  iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}'
}

get_wifi_ssid() {
  local iface
  iface="$(get_wifi_interface)"
  if [ -n "$iface" ] && command -v iwgetid >/dev/null 2>&1; then
    iwgetid -r 2>/dev/null || echo ""
  else
    echo ""
  fi
}

get_vnc_state() {
  if systemctl is-enabled vncserver-x11-serviced.service 2>/dev/null | grep -q enabled; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

get_ufw_status() {
  if command -v ufw >/dev/null 2>&1; then
    if sudo -n ufw status 2>/dev/null | grep -qw "active"; then
      echo "enabled"
    else
      echo "disabled"
    fi
  else
    echo "not installed"
  fi
}

get_setup_profile() {
  grep PROFILE= "$STATE_FILE" 2>/dev/null | cut -d= -f2 | grep -oE '[^ ]+' || echo "not set"
}

get_requests_state() {
  if pip3 list 2>/dev/null | grep -qw requests; then
    echo "installed"
  else
    echo "not installed"
  fi
}

get_primary_iface() {
  ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}'
}

get_primary_mac_address() {
  local iface
  iface="$(get_primary_iface)"
  if [ -n "$iface" ] && [ -f "/sys/class/net/$iface/address" ]; then
    cat "/sys/class/net/$iface/address"
  else
    echo "N/A"
  fi
}

############################################################
# Collect Information Functions
############################################################

get_serial() {
  local serial=""
  if [ -f /proc/cpuinfo ]; then
    serial=$(grep -i "^Serial" /proc/cpuinfo | awk '{print $3}' | sed 's/^0*//')
  fi
  if [ -z "$serial" ] && [ -f /proc/device-tree/serial-number ]; then
    serial=$(tr -d '\0' < /proc/device-tree/serial-number)
  fi
  if [ -z "$serial" ]; then
    serial="unknown_$(hostname)"
  fi
  echo "$serial"
}

get_model() {
  local model=""
  if [ -f /proc/device-tree/model ]; then
    model=$(tr -d '\0' < /proc/device-tree/model)
  fi
  if [ -z "$model" ] && [ -f /proc/cpuinfo ]; then
    model=$(grep -i "^Model" /proc/cpuinfo | cut -d: -f2 | xargs)
  fi
  [ -z "$model" ] && model="Unknown Raspberry Pi"
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
  free -h | awk '/^Mem:/ {print $2}'
}

get_storage() {
  df -h / | awk 'NR==2 {print $2 " (Used: " $3 ", Available: " $4 ", " $5 " used)"}'
}

get_usb_info() {
  if command -v lsusb &> /dev/null; then
    local usb_count
    usb_count=$(lsusb | wc -l)
    echo "USB Devices Found: $usb_count"
    lsusb
  else
    echo "lsusb not available - install usbutils"
  fi
}

get_network_interfaces() {
  echo "=== Network Interfaces ==="
  ip -br addr show | grep -v "^lo" || echo "No interfaces found"
  echo ""
  
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
  local wifi_iface
  wifi_iface="$(get_wifi_interface)"
  if [ -n "$wifi_iface" ]; then
    echo "WiFi Interface: $wifi_iface"
    if command -v iwgetid &> /dev/null; then
      local ssid
      ssid=$(iwgetid -r 2>/dev/null || echo "Not connected")
      echo "Connected SSID: $ssid"
    fi
    local wifi_power
    wifi_power=$(iw dev "$wifi_iface" info 2>/dev/null | grep "txpower" | awk '{print $2, $3}')
    [ -n "$wifi_power" ] && echo "TX Power: $wifi_power"
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
  local config_file
  config_file="$(get_boot_config_file)"
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
    echo "Model: $(grep "^model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs || echo "N/A")"
    echo "Hardware: $(grep "^Hardware" /proc/cpuinfo | cut -d: -f2 | xargs || echo "N/A")"
    echo "Cores: $(nproc)"
    echo "BogoMIPS: $(grep "^BogoMIPS" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs || echo "N/A")"
  fi
  if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
    local freq
    freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
    echo "Current Frequency: $((freq / 1000)) MHz"
  fi
  echo "Temperature: $(get_temperature)"
}

get_gpio_info() {
  echo "=== GPIO Information ==="
  if command -v pinout &> /dev/null; then
    echo "GPIO layout available via 'pinout' command"
    echo "Run 'pinout' on the Pi to see the full layout"
  fi
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
# CSV generation
############################################################

generate_csv() {
  local serial hostname mac model revision mem
  serial=$(get_serial)
  hostname=$(hostname)
  mac=$(get_primary_mac_address)
  model=$(get_model)
  revision=$(get_revision)
  mem=$(get_memory)

  local root_stats
  root_stats=$(get_root_fs_stats)
  IFS=',' read -r ROOT_TOTAL ROOT_USED ROOT_AVAIL ROOT_USE_PCT <<< "$root_stats"

  local swap_total_mb swap_state
  swap_total_mb=$(get_swap_total_mb)
  swap_state=$(get_swap_state)

  local os_dist os_ver os_id os_codename
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    os_dist="$PRETTY_NAME"
    os_ver="$VERSION"
    os_id="$ID"
    os_codename="$VERSION_CODENAME"
  fi

  local kernel arch uptime_str boot_time
  kernel=$(uname -r)
  arch=$(uname -m)
  uptime_str=$(uptime -p)
  boot_time=$(uptime -s)

  local usb_ctrl wifi_iface wifi_ssid boot_cfg spi_state i2c_state cam_state
  usb_ctrl=$(get_usb_controllers_count)
  wifi_iface=$(get_wifi_interface)
  wifi_ssid=$(get_wifi_ssid)
  boot_cfg=$(get_boot_config_file)
  spi_state=$(get_spi_state)
  i2c_state=$(get_i2c_state)
  cam_state=$(get_camera_state)

  local vnc_state ufw_state git_user git_email req_state profile net_mgr
  vnc_state=$(get_vnc_state)
  ufw_state=$(get_ufw_status)
  git_user=$(git config --global user.name 2>/dev/null || echo "not set")
  git_email=$(git config --global user.email 2>/dev/null || echo "not set")
  req_state=$(get_requests_state)
  profile=$(get_setup_profile)
  net_mgr=$(detect_network_manager)

  {
    echo "Key,Value"
    echo "Serial Number,$(csv_escape "$serial")"
    echo "Hostname,$(csv_escape "$hostname")"
    echo "MAC Address,$(csv_escape "$mac")"
    echo "Model,$(csv_escape "$model")"
    echo "Revision,$(csv_escape "$revision")"
    echo "Memory,$(csv_escape "$mem")"
    echo "Root FS Total,$(csv_escape "$ROOT_TOTAL")"
    echo "Root FS Used,$(csv_escape "$ROOT_USED")"
    echo "Root FS Available,$(csv_escape "$ROOT_AVAIL")"
    echo "Root FS Use %,$(csv_escape "$ROOT_USE_PCT")"
    echo "Swap Total (MB),$(csv_escape "$swap_total_mb")"
    echo "Swap State,$(csv_escape "$swap_state")"
    echo "OS Distribution,$(csv_escape "$os_dist")"
    echo "OS Version,$(csv_escape "$os_ver")"
    echo "OS ID,$(csv_escape "$os_id")"
    echo "OS Codename,$(csv_escape "$os_codename")"
    echo "Kernel,$(csv_escape "$kernel")"
    echo "Architecture,$(csv_escape "$arch")"
    echo "Uptime,$(csv_escape "$uptime_str")"
    echo "Boot Time,$(csv_escape "$boot_time")"
    echo "USB Controllers,$(csv_escape "$usb_ctrl")"
    echo "WiFi Interface,$(csv_escape "$wifi_iface")"
    echo "WiFi SSID,$(csv_escape "$wifi_ssid")"
    echo "Boot Config File,$(csv_escape "$boot_cfg")"
    echo "SPI,$(csv_escape "$spi_state")"
    echo "I2C,$(csv_escape "$i2c_state")"
    echo "Camera,$(csv_escape "$cam_state")"
    echo "Swap,$(csv_escape "$swap_total_mb MB")"
    echo "VNC,$(csv_escape "$vnc_state")"
    echo "Firewall (UFW),$(csv_escape "$ufw_state")"
    echo "Git User,$(csv_escape "$git_user")"
    echo "Git Email,$(csv_escape "$git_email")"
    echo "Python 'requests' package,$(csv_escape "$req_state")"
    echo "Setup Profile,$(csv_escape "$profile")"
    echo "Network Manager,$(csv_escape "$net_mgr")"
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
  output+="Hostname: $(hostname)\n"
  output+="Model: $(get_model)\n"
  output+="Revision: $(get_revision)\n"
  output+="Memory: $(get_memory)\n"
  output+="Storage: $(get_storage)\n"
  output+="MAC Address: $(get_primary_mac_address)\n"
  output+="\n"
  
  output+="$(get_cpu_info)\n\n"
  output+="$(get_os_info)\n\n"
  output+="$(get_uptime_info)\n\n"
  
  output+="=== USB Information ===\n"
  output+="$(get_usb_controllers_count) USB controllers detected\n"
  output+="$(get_usb_info)\n\n"
  
  output+="$(get_network_interfaces)\n\n"
  output+="$(get_wifi_info)\n\n"
  output+="$(get_bluetooth_info)\n\n"
  output+="$(get_gpio_info)\n\n"
  output+="$(get_boot_info)\n\n"
  output+="$(get_installed_packages)\n\n"

  # Setup-related configuration
  output+="=== Setup / Feature Configuration ===\n"
  output+="Root FS Total: $(echo "$(get_root_fs_stats)" | cut -d',' -f1)\n"
  output+="Root FS Used: $(echo "$(get_root_fs_stats)" | cut -d',' -f2)\n"
  output+="Root FS Available: $(echo "$(get_root_fs_stats)" | cut -d',' -f3)\n"
  output+="Root FS Use %: $(echo "$(get_root_fs_stats)" | cut -d',' -f4)\n"
  output+="Swap Total (MB): $(get_swap_total_mb)\n"
  output+="Swap State: $(get_swap_state)\n"
  output+="SPI: $(get_spi_state)\n"
  output+="I2C: $(get_i2c_state)\n"
  output+="Camera: $(get_camera_state)\n"
  output+="VNC: $(get_vnc_state)\n"
  output+="Firewall (UFW): $(get_ufw_status)\n"
  output+="Git User: $(git config --global user.name 2>/dev/null || echo "not set")\n"
  output+="Git Email: $(git config --global user.email 2>/dev/null || echo "not set")\n"
  output+="Python 'requests' package: $(get_requests_state)\n"
  output+="Setup Profile: $(get_setup_profile)\n"
  output+="Network Manager: $(detect_network_manager)\n"
  output+="\n"
  
  output+="============================================\n"
  output+="END OF REPORT\n"
  output+="============================================\n"
  
  echo -e "$output"
}

############################################################
# Email with attachment
############################################################

send_email_with_attachment() {
  local text_file="$1"
  local csv_file="$2"
  local subject="$3"
  local email_to="$4"

  local boundary="====RPIINFO_$(date +%s)_$$===="
  local from_addr="pi@$(hostname)"
  local csv_filename="${subject}.csv"

  log_info "Sending email to: $email_to"
  
  if command -v msmtp &> /dev/null; then
    (
      echo "To: $email_to"
      echo "From: $from_addr"
      echo "Subject: $subject"
      echo "MIME-Version: 1.0"
      echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
      echo
      echo "--$boundary"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 7bit"
      echo
      cat "$text_file"
      echo
      echo "--$boundary"
      echo "Content-Type: text/csv; name=\"$csv_filename\""
      echo "Content-Transfer-Encoding: base64"
      echo "Content-Disposition: attachment; filename=\"$csv_filename\""
      echo
      base64 "$csv_file"
      echo
      echo "--$boundary--"
    ) | msmtp "$email_to"
    if [ $? -eq 0 ]; then
      log_success "Email sent successfully via msmtp"
      return 0
    fi
  fi

  if command -v sendmail &> /dev/null; then
    (
      echo "To: $email_to"
      echo "From: $from_addr"
      echo "Subject: $subject"
      echo "MIME-Version: 1.0"
      echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
      echo
      echo "--$boundary"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 7bit"
      echo
      cat "$text_file"
      echo
      echo "--$boundary"
      echo "Content-Type: text/csv; name=\"$csv_filename\""
      echo "Content-Transfer-Encoding: base64"
      echo "Content-Disposition: attachment; filename=\"$csv_filename\""
      echo
      base64 "$csv_file"
      echo
      echo "--$boundary--"
    ) | sendmail -t
    if [ $? -eq 0 ]; then
      log_success "Email sent successfully via sendmail"
      return 0
    fi
  fi

  if command -v mail &> /dev/null; then
    log_warning "mail found but attachment support is not configured; sending text body only."
    mail -s "$subject" "$email_to" < "$text_file"
    if [ $? -eq 0 ]; then
      log_success "Email sent successfully via mail (no attachment)"
      return 0
    fi
  fi

  log_error "No suitable email client found (msmtp/sendmail/mail)."
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
  
  local save_dir="$dropbox_dir/RaspberryPi_Info"
  mkdir -p "$save_dir"
  
  local filepath="$save_dir/$filename"
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

SERIAL=$(get_serial)
DATE_STAMP=$(date '+%Y-%m-%d')
TIME_STAMP=$(date '+%H:%M')

log_info "Serial Number: $SERIAL"
log_info "Date: $DATE_STAMP"
log_info "Time: $TIME_STAMP"
echo ""

INFO=$(collect_all_info)
CSV_CONTENT=$(generate_csv)

# Show on screen
echo "$INFO"
echo ""

# Save text report to Dropbox
if [ "$SKIP_DROPBOX" = false ]; then
  log_info "Saving to Dropbox..."
  save_to_dropbox "$INFO" "$SERIAL" "$DATE_STAMP"
fi

# Prepare temp files for email
TEXT_TMP=$(mktemp)
CSV_TMP=$(mktemp)
echo -e "$INFO" > "$TEXT_TMP"
echo -e "$CSV_CONTENT" > "$CSV_TMP"

if [ -n "$EMAIL_ADDRESS" ]; then
  SUBJECT="Raspberry Pi Info - $(hostname) - $SERIAL - ${DATE_STAMP} ${TIME_STAMP}"
  echo ""
  send_email_with_attachment "$TEXT_TMP" "$CSV_TMP" "$SUBJECT" "$EMAIL_ADDRESS"
fi

rm -f "$TEXT_TMP" "$CSV_TMP"

echo ""
log_success "Collection complete!"
echo ""
log_info "You can also save this output with:"
echo "  ./$(basename "$0") > ~/rpi_info_${SERIAL}_${DATE_STAMP}.txt"
