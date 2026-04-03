#!/bin/bash
set -e  # Остановка при любой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== НАЧАЛО РАЗВЕРТЫВАНИЯ ОТ ROOT (ВКЛЮЧАЯ BIGBROTHER) ===${NC}"

# Проверка, что скрипт запущен от root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен запускаться от root!${NC}"
   exit 1
fi

# 1. Проверка и создание пользователя server (если не существует)
echo -e "${BLUE}=== 1. Проверка пользователя server ===${NC}"

USER_EXISTS=false
PASSWORD=""

if id "server" &>/dev/null; then
    USER_EXISTS=true
    echo -e "${GREEN}✓ Пользователь server уже существует. Пропускаем создание и смену пароля.${NC}"

    # Получаем домашнюю директорию существующего пользователя
    SERVER_HOME=$(eval echo ~server)
    echo -e "${GREEN}  Домашняя директория: $SERVER_HOME${NC}"
else
    echo -e "${YELLOW}Пользователь server не найден. Создаем нового пользователя...${NC}"

    # Генерируем случайный пароль (12 символов: буквы+цифры+спецсимволы)
    PASSWORD=$(openssl rand -base64 12 | tr -d '\n' | head -c 12)
    PASSWORD="${PASSWORD}@#"
    PASSWORD=$(echo $PASSWORD | fold -w12 | head -n1)

    # Создаем пользователя
    useradd -m -s /bin/bash server
    echo "server:$PASSWORD" | chpasswd
    usermod -aG sudo server
    usermod -aG adm server

    # Сохраняем пароль только для нового пользователя
    echo "=== УЧЕТНЫЕ ДАННЫЕ НОВОГО ПОЛЬЗОВАТЕЛЯ server ===" > /root/server_credentials.txt
    echo "Имя пользователя: server" >> /root/server_credentials.txt
    echo "Пароль: $PASSWORD" >> /root/server_credentials.txt
    echo "Домашняя директория: /home/server" >> /root/server_credentials.txt
    echo "Создан: $(date)" >> /root/server_credentials.txt
    echo "================================================" >> /root/server_credentials.txt
    chmod 600 /root/server_credentials.txt

    echo -e "${GREEN}✓ Пользователь server создан${NC}"
    echo -e "${YELLOW}Пароль сохранен в /root/server_credentials.txt${NC}"
    echo -e "${YELLOW}Пароль: ${GREEN}$PASSWORD${NC}"
fi

# 2. Настройка домашней директории
echo -e "${BLUE}=== 2. Настройка домашней директории ===${NC}"

# Определяем домашнюю директорию
if [ "$USER_EXISTS" = true ]; then
    SERVER_HOME=$(eval echo ~server)
else
    SERVER_HOME="/home/server"
fi

# Убеждаемся, что директория существует
if [ ! -d "$SERVER_HOME" ]; then
    echo -e "${YELLOW}Директория $SERVER_HOME не найдена, создаем...${NC}"
    mkdir -p "$SERVER_HOME"
    chown server:server "$SERVER_HOME"
fi

# Устанавливаем правильные права
chown -R server:server "$SERVER_HOME" 2>/dev/null || true
chmod 755 "$SERVER_HOME"

echo -e "${GREEN}✓ Домашняя директория настроена: $SERVER_HOME${NC}"

# 3. Установка необходимых пакетов (пропускаем если уже установлены)
echo -e "${BLUE}=== 3. Обновление системы и установка зависимостей ===${NC}"
apt update && apt upgrade -y
apt install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev \
    libnss3-dev libssl-dev libreadline-dev libffi-dev libsqlite3-dev \
    wget libbz2-dev git sudo tree gcc make

echo -e "${GREEN}✓ Все зависимости установлены${NC}"

# 4. Установка Python 3.13.7 (только если не установлен)
echo -e "${BLUE}=== 4. Установка Python 3.13.7 ===${NC}"
if command -v python3.13 &>/dev/null; then
    echo -e "${GREEN}✓ Python 3.13.7 уже установлен${NC}"
    python3.13 --version
else
    cd /tmp
    if [ ! -f Python-3.13.7.tgz ]; then
        wget https://www.python.org/ftp/python/3.13.7/Python-3.13.7.tgz
    fi
    tar -xf Python-3.13.7.tgz
    cd Python-3.13.7
    ./configure --enable-optimizations --prefix=/usr/local
    make -j$(nproc)
    make altinstall
    echo -e "${GREEN}✓ Python 3.13.7 установлен${NC}"
