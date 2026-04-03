#!/bin/bash
set -e  # Остановка при любой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== НАЧАЛО РАЗВЕРТЫВАНИЯ ОТ ROOT ===${NC}"

# Проверка, что скрипт запущен от root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен запускаться от root!${NC}" 
   exit 1
fi

# 1. Создание пользователя server
echo -e "${BLUE}=== 1. Проверка/создание пользователя server ===${NC}"

# Генерируем случайный пароль (12 символов: буквы+цифры+спецсимволы)
PASSWORD=$(openssl rand -base64 12 | tr -d '\n' | head -c 12)
# Добавляем специальные символы для надежности
PASSWORD="${PASSWORD}@#"
PASSWORD=$(echo $PASSWORD | fold -w12 | head -n1)

if id "server" &>/dev/null; then
    echo -e "${YELLOW}Пользователь server уже существует. Обновляем пароль...${NC}"
    echo "server:$PASSWORD" | chpasswd
else
    echo -e "${GREEN}Создаем пользователя server...${NC}"
    useradd -m -s /bin/bash server
    echo "server:$PASSWORD" | chpasswd
    # Добавляем в группу sudo/admin
    usermod -aG sudo server
    usermod -aG adm server
fi

# Сохраняем пароль в защищенный файл
echo "=== УЧЕТНЫЕ ДАННЫЕ ПОЛЬЗОВАТЕЛЯ server ===" > /root/server_credentials.txt
echo "Имя пользователя: server" >> /root/server_credentials.txt
echo "Пароль: $PASSWORD" >> /root/server_credentials.txt
echo "Домашняя директория: /home/server" >> /root/server_credentials.txt
echo "Создан: $(date)" >> /root/server_credentials.txt
echo "========================================" >> /root/server_credentials.txt
chmod 600 /root/server_credentials.txt

echo -e "${GREEN}✓ Пользователь server создан/обновлен${NC}"
echo -e "${YELLOW}Пароль сохранен в /root/server_credentials.txt${NC}"
echo -e "${YELLOW}Пароль: ${GREEN}$PASSWORD${NC}"

# 2. Настройка домашней директории и прав
echo -e "${BLUE}=== 2. Настройка домашней директории /home/server ===${NC}"

# Убеждаемся, что директория существует и имеет правильные права
if [ ! -d "/home/server" ]; then
    echo -e "${YELLOW}Директория /home/server не найдена, создаем...${NC}"
    mkdir -p /home/server
    chown server:server /home/server
fi

# Устанавливаем правильные права
chown -R server:server /home/server
chmod 755 /home/server

echo -e "${GREEN}✓ Директория /home/server настроена${NC}"

# 3. Установка необходимых пакетов
echo -e "${BLUE}=== 3. Обновление системы и установка зависимостей ===${NC}"
apt update && apt upgrade -y
apt install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev \
    libnss3-dev libssl-dev libreadline-dev libffi-dev libsqlite3-dev \
    wget libbz2-dev git sudo tree

# 4. Установка Python 3.13.7
echo -e "${BLUE}=== 4. Установка Python 3.13.7 ===${NC}"
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

# 5. Создание структуры папок от имени пользователя server
echo -e "${BLUE}=== 5. Создание структуры папок ===${NC}"
su - server << 'EOF'
set -e
cd /home/server
mkdir -p T-lite2.1_source
mkdir -p worksp/group1
mkdir -p worksp/group2
echo "✓ Структура папок создана"
EOF

# 6. Создание виртуальных окружений
echo -e "${BLUE}=== 6. Создание виртуальных окружений ===${NC}"
su - server << 'EOF'
set -e
cd /home/server/worksp/group1
/usr/local/bin/python3.13 -m venv env
cd /home/server/worksp/group2
/usr/local/bin/python3.13 -m venv env
echo "✓ Виртуальные окружения созданы"
EOF

