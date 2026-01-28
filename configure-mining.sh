#!/bin/bash

# ============================================================
# MINING MANAGER v8.2 (AUTO-RELOAD EDITION)
# ============================================================

CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
RUNTIME_ENV="$CONFIG_DIR/runtime.env"
WATCHDOG_SCRIPT="$CONFIG_DIR/watchdog.sh"
WATCHDOG_SERVICE="mining-watchdog.service"
GPU_SERVICE="miner-gpu.service"
CPU_SERVICE="miner-cpu.service"

# Цвета
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 1. СИСТЕМНЫЕ ФУНКЦИИ ---

install_deps() {
    echo -e "${BLUE}Установка системных компонентов...${NC}"
    if command -v yay &> /dev/null; then AUR="yay"; elif command -v paru &> /dev/null; then AUR="paru"; else echo "Нужен AUR хелпер!"; exit 1; fi
    sudo pacman -S --needed --noconfirm cuda gamemode xmrig git base-devel xprintidle

    if [ ! -f /usr/bin/gminer ] && [ ! -f /usr/bin/rigel ]; then
        echo -e "${CYAN}Выберите майнер для GPU:${NC}"
        echo "1) Gminer (Рекомендуется для RVN)"
        echo "2) Rigel"
        read -p "> " mc
        [ "$mc" == "2" ] && $AUR -S --needed --noconfirm rigel-bin || $AUR -S --needed --noconfirm gminer-bin
    fi

    # Настройка Huge Pages
    echo -e "${BLUE}Оптимизация Huge Pages...${NC}"
    sudo sysctl -w vm.nr_hugepages=1280
    echo "vm.nr_hugepages=1280" | sudo tee /etc/sysctl.d/10-mining.conf > /dev/null
}

setup_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$RUNTIME_ENV"

    echo -e "${CYAN}=== МАСТЕР НАСТРОЙКИ ===${NC}"

    read -p "Кошелек GPU (Ravencoin): " gpu_wal
    read -p "Кошелек CPU (Monero): " cpu_wal
    echo -e "${YELLOW}Настройка Прокси (Nekoray):${NC}"
    echo "Введите IP:PORT (например, 127.0.0.1:2081)"
    read -p "> " proxy_input

    M_BIN="/opt/gminer/miner"
    [ -f /usr/bin/rigel ] && M_BIN="/usr/bin/rigel"

    cat <<EOF > "$ENV_FILE"
MINER_BIN=$M_BIN
GPU_ALGO=kawpow
GPU_SERVER=gulf.moneroocean.stream:10128
GPU_WALLET=$cpu_wal
CPU_WALLET=$cpu_wal
PROXY_ADDR=$proxy_input
USE_CPU_MINING=true
# Ваши настройки:
CPU_THREADS_IDLE=26
CPU_THREADS_ACTIVE=6
IDLE_TIMEOUT=60
EOF
    echo "CURRENT_CPU_THREADS=6" > "$RUNTIME_ENV"
    echo -e "${GREEN}Конфигурация сохранена.${NC}"
}