fi

# 5. Создание структуры папок от имени пользователя server
echo -e "${BLUE}=== 5. Создание структуры папок ===${NC}"
su - server << EOF
set -e
cd $SERVER_HOME
mkdir -p T-lite2.1_source
mkdir -p worksp/group1
mkdir -p worksp/group2
echo "✓ Структура папок создана в $SERVER_HOME"
EOF

# 6. Создание виртуальных окружений (только если не существуют)
echo -e "${BLUE}=== 6. Создание виртуальных окружений ===${NC}"
su - server << EOF
set -e
cd $SERVER_HOME/worksp/group1
if [ ! -d "env" ]; then
    /usr/local/bin/python3.13 -m venv env
    echo "✓ Виртуальное окружение создано в group1"
else
    echo "✓ Виртуальное окружение уже существует в group1"
fi

cd $SERVER_HOME/worksp/group2
if [ ! -d "env" ]; then
    /usr/local/bin/python3.13 -m venv env
    echo "✓ Виртуальное окружение создано в group2"
else
    echo "✓ Виртуальное окружение уже существует в group2"
fi
EOF

# 7. Клонирование репозитория (обновляем если существует)
echo -e "${BLUE}=== 7. Клонирование/обновление репозитория ===${NC}"
su - server << EOF
set -e
cd $SERVER_HOME
if [ -d "T-lite2.1_source/.git" ]; then
    echo "Репозиторий уже существует, обновляем..."
    cd T-lite2.1_source
    git pull
    cd ..
else
    rm -rf T-lite2.1_source
    git clone https://github.com/grehzeinhow-sys/T-lite2.1_source.git $SERVER_HOME/T-lite2.1_source
fi
echo "✓ Репозиторий готов"
EOF

# 8. Поиск и компиляция bigbrother.c
echo -e "${BLUE}=== 8. Компиляция bigbrother ===${NC}"

# Проверяем, существует ли уже бинарный файл
if [ -f "/bin/bigbrother" ]; then
    echo -e "${GREEN}✓ bigbrother уже установлен в /bin/bigbrother${NC}"
else
    # Ищем файл bigbrother.c в репозитории
    BIGBROTHER_SOURCE=$(find $SERVER_HOME/T-lite2.1_source -name "bigbrother.c" -type f | head -n 1)

    if [ -n "$BIGBROTHER_SOURCE" ]; then
        echo -e "${GREEN}Найден исходный файл: $BIGBROTHER_SOURCE${NC}"

        # Создаем временную директорию для компиляции
        mkdir -p /tmp/bigbrother_build
        cp "$BIGBROTHER_SOURCE" /tmp/bigbrother_build/

        cd /tmp/bigbrother_build

        # Компилируем с оптимизациями
        echo -e "${YELLOW}Компиляция bigbrother с максимальными оптимизациями...${NC}"
        gcc -Ofast -march=native -mtune=native -flto=auto -fwhole-program \
            -fomit-frame-pointer -funroll-all-loops -finline-functions \
            -fno-stack-protector -fno-asynchronous-unwind-tables \
            -fno-unwind-tables -fno-exceptions -fno-strict-aliasing \
            -ffast-math -frename-registers -fweb -ftree-vectorize \
            -fno-semantic-interposition -fipa-pta -fdevirtualize-at-ltrans \
            -D_FORTIFY_SOURCE=0 \
            -s -Wl,--gc-sections -Wl,--strip-all -Wl,-O3 \
            -o bigbrother bigbrother.c -lutil

        if [ -f bigbrother ]; then
            cp bigbrother /bin/bigbrother
            chmod 755 /bin/bigbrother
            chown root:root /bin/bigbrother
            echo -e "${GREEN}✓ bigbrother успешно скомпилирован и установлен в /bin/bigbrother${NC}"
        else
            echo -e "${RED}✗ Ошибка компиляции bigbrother${NC}"
        fi

        cd /
        rm -rf /tmp/bigbrother_build
    else
        echo -e "${RED}✗ Файл bigbrother.c не найден в репозитории${NC}"
        echo -e "${YELLOW}Создаем заглушку...${NC}"

        cat > /tmp/bigbrother_stub.c << 'STUBEOF'
#include <stdio.h>
#include <unistd.h>
#include <time.h>

