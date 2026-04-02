import os
import requests
from pathlib import Path
import json
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading
import time

# Правильный импорт tqdm
try:
    from tqdm import tqdm
except ImportError:
    # Если tqdm не установлен, создаем заглушку
    class tqdm:
        def __init__(self, *args, **kwargs):
            pass
        def __enter__(self):
            return self
        def __exit__(self, *args):
            pass
        def update(self, n=1):
            pass
        def set_postfix_str(self, s):
            pass
    print("tqdm не установлен. Установите его: pip install tqdm")

class MultiThreadDownloader:
    def __init__(self, model_id="t-tech/T-lite-it-2.1", local_dir="T-lite-it-2.1", max_workers=20):
        """
        Многопоточный загрузчик файлов модели

        Args:
            model_id: ID модели на Hugging Face
            local_dir: Локальная директория для сохранения
            max_workers: Максимальное количество потоков
        """
        self.model_id = model_id
        self.local_dir = Path(local_dir)
        self.max_workers = max_workers
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        }
        self.lock = threading.Lock()
        self.download_stats = {
            'total_files': 0,
            'downloaded': 0,
            'failed': 0,
            'total_size': 0,
            'downloaded_size': 0
        }

        # Создаем директорию
        self.local_dir.mkdir(parents=True, exist_ok=True)

    def get_file_list(self):
        """Получает список всех файлов модели"""
        api_url = f"https://huggingface.co/api/models/{self.model_id}/tree/main"

        print(f"Получаем список файлов для модели {self.model_id}...")

        try:
            response = requests.get(api_url, headers=self.headers, timeout=30)
            response.raise_for_status()
            files = response.json()

            # Фильтруем только файлы
            file_list = [f for f in files if f.get('type') == 'file']

            # Сортируем по размеру (большие файлы первыми)
            file_list.sort(key=lambda x: x.get('size', 0), reverse=True)

            self.download_stats['total_files'] = len(file_list)
            self.download_stats['total_size'] = sum(f.get('size', 0) for f in file_list)

            print(f"Найдено {len(file_list)} файлов")
            print(f"Общий размер: {self.format_size(self.download_stats['total_size'])}")

            return file_list

        except requests.exceptions.RequestException as e:
            print(f"Ошибка при получении списка файлов: {e}")
            return None

    def format_size(self, size_bytes):
        """Форматирует размер в человекочитаемый вид"""
        if size_bytes == 0:
            return "0 B"
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if size_bytes < 1024.0:
                return f"{size_bytes:.2f} {unit}"
            size_bytes /= 1024.0
        return f"{size_bytes:.2f} PB"

    def download_file(self, file_info, pbar=None):
        """Скачивает один файл"""
        file_path = file_info['path']
        file_size = file_info.get('size', 0)
        local_path = self.local_dir / file_path

        # Создаем поддиректории
        local_path.parent.mkdir(parents=True, exist_ok=True)

        # Проверяем существующий файл
        if local_path.exists() and local_path.stat().st_size == file_size and file_size > 0:
            with self.lock:
                self.download_stats['downloaded'] += 1
                self.download_stats['downloaded_size'] += file_size
            if pbar:
                pbar.update(1)
                pbar.set_postfix_str(f"пропущен: {file_path}")
            return {'status': 'skipped', 'file': file_path, 'size': file_size}

        # URL для скачивания
        download_url = f"https://huggingface.co/{self.model_id}/resolve/main/{file_path}"

        try:
            # Скачиваем с прогрессом
            response = requests.get(download_url, headers=self.headers, stream=True, timeout=60)
            response.raise_for_status()

            # Создаем временный файл
            temp_path = local_path.with_suffix(local_path.suffix + '.tmp')

            downloaded = 0
            with open(temp_path, 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192*8):  # 64KB chunks
                    if chunk:
                        f.write(chunk)
                        downloaded += len(chunk)

            # Переименовываем временный файл
            temp_path.rename(local_path)

            with self.lock:
                self.download_stats['downloaded'] += 1
                self.download_stats['downloaded_size'] += downloaded

            if pbar:
                pbar.update(1)
                pbar.set_postfix_str(f"завершен: {file_path} ({self.format_size(downloaded)})")

            return {'status': 'success', 'file': file_path, 'size': downloaded}

        except Exception as e:
            with self.lock:
                self.download_stats['failed'] += 1

            if pbar:
                pbar.update(1)
                pbar.set_postfix_str(f"ошибка: {file_path}")

            return {'status': 'failed', 'file': file_path, 'error': str(e)}

    def download_all(self, file_list):
        """Многопоточная загрузка всех файлов"""
        print(f"\nНачинаем многопоточную загрузку ({self.max_workers} потоков)...")
        print("=" * 60)

        # Создаем прогресс-бар
        pbar = tqdm(
            total=self.download_stats['total_files'],
            desc="Загрузка файлов",
            unit="файл",
            ncols=100
        )

        # Создаем пул потоков
        with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            # Отправляем все задачи
            futures = []
            for file_info in file_list:
                future = executor.submit(self.download_file, file_info, pbar)
                futures.append(future)

            # Ожидаем завершения всех задач
            for future in as_completed(futures):
                try:
                    result = future.result()
                except Exception as e:
                    with self.lock:
                        self.download_stats['failed'] += 1
                    pbar.update(1)
                    pbar.set_postfix_str(f"критическая ошибка")

        pbar.close()

        # Выводим статистику
        print("\n" + "=" * 60)
        print("СТАТИСТИКА ЗАГРУЗКИ:")
        print(f"  Всего файлов: {self.download_stats['total_files']}")
        print(f"  Загружено: {self.download_stats['downloaded']}")
        print(f"  Пропущено: {self.download_stats['total_files'] - self.download_stats['downloaded'] - self.download_stats['failed']}")
        print(f"  Ошибок: {self.download_stats['failed']}")
        print(f"  Общий размер: {self.format_size(self.download_stats['total_size'])}")
        print(f"  Загружено: {self.format_size(self.download_stats['downloaded_size'])}")

    def save_manifest(self, file_list):
        """Сохраняет манифест загрузки"""
        manifest = {
            "model_id": self.model_id,
            "download_date": time.strftime("%Y-%m-%d %H:%M:%S"),
            "total_files": self.download_stats['total_files'],
            "total_size": self.download_stats['total_size'],
            "downloaded_files": self.download_stats['downloaded'],
            "failed_files": self.download_stats['failed'],
            "files": file_list
        }

        manifest_path = self.local_dir / "download_manifest.json"
        with open(manifest_path, 'w', encoding='utf-8') as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)

        print(f"\nМанифест сохранен: {manifest_path}")

