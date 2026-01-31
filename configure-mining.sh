#!/bin/bash

# ============================================================
# MINING MANAGER v8.7 (Configurable CPU Server)
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

# Detect AUR Helper globally
if command -v yay &> /dev/null; then AUR="yay"; elif command -v paru &> /dev/null; then AUR="paru"; else AUR=""; fi

# --- 1. SYSTEM FUNCTIONS ---

install_deps() {
    echo -e "${BLUE}Installing system components...${NC}"
    if [ -z "$AUR" ]; then echo "AUR helper needed (yay or paru)!"; exit 1; fi

    echo -e "${BLUE}Installing xmrig...${NC}"
    sudo pacman -S --needed xmrig libinput-tools

    echo -e "${BLUE}Installing cuda...${NC}"
    sudo pacman -S --needed cuda libinput-tools



    # Force install Gminer if not present
    if [ ! -f /usr/bin/gminer ] && [ ! -f /opt/gminer/miner ]; then
        echo -e "${CYAN}Installing Gminer...${NC}"
        $AUR -S --needed --noconfirm gminer-bin
    fi

    # Setup Huge Pages (1280 pages * 2MB = ~2.5GB RAM)
    echo -e "${BLUE}Optimizing Huge Pages...${NC}"
    sudo sysctl -w vm.nr_hugepages=1280
    echo "vm.nr_hugepages=1280" | sudo tee /etc/sysctl.d/10-mining.conf > /dev/null

    # --- ВАЖНОЕ ИЗМЕНЕНИЕ ДЛЯ XMRIG ---
    # Даем права на MSR регистры (ускорение хешрейта)
    echo -e "${BLUE}Setting capabilities for XMRig (MSR Fix)...${NC}"
    if command -v xmrig-mo &> /dev/null; then
        sudo setcap cap_sys_rawio,cap_net_admin=eip $(command -v xmrig-mo)
    elif command -v xmrig &> /dev/null; then
        sudo setcap cap_sys_rawio,cap_net_admin=eip $(command -v xmrig)
    fi
}

setup_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$RUNTIME_ENV"

    echo -e "${CYAN}=== SETUP WIZARD ===${NC}"

    # --- CPU SOFTWARE SELECTION ---
    echo -e "${YELLOW}CPU Miner Software:${NC}"
    echo "1. Standard XMRig (Official package)"
    echo "2. XMRig-MO (MoneroOcean Fork - Algo Switching)"
    read -p "Select [1/2]: " mo_choice

    if [[ "$mo_choice" == "2" ]]; then
        echo -e "${BLUE}Checking for XMRig-MO...${NC}"
        if ! command -v xmrig-mo &> /dev/null; then
            echo -e "${CYAN}Installing xmrig-mo from AUR...${NC}"
            $AUR -S --needed --noconfirm xmrig-mo
        fi

        if command -v xmrig-mo &> /dev/null; then
            CHOSEN_CPU_BIN=$(command -v xmrig-mo)
            echo -e "${GREEN}Selected: XMRig-MO ($CHOSEN_CPU_BIN)${NC}"
        else
            echo -e "${RED}Failed to install XMRig-MO. Falling back to Standard.${NC}"
            CHOSEN_CPU_BIN="/usr/bin/xmrig"
        fi
    else
        CHOSEN_CPU_BIN="/usr/bin/xmrig"
        echo -e "${GREEN}Selected: Standard XMRig${NC}"
    fi
    echo ""

    # --- GPU SETUP ---
    echo -e "${YELLOW}GPU Configuration:${NC}"
    read -p "Enable GPU Mining? (y/n): " use_gpu_response
    if [[ "$use_gpu_response" =~ ^[Yy]$ ]]; then
        USE_GPU_VAL="true"
        read -p "GPU Server [Default: gulf.moneroocean.stream:10128]: " gpu_server_in
        gpu_server="${gpu_server_in:-gulf.moneroocean.stream:10128}"
        read -p "GPU Wallet (Ravencoin/Kawpow): " gpu_wal
        read -p "GPU Worker Name (e.g. MyGamingPC-GPU): " gpu_worker
    else
        USE_GPU_VAL="false"
        gpu_server="DISABLED"
        gpu_wal="DISABLED"
        gpu_worker="DISABLED"
        echo -e "${RED}GPU Mining Disabled.${NC}"
    fi
    echo ""

    # --- CPU SETUP ---
    echo -e "${YELLOW}CPU Configuration:${NC}"
    read -p "CPU Server [Default: gulf.moneroocean.stream:10128]: " cpu_server_in
    cpu_server="${cpu_server_in:-gulf.moneroocean.stream:10128}"

    read -p "CPU Wallet (Monero/XMR): " cpu_wal
    read -p "CPU Worker Name (e.g. MyGamingPC-CPU): " cpu_worker
    echo ""

    # --- PROXY SETUP ---
    echo -e "${YELLOW}Proxy Setup (Nekoray/SOCKS5):${NC}"
    echo "Enter IP:PORT (e.g., 127.0.0.1:2081) or leave empty for none"
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
CPU_BIN=$CHOSEN_CPU_BIN
GPU_ALGO=kawpow
GPU_SERVER=$gpu_server
GPU_WALLET=$gpu_wal
GPU_WORKER=${gpu_worker:-DefaultGPU}
CPU_SERVER=$cpu_server
CPU_WALLET=$cpu_wal
CPU_WORKER=${cpu_worker:-DefaultCPU}
PROXY_ADDR=$proxy_input
USE_CPU_MINING=true
USE_GPU_MINING=$USE_GPU_VAL
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

    # XMRIG CONFIG
    cat <<EOF > "$CONFIG_DIR/config.json"
{
    "autosave": true,
    "cpu": true,
    "opencl": false,
    "cuda": false,
    "pools": [
        {
            "url": "gulf.moneroocean.stream:10128",
            "user": "auto",
            "pass": "auto",
            "keepalive": true,
            "tls": true
        }
    ]
}
EOF

    # GPU SERVICE
    cat <<EOF > "$HOME/.config/systemd/user/$GPU_SERVICE"