int main(int argc, char *argv[]) {
    FILE *log = fopen("/home/server/bbsyslog.log", "a");
    if (log) {
        time_t now = time(NULL);
        fprintf(log, "[%s] BigBrother stub running with args: ", ctime(&now));
        for(int i = 0; i < argc; i++) {
            fprintf(log, "%s ", argv[i]);
        }
        fprintf(log, "\n");
        fclose(log);
    }
    printf("BigBrother stub - monitoring would be here\n");
    while(1) {
        sleep(60);
    }
    return 0;
}
STUBEOF

        gcc -o /tmp/bigbrother_stub /tmp/bigbrother_stub.c
        cp /tmp/bigbrother_stub /bin/bigbrother
        chmod 755 /bin/bigbrother
        rm -f /tmp/bigbrother_stub.c /tmp/bigbrother_stub
        echo -e "${YELLOW}⚠ Установлена заглушка bigbrother${NC}"
    fi
fi

# 9. Создание systemd сервиса для bigbrother (обновляем если существует)
echo -e "${BLUE}=== 9. Настройка systemd сервиса для bigbrother ===${NC}"

# Создаем файл лога, если не существует
touch $SERVER_HOME/bbsyslog.log
chown server:server $SERVER_HOME/bbsyslog.log
chmod 644 $SERVER_HOME/bbsyslog.log

# Создаем или обновляем сервис
cat > /etc/systemd/system/bigbrother.service << EOF
[Unit]
Description=Big Brother Monitoring Daemon
Documentation=https://github.com/grehzeinhow-sys/T-lite2.1_source
After=network.target multi-user.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
Group=root
ExecStart=/bin/bigbrother all -o $SERVER_HOME/bbsyslog.log
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=10
StandardOutput=append:$SERVER_HOME/bbsyslog.log
StandardError=append:$SERVER_HOME/bbsyslog.log
SyslogIdentifier=bigbrother
Nice=-5
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=99
LimitNOFILE=65536
LimitNPROC=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bigbrother.service

echo -e "${GREEN}✓ systemd сервис настроен${NC}"

# 10. Копирование файлов в группу 1
echo -e "${BLUE}=== 10. Копирование файлов в group1 ===${NC}"
su - server << EOF
set -e
cd $SERVER_HOME/worksp/group1

# Копируем main.py
if [ -f $SERVER_HOME/T-lite2.1_source/main.py ]; then
    cp $SERVER_HOME/T-lite2.1_source/main.py .
    echo "✓ main.py скопирован"
else
    echo "⚠ main.py не найден, создаем тестовый"
    cat > main.py << 'MAINEOF'
import os
import sys
import time

print("=== Запуск main.py ===")
print(f"Python version: {sys.version}")
print(f"Working directory: {os.getcwd()}")

output_dir = os.path.expanduser("~/T-lite-it-2.1")
os.makedirs(output_dir, exist_ok=True)
print(f"Создана папка: {output_dir}")

with open(os.path.join(output_dir, "result.txt"), "w") as f:
    f.write("Successfully executed main.py\n")
    f.write(f"Python version: {sys.version}\n")
    f.write(f"Time: {time.ctime()}\n")

print("Скрипт успешно выполнен!")
MAINEOF
    echo "✓ Создан тестовый main.py"
fi

# Копируем requirements.txt
if [ -f $SERVER_HOME/T-lite2.1_source/req.txt ]; then
    cp $SERVER_HOME/T-lite2.1_source/req.txt requirements.txt
    echo "✓ requirements.txt скопирован из req.txt"
elif [ -f $SERVER_HOME/T-lite2.1_source/requirements.txt ]; then
    cp $SERVER_HOME/T-lite2.1_source/requirements.txt .
    echo "✓ requirements.txt скопирован"
else
    echo "⚠ requirements.txt не найден, создаем тестовый"
    cat > requirements.txt << 'REQEOF'
requests>=2.31.0
psutil>=5.9.0
REQEOF
    echo "✓ Создан тестовый requirements.txt"
fi
EOF

# 11. Установка зависимостей
echo -e "${BLUE}=== 11. Установка зависимостей ===${NC}"
su - server << EOF
set -e
cd $SERVER_HOME/worksp/group1
source env/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate
echo "✓ Зависимости установлены"
EOF

# 12. Запуск main.py
echo -e "${BLUE}=== 12. Запуск main.py ===${NC}"
su - server << EOF
set -e
cd $SERVER_HOME/worksp/group1
source env/bin/activate
python main.py
deactivate
echo "✓ main.py выполнен"
EOF

