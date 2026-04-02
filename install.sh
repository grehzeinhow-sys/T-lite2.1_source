#!/bin/bash
set -e  # Остановка при любой ошибке

echo "=== 1. Обновление системы и установка зависимостей ==="
sudo apt update
sudo apt install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev \
    libnss3-dev libssl-dev libreadline-dev libffi-dev libsqlite3-dev \
    wget libbz2-dev git

echo "=== 2. Установка Python 3.13.7 ==="
cd /tmp
if [ ! -f Python-3.13.7.tgz ]; then
    wget https://www.python.org/ftp/python/3.13.7/Python-3.13.7.tgz
fi
tar -xf Python-3.13.7.tgz
cd Python-3.13.7
./configure --enable-optimizations --prefix=/usr/local
make -j$(nproc)
sudo make altinstall

echo "=== 3. Создание структуры папок ==="
mkdir -p ~/T-lite2.1_source
mkdir -p ~/worksp/group1
mkdir -p ~/worksp/group2

echo "=== 4. Создание виртуальных окружений с Python 3.13.7 ==="
cd ~/worksp/group1
python3.13 -m venv env
cd ~/worksp/group2
python3.13 -m venv env

echo "=== 5. Клонирование репозитория ==="
# Очищаем папку, если она уже существует
rm -rf ~/T-lite2.1_source/*
git clone https://github.com/grehzeinhow-sys/T-lite2.1_source.git ~/T-lite2.1_source

echo "=== 6. Проверка наличия файлов в репозитории ==="
ls -la ~/T-lite2.1_source/

echo "=== 7. Копирование main.py и requirements.txt в группу 1 ==="
# Проверяем, как именно называются файлы в репозитории
if [ -f ~/T-lite2.1_source/main.py ]; then
    cp ~/T-lite2.1_source/main.py ~/worksp/group1/
else
    echo "ВНИМАНИЕ: main.py не найден. Ищем другие .py файлы:"
    find ~/T-lite2.1_source -name "*.py" -type f
fi

# Копируем requirements.txt (мог быть назван req.txt)
if [ -f ~/T-lite2.1_source/req.txt ]; then
    cp ~/T-lite2.1_source/req.txt ~/worksp/group1/requirements.txt
elif [ -f ~/T-lite2.1_source/requirements.txt ]; then
    cp ~/T-lite2.1_source/requirements.txt ~/worksp/group1/
else
    echo "ВНИМАНИЕ: Файл с зависимостями не найден. Ищем:"
    find ~/T-lite2.1_source -name "*.txt" -type f
fi

echo "=== 8. Установка зависимостей в виртуальное окружение группы 1 ==="
cd ~/worksp/group1
source env/bin/activate

# Проверяем, какой файл с зависимостями в итоге скопировался
if [ -f requirements.txt ]; then
    echo "Установка из requirements.txt"
    pip install --upgrade pip
    pip install -r requirements.txt
elif [ -f req.txt ]; then
    echo "Установка из req.txt"
    pip install --upgrade pip
    pip install -r req.txt
else
    echo "ПРЕДУПРЕЖДЕНИЕ: Файл с зависимостями не найден. Устанавливаем только pip."
    pip install --upgrade pip
fi

deactivate

echo "=== 9. Запуск main.py ==="
cd ~/worksp/group1
source env/bin/activate
python main.py
deactivate

echo "=== 10. Проверка создания папки ~/T-lite-it-2.1 ==="
if [ -d ~/T-lite-it-2.1 ]; then
    echo "✓ УСПЕХ: Папка ~/T-lite-it-2.1 создана!"
    ls -la ~/T-lite-it-2.1/
else
    echo "✗ ОШИБКА: Папка ~/T-lite-it-2.1 не найдена."
    echo "Содержимое домашней директории:"
    ls -la ~/
    exit 1
fi

echo "=== 11. Итоговая проверка ==="
echo "Python версия:"
python3.13 --version
echo ""
echo "Виртуальное окружение группы 1:"
~/worksp/group1/env/bin/python --version
echo "Установленные пакеты в group1:"
~/worksp/group1/env/bin/pip list
echo ""
echo "Структура проектов:"
tree -L 3 ~/worksp/ 2>/dev/null || ls -la ~/worksp/
echo ""
echo "=== ВСЕ ЗАДАЧИ ВЫПОЛНЕНЫ УСПЕШНО! ==="