[Unit]
Description=GPU Miner (Gminer)
After=network.target
[Service]
Type=simple
EnvironmentFile=$ENV_FILE
Environment=all_proxy=http://\${PROXY_ADDR}
Environment=https_proxy=http://\${PROXY_ADDR}
ExecStart=/bin/bash -c "exec \${MINER_BIN} --algo \${GPU_ALGO} --server \${GPU_SERVER} --user \${GPU_WALLET} --worker \${GPU_WORKER} -p \${GPU_WORKER} --proxy \${PROXY_ADDR}"
Restart=always
Nice=15
EOF

    # CPU SERVICE
    cat <<EOF > "$HOME/.config/systemd/user/$CPU_SERVICE"
[Unit]
Description=CPU Miner
After=network.target
[Service]
Type=simple
EnvironmentFile=$ENV_FILE
EnvironmentFile=$RUNTIME_ENV
# --config указывает на файл для сохранения статистики
# -o и -u перезаписывают настройки из config.json (чтобы подтянуть переменные из env)
# --threads управляется скриптом
ExecStart=/bin/bash -c "exec \${CPU_BIN} --config=$CONFIG_DIR/config.json -o \${CPU_SERVER} -u \${CPU_WALLET} -p \${CPU_WORKER} --threads \${CURRENT_CPU_THREADS} --cpu-no-yield --proxy=\${PROXY_ADDR}"
Restart=always
Nice=19
EOF

    # WATCHDOG SCRIPT
    cat <<'EOF' > "$WATCHDOG_SCRIPT"
#!/bin/bash
CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
RUNTIME_ENV="$CONFIG_DIR/runtime.env"

GPU_SRV="miner-gpu.service"
CPU_SRV="miner-cpu.service"

source "$ENV_FILE" 2>/dev/null
IDLE_TIMEOUT=${IDLE_TIMEOUT:-60}

MY_IDLE_TIMER=0
LOOP_DELAY=5

is_video_enc_dec() {
    if command -v nvidia-smi &> /dev/null; then
        counts=$(nvidia-smi --query-gpu=utilization.decoder,utilization.encoder --format=csv,noheader,nounits)

        dec=$(echo "$counts" | cut -d ',' -f 1 | xargs)
        enc=$(echo "$counts" | cut -d ',' -f 2 | xargs)

        # Trigger ONLY if either is above 20%
        if [ "${dec:-0}" -gt 20 ] || [ "${enc:-0}" -gt 20 ]; then
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}

current_mode="unknown"

echo "Watchdog started. Mode: KERNEL HARDWARE MONITOR"

