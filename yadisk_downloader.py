#!/usr/bin/env python3
"""
Скачивание публичной папки или одиночного файла с Яндекс Диска без авторизации
(с пагинацией, кэшированием статусов gone, проверкой размера и MD5, журналом проблем
и защитой от 429/500).
Использование: python yadisk_download.py <ссылка> [папка назначения]
"""

import sys
import os
import json
import urllib.request
import urllib.parse
import urllib.error
import http.client
import ssl
import socket
import time
import random
import hashlib

API = "https://cloud-api.yandex.net/v1/disk/public/resources"
CACHE_TTL = 86400  # Время жизни кэша в секундах (24 часа)

unavailable_log = time.strftime("unavailable_files_%Y-%m-%d_%H-%M-%S.txt")


class RetryableError(Exception):
    """Проверка после скачивания не прошла: имеет смысл повторить."""


# Ошибки, при которых скачивание нужно повторять
RETRY_ERRORS = (
    TimeoutError,
    socket.timeout,
    urllib.error.URLError,
    ConnectionError,          # ConnectionResetError и т.п.
    http.client.HTTPException,  # IncompleteRead и т.п.
    ssl.SSLError,
    RetryableError,
)


def log_problem(problem, path=None, url=None, details=None):
    """Записывает проблему в журнал текущего запуска."""
    try:
        with open(unavailable_log, "a", encoding="utf-8") as log:
            log.write("=" * 70 + "\n")
            log.write("Время: " + time.strftime("%Y-%m-%d %H:%M:%S") + "\n")
            log.write("Проблема: " + str(problem) + "\n")
            if path:
                log.write("Файл: " + str(path) + "\n")
            if url:
                log.write("URL: " + str(url) + "\n")
            if details:
                log.write("Подробности: " + str(details) + "\n")
            log.write("\n")
    except Exception as e:
        print(f"\nНе удалось записать ошибку в журнал: {e}")


def get_cache_filename(public_key):
    """Генерирует уникальное имя файла кэша на основе хэша публичной ссылки."""
    key_hash = hashlib.md5(public_key.encode("utf-8")).hexdigest()
    return f"yadisk_cache_{key_hash}.json"


def calculate_md5(file_path, chunk_size=8192):
    """Вычисляет MD5-хеш локального файла."""
    if not os.path.exists(file_path):
        return None
    hasher = hashlib.md5()
    try:
        with open(file_path, "rb") as f:
            while True:
                chunk = f.read(chunk_size)
                if not chunk:
                    break
                hasher.update(chunk)
        return hasher.hexdigest()
    except Exception as e:
        log_problem("Ошибка вычисления MD5", file_path, details=e)
        return None


def fetch_with_retry(url, timeout=30, retries=8, backoff=5):
    """Выполняет GET-запрос с повторными попытками при сетевых сбоях и обработкой 429."""
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            last_err = e
            # Фатальные ошибки сразу наверх без ретритов
            if e.code in (400, 404, 410):
                raise
            if e.code == 429:
                retry_after = e.headers.get("Retry-After")
                if retry_after and retry_after.isdigit():
                    wait = int(retry_after) + random.uniform(5.0, 10.0)
                else:
                    wait = min(15 + (attempt * 10), 90) + random.uniform(2.0, 5.0)

                print(f"  превышен лимит запросов (429), пауза {wait:.1f}с (попытка {attempt}/{retries})...")
                time.sleep(wait)
                continue

            wait = (backoff * attempt) + random.uniform(1, 3)
            print(f"  ошибка HTTP ({e.code} {e.reason}), повтор {attempt}/{retries} через {wait:.1f}с...")
            time.sleep(wait)
        except RETRY_ERRORS as e:
            last_err = e
            wait = (backoff * attempt) + random.uniform(1, 3)
            print(f"  сетевая ошибка ({e}), повтор {attempt}/{retries} через {wait:.1f}с...")
            time.sleep(wait)
    if last_err:
        raise last_err
    raise Exception("Не удалось выполнить HTTP-запрос")