def download_with_git_lfs(model_id, local_dir):
    """Альтернативный метод через git-lfs"""
    import subprocess
    import platform

    print("\nИспользуем альтернативный метод (git-lfs)...")

    # Проверяем git
    try:
        subprocess.run(["git", "--version"], check=True, capture_output=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Git не найден. Пожалуйста, установите git")
        return False

    # Устанавливаем git-lfs если нужно
    try:
        subprocess.run(["git", "lfs", "version"], check=True, capture_output=True)
    except:
        print("Устанавливаем git-lfs...")
        if platform.system() == "Linux":
            subprocess.run(["sudo", "apt-get", "update"], check=False)
            subprocess.run(["sudo", "apt-get", "install", "-y", "git-lfs"], check=False)
        elif platform.system() == "Darwin":
            subprocess.run(["brew", "install", "git-lfs"], check=False)

        subprocess.run(["git", "lfs", "install"], check=False)

    # Клонируем репозиторий
    repo_url = f"https://huggingface.co/{model_id}"

    print(f"Клонируем репозиторий в {local_dir}...")
    try:
        subprocess.run(["git", "lfs", "clone", repo_url, local_dir],
                      check=True, capture_output=True)
        print("Модель успешно скачана через git-lfs")
        return True
    except subprocess.CalledProcessError:
        try:
            subprocess.run(["git", "clone", repo_url, local_dir], check=True)
            subprocess.run(["git", "-C", local_dir, "lfs", "pull"], check=True)
            print("Модель успешно скачана через git")
            return True
        except subprocess.CalledProcessError as e:
            print(f"Ошибка клонирования: {e}")
            return False

def main():
    """Основная функция"""
    print("=" * 60)
    print("МНОГОПОТОЧНАЯ ЗАГРУЗКА МОДЕЛИ T-lite-it-2.1")
    print("=" * 60)

    # Параметры
    MODEL_ID = "t-tech/T-lite-it-2.1"
    LOCAL_DIR = "T-lite-it-2.1"
    MAX_WORKERS = 20  # Количество потоков

    # Создаем загрузчик
    downloader = MultiThreadDownloader(
        model_id=MODEL_ID,
        local_dir=LOCAL_DIR,
        max_workers=MAX_WORKERS
    )

    # Получаем список файлов
    file_list = downloader.get_file_list()

    if file_list:
        # Загружаем файлы
        downloader.download_all(file_list)

        # Сохраняем манифест
        downloader.save_manifest(file_list)

        # Проверяем результат
        if downloader.download_stats['failed'] > 0:
            print("\nНекоторые файлы не загрузились. Пробуем альтернативный метод...")
            if download_with_git_lfs(MODEL_ID, LOCAL_DIR):
                print("Альтернативный метод завершен успешно")
            else:
                print("Не удалось загрузить все файлы. Попробуйте запустить скрипт снова.")
        else:
            print("\nВСЕ ФАЙЛЫ УСПЕШНО ЗАГРУЖЕНЫ!")

    else:
        print("\nНе удалось получить список файлов. Пробуем альтернативный метод...")
        if download_with_git_lfs(MODEL_ID, LOCAL_DIR):
            print("Модель успешно скачана через git-lfs")
        else:
            print("Не удалось загрузить модель. Проверьте подключение к интернету.")

    print("\n" + "=" * 60)
    print("ИНСТРУКЦИЯ ПО ИСПОЛЬЗОВАНИЮ:")
    print("=" * 60)
    print("Для загрузки модели используйте:")
    print("```python")
    print("from transformers import AutoModelForCausalLM, AutoTokenizer")
    print("")
    print(f"model_path = './{LOCAL_DIR}'")
    print("tokenizer = AutoTokenizer.from_pretrained(model_path)")
    print("model = AutoModelForCausalLM.from_pretrained(model_path)")
    print("```")

if __name__ == "__main__":
    # Устанавливаем зависимости если нужно
    try:
        import requests
    except ImportError:
        print("Устанавливаем requests...")
        import subprocess
        subprocess.check_call(['pip', 'install', 'requests'])

    # Проверяем и устанавливаем tqdm
    try:
        from tqdm import tqdm
    except ImportError:
        print("Устанавливаем tqdm...")
        import subprocess
        subprocess.check_call(['pip', 'install', 'tqdm'])
        from tqdm import tqdm

    main()