while true; do
    source "$ENV_FILE" 2>/dev/null

    if timeout "$LOOP_DELAY" dd if=/dev/input/mice of=/dev/null bs=1 count=1 2>/dev/null; then
        MY_IDLE_TIMER=0
        reason="Mouse Input"
        sleep 1
    else
        MY_IDLE_TIMER=$((MY_IDLE_TIMER + LOOP_DELAY))
        reason="Idle ($((IDLE_TIMEOUT - MY_IDLE_TIMER))s left)"
    fi

    LAST_INT_COUNT=$CURRENT_INT_COUNT

    if [ "$MY_IDLE_TIMER" -lt "$IDLE_TIMEOUT" ] || is_video_enc_dec; then
        target_mode="active"
        target_threads=$CPU_THREADS_ACTIVE
    else
        target_mode="idle"
        target_threads=$CPU_THREADS_IDLE
    fi

    running_threads=$(grep "CURRENT_CPU_THREADS" "$RUNTIME_ENV" 2>/dev/null | cut -d'=' -f2)

    if [ "$current_mode" != "$target_mode" ] || [ "$running_threads" != "$target_threads" ]; then

        echo "State change: $target_mode (Reason: $reason)"

        if [ "$target_mode" == "active" ]; then
            # --> ACTIVE (Gaming/Work)
            sudo wrmsr -a 0x1a4 0x0 2>/dev/null

            # Stop GPU miner regardless of setting
            systemctl --user stop $GPU_SRV

            echo "CURRENT_CPU_THREADS=$target_threads" > "$RUNTIME_ENV"
            [ "$USE_CPU_MINING" = "true" ] && systemctl --user restart $CPU_SRV

        else
            # --> IDLE (Away)
            sudo wrmsr -a 0x1a4 0xf 2>/dev/null

            echo "CURRENT_CPU_THREADS=$target_threads" > "$RUNTIME_ENV"
            [ "$USE_CPU_MINING" = "true" ] && systemctl --user restart $CPU_SRV

            # Only start GPU miner if enabled in config
            if [ "$USE_GPU_MINING" = "true" ]; then
                systemctl --user start $GPU_SRV
            else
                systemctl --user stop $GPU_SRV
            fi
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

    if [[ "$CPU_BIN" == *xmrig-mo* ]]; then cpu_ver="XMRig-MO"; else cpu_ver="Standard"; fi

    echo -e "CPU Miner:   ${YELLOW}${cpu_ver}${NC} (Threads: $cur_threads)"

    if [ "$USE_GPU_MINING" = "true" ]; then
        echo -e "GPU Config:  ${GREEN}ENABLED${NC} (Worker: $GPU_WORKER)"
    else
        echo -e "GPU Config:  ${RED}DISABLED${NC}"
    fi

    echo -n "Watchdog:    "; systemctl --user is-active --quiet $WATCHDOG_SERVICE && echo -e "${GREEN}RUNNING${NC}" || echo -e "${RED}OFF${NC}"

    echo -n "GPU Miner:   "
    if [ "$USE_GPU_MINING" = "true" ]; then
        systemctl --user is-active --quiet $GPU_SERVICE && echo -e "${GREEN}MINING${NC}" || echo -e "${YELLOW}SLEEPING${NC}"
    else
        echo -e "${RED}DISABLED${NC}"
    fi

    echo -n "CPU Miner:   "; systemctl --user is-active --quiet $CPU_SERVICE && echo -e "${GREEN}MINING${NC}" || echo -e "${YELLOW}SLEEPING${NC}"
    echo "----------------------"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== MINING MANAGER v8.7 (Configurable Server) ===${NC}"
        show_status
        echo "1. Toggle All Services (On/Off)"
        echo "2. Edit Config (Names/Wallets/Threads/Servers)"
        echo "3. RESET & REINSTALL (Regenerate Config)"
        echo "4. Logs: CPU"
        echo "5. Logs: GPU"
        echo "6. Logs: Watchdog"
        echo "7. Exit"
        echo ""
        read -p "> " choice
        case $choice in
            1) systemctl --user is-active --quiet $WATCHDOG_SERVICE && systemctl --user stop $WATCHDOG_SERVICE $GPU_SERVICE $CPU_SERVICE || systemctl --user start $WATCHDOG_SERVICE ;;
            2) nano "$ENV_FILE" ;;
            3) rm -rf "$CONFIG_DIR"; echo "Config deleted. Restarting setup..."; sleep 1; install_deps; setup_config; create_services ;;
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