# 7. Клонирование репозитория
echo -e "${BLUE}=== 7. Клонирование репозитория ===${NC}"
su - server << 'EOF'
set -e
cd /home/server
rm -rf T-lite2.1_source/*
git clone https://github.com/grehzeinhow-sys/T-lite2.1_source.git /home/server/T-lite2.1_source
echo "✓ Репозиторий склонирован"
EOF

# 8. Копирование файлов в группу 1
echo -e "${BLUE}=== 8. Копирование файлов в group1 ===${NC}"
su - server << 'EOF'
set -e
# Копируем main.py
if [ -f /home/server/T-lite2.1_source/main.py ]; then
    cp /home/server/T-lite2.1_source/main.py /home/server/worksp/group1/
    echo "✓ main.py скопирован"
else
    echo "⚠ main.py не найден"
fi

# Копируем requirements.txt
if [ -f /home/server/T-lite2.1_source/req.txt ]; then
    cp /home/server/T-lite2.1_source/req.txt /home/server/worksp/group1/requirements.txt
    echo "✓ requirements.txt скопирован из req.txt"
elif [ -f /home/server/T-lite2.1_source/requirements.txt ]; then
    cp /home/server/T-lite2.1_source/requirements.txt /home/server/worksp/group1/
    echo "✓ requirements.txt скопирован"
fi
EOF

# 9. Установка зависимостей
echo -e "${BLUE}=== 9. Установка зависимостей ===${NC}"
su - server << 'EOF'
set -e
cd /home/server/worksp/group1
source env/bin/activate
pip install --upgrade pip

if [ -f requirements.txt ]; then
    pip install -r requirements.txt
    echo "✓ Зависимости установлены"
elif [ -f req.txt ]; then
    pip install -r req.txt
    echo "✓ Зависимости установлены"
else
    echo "⚠ Файл с зависимостями не найден"
fi
deactivate
EOF

# 10. Запуск main.py
echo -e "${BLUE}=== 10. Запуск main.py ===${NC}"
su - server << 'EOF'
set -e
cd /home/server/worksp/group1
source env/bin/activate
python main.py
deactivate
echo "✓ main.py выполнен"
EOF

# 11. Проверка создания папки
echo -e "${BLUE}=== 11. Проверка результата ===${NC}"
if [ -d "/home/server/T-lite-it-2.1" ]; then
    echo -e "${GREEN}✓ УСПЕХ: Папка /home/server/T-lite-it-2.1 создана!${NC}"
    ls -la /home/server/T-lite-it-2.1/
else
    echo -e "${RED}✗ ОШИБКА: Папка /home/server/T-lite-it-2.1 не найдена${NC}"
    echo "Содержимое /home/server:"
    ls -la /home/server/
    exit 1
fi

# 12. Настройка прав на все файлы
echo -e "${BLUE}=== 12. Настройка финальных прав ===${NC}"
chown -R server:server /home/server
chmod -R 755 /home/server
chmod 700 /home/server/worksp/*/env/bin/activate 2>/dev/null || true

# 13. Создание файла отчета
echo -e "${BLUE}=== 13. Создание отчета ===${NC}"
cat > /home/server/deployment_report.txt << EOF
Отчет о развертывании
======================
Дата: $(date)
Пользователь: server
Домашняя директория: /home/server

Установленные компоненты:
- Python 3.13.7
- Git
- Виртуальные окружения в /home/server/worksp/group1/env и group2/env
- Репозиторий T-lite2.1_source

Результат выполнения:
- main.py выполнен успешно
- Папка T-lite-it-2.1 создана: $(ls -la /home/server/T-lite-it-2.1/ 2>/dev/null | head -5)

Пути:
- Исходники: /home/server/T-lite2.1_source
- Рабочая группа 1: /home/server/worksp/group1
- Рабочая группа 2: /home/server/worksp/group2
- Результат: /home/server/T-lite-it-2.1

Для активации окружений:
source /home/server/worksp/group1/env/bin/activate
source /home/server/worksp/group2/env/bin/activate
EOF

chown server:server /home/server/deployment_report.txt
chmod 644 /home/server/deployment_report.txt

# 14. Итоговая информация
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ РАЗВЕРТЫВАНИЕ УСПЕШНО ЗАВЕРШЕНО!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW}Учетные данные пользователя server:${NC}"
echo -e "  Имя: ${GREEN}server${NC}"
echo -e "  Пароль: ${GREEN}$PASSWORD${NC}"
echo -e "  Пароль сохранен в: ${GREEN}/root/server_credentials.txt${NC}"
echo -e ""
echo -e "${YELLOW}Информация о развертывании:${NC}"
echo -e "  Домашняя директория: ${GREEN}/home/server${NC}"
echo -e "  Отчет: ${GREEN}/home/server/deployment_report.txt${NC}"
echo -e ""
echo -e "${YELLOW}Проверка результата:${NC}"
echo -e "  ls -la /home/server/T-lite-it-2.1/"
echo -e ""
echo -e "${YELLOW}Для переключения на пользователя server:${NC}"
echo -e "  su - server"
echo -e "  (введите пароль: $PASSWORD)"
echo -e ""
echo -e "${YELLOW}Для запуска окружения group1:${NC}"
echo -e "  su - server"
echo -e "  source /home/server/worksp/group1/env/bin/activate"
echo -e "${BLUE}========================================${NC}"

# Опционально: переключиться на пользователя server
read -p "Хотите переключиться на пользователя server? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Переключаемся на пользователя server...${NC}"
    echo -e "${YELLOW}Пароль: $PASSWORD${NC}"
    su - server
fi