def get_items(public_key, path="/", offset=0, limit=100):
    """Запрашивает порцию элементов папки с использованием пагинации."""
    params = urllib.parse.urlencode({
        "public_key": public_key,
        "path": path,
        "offset": offset,
        "limit": limit,
        "fields": "_embedded.items.name,_embedded.items.type,_embedded.items.path,"
                  "_embedded.items.file,_embedded.items.size,_embedded.items.md5,_embedded.total"
    })
    url = f"{API}?{params}"
    return json.loads(fetch_with_retry(url, timeout=30))


def get_download_url(public_key, path):
    """Получает прямую ссылку на скачивание конкретного файла."""
    params = urllib.parse.urlencode({"public_key": public_key, "path": path})
    url = f"{API}/download?{params}"
    return json.loads(fetch_with_retry(url, timeout=30))["href"]


def download_file(public_key, item_path, dest_path, expected_size=None, expected_md5=None):
    """
    Скачивает файл с докачкой и проверкой размера и MD5.
    Возвращает:
      "success" - файл скачан и проверен
      "gone"    - сервер сообщил, что файла нет (400/404/410); кэшируется
      "failed"  - не удалось (сеть, диск, проверка); не кэшируется, повторится при следующем запуске
    """
    max_retries = 5
    last_error = None
    last_url = None

    os.makedirs(os.path.dirname(dest_path) or ".", exist_ok=True)

    for attempt in range(1, max_retries + 1):
        try:
            # Проверка уже готового файла по размеру и MD5
            if os.path.exists(dest_path):
                file_size = os.path.getsize(dest_path)
                if expected_size is not None and file_size == expected_size:
                    if not expected_md5:
                        return "success"
                    if calculate_md5(dest_path) == expected_md5:
                        return "success"

            dl_url = get_download_url(public_key, item_path)
            last_url = dl_url

            headers = {"User-Agent": "Mozilla/5.0"}
            mode = "wb"
            existing_size = 0

            if os.path.exists(dest_path) and expected_size is not None:
                existing_size = os.path.getsize(dest_path)
                if 0 < existing_size < expected_size:
                    headers["Range"] = f"bytes={existing_size}-"
                    mode = "ab"
                else:
                    existing_size = 0

            req = urllib.request.Request(dl_url, headers=headers)

            try:
                r = urllib.request.urlopen(req, timeout=60)
                status = r.status
            except urllib.error.HTTPError as e:
                if e.code == 416:  # Range не сошёлся
                    existing_size = 0
                    mode = "wb"
                    dl_url = get_download_url(public_key, item_path)
                    last_url = dl_url
                    req = urllib.request.Request(dl_url, headers={"User-Agent": "Mozilla/5.0"})
                    r = urllib.request.urlopen(req, timeout=60)
                    status = r.status
                else:
                    raise

            # Сервер проигнорировал Range и отдаёт файл целиком
            if status == 200 and mode == "ab":
                existing_size = 0
                mode = "wb"

            with r, open(dest_path, mode) as f:
                total = expected_size if expected_size is not None else int(r.headers.get("Content-Length", 0))
                downloaded = existing_size

                while True:
                    chunk = r.read(1024 * 256)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total:
                        pct = downloaded * 100 // total
                        mb = downloaded / 1024 / 1024
                        print(f"\r  {pct}% ({mb:.1f} MB)", end="", flush=True)
            print()

            # Проверка итогового размера
            actual_size = os.path.getsize(dest_path)
            if expected_size is not None and actual_size != expected_size:
                if actual_size > expected_size:
                    os.remove(dest_path)  # битый хвост, докачка не поможет
                # если меньше - файл остаётся, следующая попытка докачает через Range
                raise RetryableError(
                    f"Размер не совпадает: ожидался {expected_size}, получен {actual_size}")

            # Финальная проверка MD5
            if expected_md5:
                actual_md5 = calculate_md5(dest_path)
                if actual_md5 != expected_md5:
                    os.remove(dest_path)  # докачка битого файла бессмысленна
                    raise RetryableError(
                        f"MD5 не совпадает: ожидался {expected_md5}, получен {actual_md5}")

            return "success"

        except urllib.error.HTTPError as e:
            last_error = e
            if e.code in (400, 404, 410):
                print(f"\n  ОШИБКА: Сервер вернул HTTP {e.code}. Файл помечен как недоступный (gone).")
                log_problem(f"Файл недоступен (HTTP {e.code})", item_path, last_url, e)
                return "gone"

            wait = (5 * attempt) + random.uniform(2.0, 5.0)
            print(f"\n  ошибка HTTP ({e.code}), попытка {attempt}/{max_retries} через {wait:.1f}с...")
            if attempt < max_retries:
                time.sleep(wait)

        except RETRY_ERRORS as e:
            last_error = e
            wait = 5 * attempt + random.uniform(1.0, 3.0)
            print(f"\n  ошибка ({e}), попытка {attempt}/{max_retries} через {wait:.1f}с...")
            if attempt < max_retries:
                time.sleep(wait)

        except Exception as e:
            # Локальные ошибки диска, записи и прочее: повторять бессмысленно
            print(f"\n  ОШИБКА: {e}")
            log_problem("Ошибка скачивания или проверки файла", item_path, last_url, e)
            return "failed"

    print("\n  ОШИБКА: Превышен лимит попыток для файла.")
    log_problem("Превышен лимит попыток скачивания", item_path, last_url, last_error)
    return "failed"


