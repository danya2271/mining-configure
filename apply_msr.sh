#!/bin/bash

# Проверка на права root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт через sudo: sudo bash $0"
  exit 1
fi

echo "=== Оптимизация процессора для майнинга (MSR MOD) ==="

# 1. Установка msr-tools
echo "[1/4] Проверка msr-tools..."
if ! command -v wrmsr &> /dev/null; then
    pacman -S --needed --noconfirm msr-tools
fi

# 2. Загрузка модуля ядра
echo "[2/4] Загрузка модуля msr..."
modprobe msr

# 3. Применение патча (Отключение префетчеров для Haswell/Xeon v3)
# Регистр 0x1a4, значение 0xf отключает 4 типа префетчеров
echo "[3/4] Запись значений в регистры процессора..."
wrmsr -a 0x1a4 0xf

# 4. Настройка автозапуска при загрузке системы
echo "[4/4] Настройка автозапуска через systemd..."

# Создаем файл службы
cat <<EOF > /etc/systemd/system/xeon-msr-mod.service
[Unit]
Description=Apply Xeon MSR MOD for Mining
After=network.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/modprobe msr
ExecStart=/usr/bin/wrmsr -a 0x1a4 0xf
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Включаем службу
systemctl daemon-reload
systemctl enable xeon-msr-mod.service

echo "-------------------------------------------------------"
echo -e "\033[0;32mПАТЧ УСПЕШНО ПРИМЕНЕН\033[0m"
echo "MSR MOD будет работать автоматически после перезагрузки."
echo "Теперь перезапустите майнер и проверьте логи XMRig."
echo "-------------------------------------------------------"