create_services() {
    echo -e "${BLUE}Обновление служб и скриптов...${NC}"

    # GPU SERVICE
    cat <<EOF > "$HOME/.config/systemd/user/$GPU_SERVICE"
[Unit]
Description=GPU Miner
After=network.target
[Service]
Type=simple
EnvironmentFile=$ENV_FILE
Environment=all_proxy=http://\${PROXY_ADDR}
Environment=https_proxy=http://\${PROXY_ADDR}
ExecStart=/opt/gminer/miner --algo \${GPU_ALGO} --server \${GPU_SERVER} --user \${GPU_WALLET}
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
ExecStart=/usr/bin/xmrig -o gulf.moneroocean.stream:20128 -u \${CPU_WALLET} --proxy=\${PROXY_ADDR} --tls -k --coin monero -t \${CURRENT_CPU_THREADS} --cpu-no-yield
Restart=always
Nice=19
EOF

    # WATCHDOG SCRIPT (V8.2 INTELLIGENT)
    cat <<'EOF' > "$WATCHDOG_SCRIPT"
#!/bin/bash
CONFIG_DIR="$HOME/.config/mining-manager"
ENV_FILE="$CONFIG_DIR/mining.env"
RUNTIME_ENV="$CONFIG_DIR/runtime.env"

GPU_SRV="miner-gpu.service"
CPU_SRV="miner-cpu.service"

# Внутренний таймер простоя (так как система нам его не дает)
MY_IDLE_TIMER=0
LAST_INT_COUNT=0
LOOP_DELAY=5

# === ФУНКЦИЯ ЧТЕНИЯ АКТИВНОСТИ ЖЕЛЕЗА ===
get_hardware_interrupts() {
    # Складываем количество прерываний от USB (xhci) и клавиатуры/тачпада (i8042)
    # Это работает на уровне ядра, игнорируя Wayland
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

# Инициализация первого значения
LAST_INT_COUNT=$(get_hardware_interrupts)
current_mode="unknown"

echo "Watchdog started. Mode: KERNEL HARDWARE MONITOR (Universal)"

while true; do
    source "$ENV_FILE" 2>/dev/null

    # 1. Получаем текущее число прерываний (кликов/движений)
    CURRENT_INT_COUNT=$(get_hardware_interrupts)

    # 2. Вычисляем разницу с прошлого раза
    DIFF=$((CURRENT_INT_COUNT - LAST_INT_COUNT))

    # Если было много прерываний (>100), значит юзер шевелил мышкой/клавой
    if [ "$DIFF" -gt 100 ]; then
        MY_IDLE_TIMER=0
    else
        # Иначе добавляем время к таймеру
        MY_IDLE_TIMER=$((MY_IDLE_TIMER + LOOP_DELAY))
    fi

    # Обновляем "прошлое" значение
    LAST_INT_COUNT=$CURRENT_INT_COUNT

    # 3. Логика переключения
    if [ "$MY_IDLE_TIMER" -lt "$IDLE_TIMEOUT" ] || is_video_playing; then
        target_mode="active"
        target_threads=$CPU_THREADS_ACTIVE
    else
        target_mode="idle"
        target_threads=$CPU_THREADS_IDLE
    fi

    # 4. Применение
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

# --- 2. ИНТЕРФЕЙС МЕНЮ ---

show_status() {
    echo -e "\n${CYAN}--- СТАТУС СИСТЕМЫ ---${NC}"
    source "$ENV_FILE" 2>/dev/null
    cur_threads=$(grep "CURRENT_CPU_THREADS" "$RUNTIME_ENV" 2>/dev/null | cut -d'=' -f2)

    echo -e "Режим потоков: ${YELLOW}${cur_threads:-ЗАГРУЗКА}${NC} (В конфиге Active=$CPU_THREADS_ACTIVE / Idle=$CPU_THREADS_IDLE)"

    echo -n "Watchdog: "; systemctl --user is-active --quiet $WATCHDOG_SERVICE && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${RED}ВЫКЛ${NC}"
    echo -n "GPU: "; systemctl --user is-active --quiet $GPU_SERVICE && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${YELLOW}СПИТ${NC}"
    echo -n "CPU: "; systemctl --user is-active --quiet $CPU_SERVICE && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${YELLOW}СПИТ${NC}"
    echo "----------------------"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== MINING MANAGER v8.2 (AUTO-RELOAD) ===${NC}"
        show_status
        echo "1. Вкл/Выкл Все службы"
        echo "2. Изменить конфиг (применится автоматически)"
        echo "3. Сбросить всё и ПЕРЕУСТАНОВИТЬ (ВАЖНО ДЛЯ ОБНОВЛЕНИЯ)"
        echo "4. Логи: Процессор"
        echo "5. Логи: Видеокарта"
        echo "6. Логи: Watchdog"
        echo "7. Выход"
        echo ""
        read -p "> " choice
        case $choice in
            1) systemctl --user is-active --quiet $WATCHDOG_SERVICE && systemctl --user stop $WATCHDOG_SERVICE $GPU_SERVICE $CPU_SERVICE || systemctl --user start $WATCHDOG_SERVICE ;;
            2) nano "$ENV_FILE" ;; # Больше не нужно рестартить руками
            3) rm -rf "$CONFIG_DIR"; echo "Конфиг сброшен. Перезапустите скрипт."; exit 0 ;;
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