def list_all(public_key, path="/", counter=None):
    """Рекурсивно получает все файлы с пагинацией."""
    if counter is None:
        counter = [0]  # изменяемый объект: общий счётчик для всех уровней рекурсии

    offset = 0
    limit = 100
    files = []
    while True:
        data = get_items(public_key, path, offset, limit)
        emb = data.get("_embedded", {})
        items = emb.get("items", [])
        total = emb.get("total", 0)

        for item in items:
            if item["type"] == "file":
                files.append(item)
                counter[0] += 1
                if counter[0] % 50 == 0:
                    print(f"\r  Получено файлов: {counter[0]}", end="", flush=True)
            elif item["type"] == "dir":
                files.extend(list_all(public_key, item["path"], counter))

        offset += len(items)
        if offset >= total or not items:
            break
    return files


def load_cached_files(public_key):
    """Загружает кэш списка файлов, если он свежий."""
    cache_file = get_cache_filename(public_key)
    if not os.path.exists(cache_file):
        return None
    try:
        with open(cache_file, "r", encoding="utf-8") as f:
            cache_data = json.load(f)

        if time.time() - cache_data.get("timestamp", 0) < CACHE_TTL:
            print("Использую закэшированный список файлов для этой ссылки...")
            return cache_data.get("files")
    except Exception as e:
        print(f"Ошибка чтения кэша: {e}")
        log_problem("Ошибка чтения кэша", cache_file, details=e)
    return None


def save_cached_files(public_key, files):
    """Сохраняет список файлов в персональный кэш."""
    cache_file = get_cache_filename(public_key)
    try:
        cache_data = {
            "timestamp": time.time(),
            "files": files
        }
        with open(cache_file, "w", encoding="utf-8") as f:
            json.dump(cache_data, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"Не удалось сохранить кэш: {e}")
        log_problem("Ошибка сохранения кэша", cache_file, details=e)


def get_single_resource_meta(public_key):
    """Получает метаданные для одиночного файла по публичной ссылке."""
    params = urllib.parse.urlencode({"public_key": public_key})
    url = f"{API}?{params}"
    return json.loads(fetch_with_retry(url, timeout=30))


