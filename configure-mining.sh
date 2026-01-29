#!/bin/bash

# ============================================================
# MINING MANAGER v8.3 (GMER ONLY + CUSTOM NAMES)
# ============================================================

CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
RUNTIME_ENV="$CONFIG_DIR/runtime.env"
WATCHDOG_SCRIPT="$CONFIG_DIR/watchdog.sh"
WATCHDOG_SERVICE="mining-watchdog.service"
GPU_SERVICE="miner-gpu.service"
CPU_SERVICE="miner-cpu.service"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir "$HOME/.config/systemd/user" -p

# --- 1. SYSTEM FUNCTIONS ---

install_deps() {
    echo -e "${BLUE}Installing system components...${NC}"
    if command -v yay &> /dev/null; then AUR="yay"; elif command -v paru &> /dev/null; then AUR="paru"; else echo "AUR helper needed (yay or paru)!"; exit 1; fi

    # Update system and install common deps
    sudo pacman -S --needed cuda gamemode xmrig git base-devel xprintidle

    # Force install Gminer if not present
    if [ ! -f /usr/bin/gminer ] && [ ! -f /opt/gminer/miner ]; then
        echo -e "${CYAN}Installing Gminer...${NC}"
        $AUR -S --needed --noconfirm gminer-bin
    fi

    # Setup Huge Pages
    echo -e "${BLUE}Optimizing Huge Pages...${NC}"
    sudo sysctl -w vm.nr_hugepages=1280
    echo "vm.nr_hugepages=1280" | sudo tee /etc/sysctl.d/10-mining.conf > /dev/null
}

setup_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$RUNTIME_ENV"

    echo -e "${CYAN}=== SETUP WIZARD ===${NC}"

    # Wallet Setup
    read -p "GPU Wallet (Ravencoin/Kawpow): " gpu_wal
    read -p "GPU Worker Name (e.g. MyGamingPC-GPU): " gpu_worker

    read -p "CPU Wallet (Monero/XMR): " cpu_wal
    read -p "CPU Worker Name (e.g. MyGamingPC-CPU): " cpu_worker

    # Proxy Setup
    echo -e "${YELLOW}Proxy Setup (Nekoray/SOCKS5):${NC}"
    echo "Enter IP:PORT (e.g., 127.0.0.1:2081)"
    read -p "> " proxy_input

    # Detect Gminer Path
    if [ -f /usr/bin/gminer ]; then
        M_BIN="/usr/bin/gminer"
    else
        M_BIN="/opt/gminer/miner"
    fi

    # Write Config
    cat <<EOF > "$ENV_FILE"
MINER_BIN=$M_BIN
GPU_ALGO=kawpow
GPU_SERVER=gulf.moneroocean.stream:10128
GPU_WALLET=$gpu_wal
GPU_WORKER=${gpu_worker:-DefaultGPU}
CPU_WALLET=$cpu_wal
CPU_WORKER=${cpu_worker:-DefaultCPU}
PROXY_ADDR=$proxy_input
USE_CPU_MINING=true
# Threads Configuration:
CPU_THREADS_IDLE=26
CPU_THREADS_ACTIVE=6
IDLE_TIMEOUT=60
EOF
    echo "CURRENT_CPU_THREADS=6" > "$RUNTIME_ENV"
    echo -e "${GREEN}Configuration saved.${NC}"
}

