#!/usr/bin/env python3
"""
Скачивание публичных ссылок с Яндекс Диска без авторизации.
"""

import sys
import os
import json
import urllib.request
import urllib.parse
import urllib.error
import socket
import time
import threading
import http.client

API = "https://cloud-api.yandex.net/v1/disk/public/resources"
API_QPS = 20  # общий потолок запросов к API в секунду на все потоки (лимит Яндекса ~40)
_rl_lock = threading.Lock()
_rl_next = 0.0

# все сетевые сбои: обрыв, сброс, неполный ответ, SSL, таймауты, URLError
NET_ERRORS = (OSError, http.client.HTTPException)


def _throttle():
    """Общий для всех потоков ограничитель частоты запросов к API."""
    global _rl_next
    with _rl_lock:
        now = time.monotonic()
        wait = _rl_next - now
        _rl_next = max(now, _rl_next) + 1 / API_QPS
    if wait > 0:
        time.sleep(wait)


def fetch_with_retry(url, timeout=30, retries=5, backoff=3):
    last_err = None
    for attempt in range(1, retries + 1):
        _throttle()
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504):
                raise  # 404, 403 и т.п. повторять бессмысленно
            last_err = e
            wait = int(e.headers.get("Retry-After") or 0) or backoff * attempt
        except NET_ERRORS as e:
            last_err = e
            wait = backoff * attempt
        time.sleep(wait)
    raise last_err


def get_items(public_key, path="/", offset=0, limit=100):
    params = urllib.parse.urlencode(
        {
            "public_key": public_key,
            "path": path,
            "offset": offset,
            "limit": limit,
            "fields": "_embedded.items.name,_embedded.items.type,_embedded.items.path,"
            "_embedded.items.file,_embedded.items.size,_embedded.total",
        }
    )
    url = f"{API}?{params}"
    return json.loads(fetch_with_retry(url, timeout=30))


def get_download_url(public_key, path):
    params = urllib.parse.urlencode({"public_key": public_key, "path": path})
    url = f"{API}/download?{params}"
    return json.loads(fetch_with_retry(url, timeout=30))["href"]


def get_meta(public_key):
    params = urllib.parse.urlencode(
        {"public_key": public_key, "fields": "name,size,type"}
    )
    return json.loads(fetch_with_retry(f"{API}?{params}", timeout=30))


def download_file(
    url, dest_path, size=0, on_progress=None, cancel=lambda: False, retries=5
):
    """url - строка или функция, возвращающая свежую ссылку (вызывается при каждой попытке)."""
    get_url = url if callable(url) else (lambda: url)
    os.makedirs(os.path.dirname(dest_path) or ".", exist_ok=True)
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(
                get_url(), headers={"User-Agent": "Mozilla/5.0"}
            )
            with urllib.request.urlopen(req, timeout=60) as r, open(
                dest_path, "wb"
            ) as f:
                total = int(r.headers.get("Content-Length", 0)) or size
                done = 0
                while chunk := r.read(1024 * 256):
                    if cancel():
                        raise InterruptedError("cancelled")
                    f.write(chunk)
                    done += len(chunk)
                    if on_progress:
                        on_progress(done, total)
            return
        except InterruptedError:
            if os.path.exists(dest_path):
                os.remove(dest_path)  # не оставляем битый файл
            raise
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504):
                raise
            last_err = e
        except NET_ERRORS as e:
            last_err = e
        if cancel():
            raise InterruptedError("cancelled")
        time.sleep(min(3 * attempt, 15))
    if os.path.exists(dest_path):
        os.remove(dest_path)
    raise last_err


def list_all(public_key, path="/"):
    """Рекурсивно получить все файлы."""
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
            elif item["type"] == "dir":
                files.extend(list_all(public_key, item["path"]))
        offset += len(items)
        if offset >= total:
            break
    return files


def run(
    public_key,
    dest_dir,
    log=print,
    on_list=None,
    on_progress=None,
    on_state=None,
    cancel=lambda: False,
    workers=3,
):
    """
    workers - число потоков: int или функция без аргументов (читается
              перед стартом каждого нового файла, можно менять на лету)
    on_list(files)              - список [{"name","path","size"}] получен
    on_progress(i, done, total) - прогресс файла i в байтах
    on_state(i, state)          - "start" | "skip" | "done" | "error" | "cancel"
    """
    get_workers = workers if callable(workers) else (lambda: workers)

    log("Получаю список файлов...")
    try:
        files = [
            {
                "name": it["path"].lstrip("/"),
                "path": it["path"],
                "size": it.get("size", 0),
            }
            for it in list_all(public_key)
        ]
        if not files:  # одиночный файл
            meta = get_meta(public_key)
            if meta.get("type") != "file":
                log("Папка пуста")
                return
            files = [
                {
                    "name": meta.get("name", "file"),
                    "path": "/",
                    "size": meta.get("size", 0),
                }
            ]
    except Exception as e:
        log(f"Ошибка API: {e}")
        return

    if on_list:
        on_list(files)

    def state(i, s):
        if on_state:
            on_state(i, s)

    cond = threading.Condition()
    running = [0]

    def job(i, f, dest):
        try:
            state(i, "start")
            download_file(
                lambda: get_download_url(
                    public_key, f["path"]
                ),  # свежая ссылка на каждой попытке
                dest,
                f["size"],
                (lambda d, t, i=i: on_progress(i, d, t)) if on_progress else None,
                cancel,
            )
            state(i, "done")
        except InterruptedError:
            state(i, "cancel")
        except Exception as e:
            state(i, "error")
            log(f"Ошибка: {f['name']}: {type(e).__name__}: {e}")
        finally:
            with cond:
                running[0] -= 1
                cond.notify_all()

    for i, f in enumerate(files):
        if cancel():
            break
        dest = os.path.join(dest_dir, f["name"])
        # проверка на диске: без потока и без запросов к API
        if os.path.exists(dest) and os.path.getsize(dest) == f["size"]:
            state(i, "skip")
            continue
        with cond:
            # ждём свободный слот; лимит перечитывается каждые 0.3 с
            while running[0] >= max(1, get_workers()) and not cancel():
                cond.wait(0.3)
            if cancel():
                break
            running[0] += 1
        threading.Thread(target=job, args=(i, f, dest), daemon=True).start()

    with cond:  # дождаться завершения активных закачек
        while running[0] > 0:
            cond.wait(0.3)

    log("Отменено" if cancel() else f"Готово: {os.path.abspath(dest_dir)}")


if __name__ == "__main__":  # CLI остаётся рабочим
    if len(sys.argv) < 2:
        sys.exit("Использование: python yadisk_core.py <ссылка> [папка]")
    run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "downloaded")