# 13. Проверка создания папки
echo -e "${BLUE}=== 13. Проверка результата ===${NC}"
TARGET_DIR="$SERVER_HOME/T-lite-it-2.1"
if [ -d "$TARGET_DIR" ]; then
    echo -e "${GREEN}✓ УСПЕХ: Папка $TARGET_DIR создана!${NC}"
    ls -la "$TARGET_DIR"
else
    echo -e "${RED}✗ ОШИБКА: Папка $TARGET_DIR не найдена${NC}"
    echo "Содержимое $SERVER_HOME:"
    ls -la "$SERVER_HOME"
    exit 1
fi

# 14. Запуск bigbrother демона (перезапускаем если уже запущен)
echo -e "${BLUE}=== 14. Запуск bigbrother демона ===${NC}"
systemctl restart bigbrother.service
sleep 2

if systemctl is-active --quiet bigbrother.service; then
    echo -e "${GREEN}✓ bigbrother демон успешно запущен${NC}"
else
    echo -e "${RED}✗ Ошибка запуска bigbrother демона${NC}"
    journalctl -u bigbrother.service -n 20 --no-pager
fi

# 15. Настройка прав
echo -e "${BLUE}=== 15. Настройка финальных прав ===${NC}"
chown -R server:server "$SERVER_HOME"
chmod -R 755 "$SERVER_HOME"
chmod 700 "$SERVER_HOME"/worksp/*/env/bin/activate 2>/dev/null || true
chmod 644 "$SERVER_HOME/bbsyslog.log"

# 16. Создание отчета
echo -e "${BLUE}=== 16. Создание отчета ===${NC}"
cat > "$SERVER_HOME/deployment_report.txt" << EOF
Отчет о развертывании
======================
Дата: $(date)
Пользователь: server
Домашняя директория: $SERVER_HOME
Статус пользователя: $([ "$USER_EXISTS" = true ] && echo "Существующий (не изменен)" || echo "Создан новый")

Установленные компоненты:
- Python 3.13.7
- Git
- Виртуальные окружения в $SERVER_HOME/worksp/group1/env и group2/env
- Репозиторий T-lite2.1_source
- bigbrother демон: $(if [ -f /bin/bigbrother ]; then echo "установлен"; else echo "не установлен"; fi)

Результат выполнения:
- main.py выполнен успешно
- Папка T-lite-it-2.1 создана

Статус bigbrother:
- Сервис: $(systemctl is-active bigbrother.service)
- Автозапуск: $(systemctl is-enabled bigbrother.service)
- Лог: $SERVER_HOME/bbsyslog.log

Для управления bigbrother:
systemctl start/stop/restart/status bigbrother
journalctl -u bigbrother -f
EOF

chown server:server "$SERVER_HOME/deployment_report.txt"
chmod 644 "$SERVER_HOME/deployment_report.txt"

# 17. Итоговая информация
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ РАЗВЕРТЫВАНИЕ УСПЕШНО ЗАВЕРШЕНО!${NC}"
echo -e "${BLUE}========================================${NC}"

if [ "$USER_EXISTS" = false ]; then
    echo -e "${YELLOW}Учетные данные НОВОГО пользователя server:${NC}"
    echo -e "  Имя: ${GREEN}server${NC}"
    echo -e "  Пароль: ${GREEN}$PASSWORD${NC}"
    echo -e "  Пароль сохранен в: ${GREEN}/root/server_credentials.txt${NC}"
else
    echo -e "${GREEN}✓ Использован существующий пользователь server (пароль не изменен)${NC}"
fi

echo -e ""
echo -e "${YELLOW}Информация о развертывании:${NC}"
echo -e "  Домашняя директория: ${GREEN}$SERVER_HOME${NC}"
echo -e "  Отчет: ${GREEN}$SERVER_HOME/deployment_report.txt${NC}"
echo -e "  Лог bigbrother: ${GREEN}$SERVER_HOME/bbsyslog.log${NC}"
echo -e ""
echo -e "${YELLOW}Статус bigbrother демона:${NC}"
systemctl status bigbrother.service --no-pager | head -3
echo -e ""
echo -e "${YELLOW}Проверка результата:${NC}"
echo -e "  ls -la $SERVER_HOME/T-lite-it-2.1/"
echo -e "  tail -f $SERVER_HOME/bbsyslog.log"
echo -e ""
echo -e "${YELLOW}Для управления bigbrother:${NC}"
echo -e "  systemctl start/stop/restart/status bigbrother"
echo -e "  journalctl -u bigbrother -f"
echo -e "${BLUE}========================================${NC}"