create_services() {
    echo -e "${BLUE}Updating services and scripts...${NC}"

    # GPU SERVICE (Gminer Only)
    # Uses --worker to set the rig name
    cat <<EOF > "$HOME/.config/systemd/user/$GPU_SERVICE"
[Unit]
Description=GPU Miner (Gminer)
After=network.target
[Service]
Type=simple
EnvironmentFile=$ENV_FILE
Environment=all_proxy=http://\${PROXY_ADDR}
Environment=https_proxy=http://\${PROXY_ADDR}
ExecStart=\${MINER_BIN} --algo \${GPU_ALGO} --server \${GPU_SERVER} --user \${GPU_WALLET} --worker \${GPU_WORKER}
Restart=always
Nice=15
EOF

    # CPU SERVICE (XMRig)
    # Uses --rig-id and -p (pass) to ensure name shows on pool
    cat <<EOF > "$HOME/.config/systemd/user/$CPU_SERVICE"
[Unit]
Description=CPU Miner (XMRig)
After=network.target
[Service]
Type=simple
EnvironmentFile=$ENV_FILE
EnvironmentFile=$RUNTIME_ENV
ExecStart=/usr/bin/xmrig -o gulf.moneroocean.stream:20128 -u \${CPU_WALLET} -p \${CPU_WORKER} --rig-id \${CPU_WORKER} --proxy=\${PROXY_ADDR} --tls -k --coin monero -t \${CURRENT_CPU_THREADS} --cpu-no-yield
Restart=always
Nice=19
EOF

    # WATCHDOG SCRIPT (UNCHANGED LOGIC)
    cat <<'EOF' > "$WATCHDOG_SCRIPT"
#!/bin/bash
CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
RUNTIME_ENV="$CONFIG_DIR/runtime.env"

GPU_SRV="miner-gpu.service"
CPU_SRV="miner-cpu.service"

MY_IDLE_TIMER=0
LAST_INT_COUNT=0
LOOP_DELAY=5

get_hardware_interrupts() {
    grep -E "xhci|i8042" /proc/interrupts | awk '{ for(i=2;i<=NF;i++) sum+=$i } END { print sum }'
}

is_video_playing() {
    if command -v nvidia-smi &> /dev/null; then
        counts=$(nvidia-smi --query-gpu=utilization.decoder,utilization.encoder --format=csv,noheader,nounits)
        dec=$(echo $counts | cut -d ',' -f 1 | xargs)
        enc=$(echo $counts | cut -d ',' -f 2 | xargs)
        if [ "$dec" -gt 0 ] || [ "$enc" -gt 0 ]; then return 0; else return 1; fi
    else
        return 1
    fi
}

LAST_INT_COUNT=$(get_hardware_interrupts)
current_mode="unknown"

echo "Watchdog started. Mode: KERNEL HARDWARE MONITOR"

while true; do
    source "$ENV_FILE" 2>/dev/null

    CURRENT_INT_COUNT=$(get_hardware_interrupts)
    DIFF=$((CURRENT_INT_COUNT - LAST_INT_COUNT))

    if [ "$DIFF" -gt 100 ]; then
        MY_IDLE_TIMER=0
    else
        MY_IDLE_TIMER=$((MY_IDLE_TIMER + LOOP_DELAY))
    fi

    LAST_INT_COUNT=$CURRENT_INT_COUNT

    if [ "$MY_IDLE_TIMER" -lt "$IDLE_TIMEOUT" ] || is_video_playing; then
        target_mode="active"
        target_threads=$CPU_THREADS_ACTIVE
    else
        target_mode="idle"
        target_threads=$CPU_THREADS_IDLE
    fi

    running_threads=$(grep "CURRENT_CPU_THREADS" "$RUNTIME_ENV" 2>/dev/null | cut -d'=' -f2)

    if [ "$current_mode" != "$target_mode" ] || [ "$running_threads" != "$target_threads" ]; then

        echo "State change: $target_mode (Idle Timer: ${MY_IDLE_TIMER}s | Interrupts: +$DIFF)"

        if [ "$target_mode" == "active" ]; then
            # --> ACTIVE
            sudo wrmsr -a 0x1a4 0x0 2>/dev/null
            systemctl --user stop $GPU_SRV

            echo "CURRENT_CPU_THREADS=$target_threads" > "$RUNTIME_ENV"
            [ "$USE_CPU_MINING" = "true" ] && systemctl --user restart $CPU_SRV

        else
            # --> IDLE
            sudo wrmsr -a 0x1a4 0xf 2>/dev/null

            echo "CURRENT_CPU_THREADS=$target_threads" > "$RUNTIME_ENV"
            [ "$USE_CPU_MINING" = "true" ] && systemctl --user restart $CPU_SRV

            systemctl --user start $GPU_SRV
        fi
        current_mode="$target_mode"
    fi

    sleep $LOOP_DELAY
done
EOF
    chmod +x "$WATCHDOG_SCRIPT"

    # WATCHDOG SERVICE
    cat <<EOF > "$HOME/.config/systemd/user/$WATCHDOG_SERVICE"
[Unit]
Description=Mining Watchdog
After=network.target
[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT
Restart=always
[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now $WATCHDOG_SERVICE
}

# --- 2. MENU INTERFACE ---

show_status() {
    echo -e "\n${CYAN}--- SYSTEM STATUS ---${NC}"
    source "$ENV_FILE" 2>/dev/null
    cur_threads=$(grep "CURRENT_CPU_THREADS" "$RUNTIME_ENV" 2>/dev/null | cut -d'=' -f2)

    echo -e "CPU Threads: ${YELLOW}${cur_threads:-LOADING}${NC} (Active=$CPU_THREADS_ACTIVE / Idle=$CPU_THREADS_IDLE)"
    echo -e "Workers: GPU=[${CYAN}$GPU_WORKER${NC}] CPU=[${CYAN}$CPU_WORKER${NC}]"

    echo -n "Watchdog: "; systemctl --user is-active --quiet $WATCHDOG_SERVICE && echo -e "${GREEN}RUNNING${NC}" || echo -e "${RED}OFF${NC}"
    echo -n "GPU: "; systemctl --user is-active --quiet $GPU_SERVICE && echo -e "${GREEN}MINING${NC}" || echo -e "${YELLOW}SLEEPING${NC}"
    echo -n "CPU: "; systemctl --user is-active --quiet $CPU_SERVICE && echo -e "${GREEN}MINING${NC}" || echo -e "${YELLOW}SLEEPING${NC}"
    echo "----------------------"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== MINING MANAGER v8.3 (GMiner Only) ===${NC}"
        show_status
        echo "1. Toggle All Services (On/Off)"
        echo "2. Edit Config (Names/Wallets)"
        echo "3. RESET & REINSTALL (Use this to apply name changes)"
        echo "4. Logs: CPU"
        echo "5. Logs: GPU"
        echo "6. Logs: Watchdog"
        echo "7. Exit"
        echo ""
        read -p "> " choice
        case $choice in
            1) systemctl --user is-active --quiet $WATCHDOG_SERVICE && systemctl --user stop $WATCHDOG_SERVICE $GPU_SERVICE $CPU_SERVICE || systemctl --user start $WATCHDOG_SERVICE ;;
            2) nano "$ENV_FILE" ;;
            3) rm -rf "$CONFIG_DIR"; echo "Config deleted. Please restart script to reconfigure."; exit 0 ;;
            4) journalctl --user -f -u $CPU_SERVICE ;;
            5) journalctl --user -f -u $GPU_SERVICE ;;
            6) journalctl --user -f -u $WATCHDOG_SERVICE ;;
            7) exit 0 ;;
        esac
    done
}

if [ ! -f "$ENV_FILE" ]; then
    install_deps
    setup_config
    create_services
fi
main_menu