def main():
    if len(sys.argv) < 2:
        print("Использование: python yadisk_download.py <ссылка> [папка]")
        sys.exit(1)

    public_key = sys.argv[1]
    dest_dir = sys.argv[2] if len(sys.argv) > 2 else "downloaded"

    print(f"Журнал ошибок: {os.path.abspath(unavailable_log)}")

    # 1. Папка это или одиночный файл
    try:
        meta = get_single_resource_meta(public_key)
    except Exception as e:
        print(f"Ошибка получения метаданных ресурса: {e}")
        log_problem("Не удалось получить метаданные ресурса", url=public_key, details=e)
        sys.exit(1)

    # Одиночный файл
    if meta.get("type") == "file":
        file_name = meta.get("name", "file")
        dest_path = os.path.join(dest_dir, file_name)
        expected_size = meta.get("size")
        expected_md5 = meta.get("md5")

        print(f"Одиночный файл: {file_name}")
        print(f"Скачивание в -> {dest_path}")

        result = download_file(public_key, "/", dest_path, expected_size, expected_md5)
        if result == "success":
            print("\nГотово! Файл успешно скачан.")
        else:
            print(f"\nНе удалось скачать файл. Результат: {result}")
            sys.exit(1)
        return

    # 2. Папка: кэш и список файлов
    files = load_cached_files(public_key)

    if files is None:
        print("Получаю список файлов с Яндекс Диска ...")
        try:
            files = list_all(public_key)
            print(f"\r  Получено файлов: {len(files)}")
            for f in files:
                f.setdefault("status", "active")
            save_cached_files(public_key, files)
        except Exception as e:
            print(f"\nОшибка получения списка файлов: {e}")
            log_problem("Не удалось получить список файлов", url=public_key, details=e)
            sys.exit(1)

    if not files:
        print("Файлов не найдено.")
        return

    total_size = sum(f.get("size", 0) for f in files)
    print(f"Найдено файлов: {len(files)}, общий размер: {total_size/1024/1024:.1f} МБ\n")

    cache_updated = False
    stats = {"success": 0, "skipped": 0, "failed": 0, "gone": 0}

    # 3. Скачивание файлов
    for i, item in enumerate(files, 1):
        rel_path = item["path"].lstrip("/")

        # Ранее помеченные как gone пропускаем, не тратя запросы
        if item.get("status") == "gone":
            print(f"[{i}/{len(files)}] {rel_path} — пропущен (статус gone в кэше)")
            stats["gone"] += 1
            continue

        dest_path = os.path.join(dest_dir, rel_path)
        expected_size = item.get("size", -1)
        expected_md5 = item.get("md5")

        # -1 означает, что размер неизвестен
        if expected_size is not None and expected_size < 0:
            expected_size = None

        print(f"[{i}/{len(files)}] {rel_path}")

        # Проверка уже скачанного файла (размер + MD5)
        if os.path.exists(dest_path):
            if expected_size is not None and os.path.getsize(dest_path) == expected_size:
                if not expected_md5:
                    print("  пропускаю (размер совпадает)")
                    stats["skipped"] += 1
                    continue
                if calculate_md5(dest_path) == expected_md5:
                    print("  пропускаю (уже скачан и проверен)")
                    stats["skipped"] += 1
                    continue

        status = download_file(public_key, item["path"], dest_path, expected_size, expected_md5)

        if status == "gone":
            item["status"] = "gone"
            cache_updated = True
            stats["gone"] += 1
        elif status == "failed":
            stats["failed"] += 1
        else:
            stats["success"] += 1

        time.sleep(random.uniform(2.0, 4.0))

    # Обновляем кэш, если появились файлы со статусом gone
    if cache_updated:
        save_cached_files(public_key, files)

    print(f"\nГотово! Файлы сохранены в: {os.path.abspath(dest_dir)}")
    print(f"Скачано: {stats['success']} | пропущено: {stats['skipped']} | "
          f"gone: {stats['gone']} | ошибок: {stats['failed']}")
    print(f"Журнал ошибок: {os.path.abspath(unavailable_log)}")

    if stats["failed"]:
        sys.exit(1)


if __name__ == "__main__":
    main()