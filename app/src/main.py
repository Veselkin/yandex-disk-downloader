import asyncio
import json
import os
import threading
import flet as ft
import yadisk_core as core

APP_VERSION = "1.0.0"
WORKER_CHOICES = [1, 2, 3, 4, 5, 6, 8]
DEFAULT_WORKERS = 3
REFRESH = 0.3  # период обновления UI, сек
ANDROID_PUBLIC_DIR = "/storage/emulated/0/Download/yadisk"


# ---------- настройки (запоминание пути) ----------
def _settings_file():
    base = os.environ.get("FLET_APP_STORAGE_DATA")
    if base:
        return os.path.join(base, "settings.json")
    return os.path.join(os.path.expanduser("~"), ".yadisk_app.json")


def load_settings():
    try:
        with open(_settings_file(), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_settings(data):
    try:
        os.makedirs(os.path.dirname(_settings_file()), exist_ok=True)
        with open(_settings_file(), "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
    except OSError:
        pass


def default_dir(page: ft.Page) -> str:
    if page.platform.value == "android":
        return ANDROID_PUBLIC_DIR
    return os.path.join(os.path.expanduser("~"), "Downloads", "yadisk")


def check_writable(path):
    """None, если в папку можно писать, иначе текст ошибки."""
    try:
        os.makedirs(path, exist_ok=True)
        test = os.path.join(path, ".write_test")
        with open(test, "w") as f:
            f.write("1")
        os.remove(test)
        return None
    except OSError as e:
        return str(e)


def fmt_mb(b):
    return f"{b / 1024 / 1024:.1f} МБ"


def main(page: ft.Page):
    page.title = f"Yandex Disk downloader v{APP_VERSION}"
    page.padding = 16

    url = ft.TextField(label="Публичная ссылка")
    dest = ft.TextField(
        label="Папка назначения",
        value=load_settings().get("dest") or default_dir(page),
        expand=True,
    )
    btn = ft.Button(content="Скачать")
    clear_btn = ft.OutlinedButton(content="Очистить")
    workers_dd = ft.Dropdown(
        label="Потоки",
        width=110,
        value=str(DEFAULT_WORKERS),
        options=[ft.DropdownOption(key=str(n), text=str(n)) for n in WORKER_CHOICES],
    )
    spinner = ft.ProgressRing(width=18, height=18, stroke_width=2, visible=False)
    status = ft.Text("")
    total_bar = ft.ProgressBar(value=0, visible=False)
    total_text = ft.Text("", size=12)
    active_box = ft.Column(spacing=6)
    file_list = ft.ListView(spacing=2, expand=True)
    list_box = ft.Container(
        content=file_list,
        expand=True,
        padding=8,
        border=ft.Border.all(1, ft.Colors.OUTLINE_VARIANT),
        border_radius=6,
    )
    cancel_ev = threading.Event()

    # ---------- выбор папки ----------
    picker = ft.FilePicker()
    page.services.append(picker)

    async def pick_dir(_):
        cur = dest.value.strip()
        path = await picker.get_directory_path(
            dialog_title="Папка загрузки",
            initial_directory=cur if os.path.isdir(cur) else None,
        )
        if path:
            dest.value = path
            save_settings({"dest": path})
            page.update()

    pick_btn = ft.IconButton(
        icon=ft.Icons.FOLDER_OPEN, tooltip="Выбрать папку", on_click=pick_dir
    )

    def get_workers():
        """Читается из потока загрузки перед стартом каждого файла."""
        try:
            return int(workers_dd.value)
        except (TypeError, ValueError):
            return DEFAULT_WORKERS

    # Данные пишутся из рабочих потоков, UI читает их только в refresh()
    lock = threading.Lock()
    names, sizes, done = [], [], []
    active = set()
    acc = {"done": 0, "total": 0, "finished": 0}
    pending = {"files": None, "msg": None}
    active_ctrls = {}  # i -> (column, bar, label)

    def on_list(files):
        with lock:
            names[:] = [f["name"] for f in files]
            sizes[:] = [f["size"] for f in files]
            done[:] = [0] * len(files)
            active.clear()
            acc.update(done=0, total=sum(sizes), finished=0)
            pending["files"] = files

    def on_progress(i, d, t):
        with lock:
            acc["done"] += d - done[i]
            done[i] = d

    def on_state(i, state):
        with lock:
            if state == "start":
                active.add(i)
                return
            active.discard(i)
            if state in ("skip", "done"):
                acc["done"] += sizes[i] - done[i]
                done[i] = sizes[i]
            if state in ("skip", "done", "error"):
                acc["finished"] += 1

    def log(msg):
        with lock:
            pending["msg"] = msg

    def refresh():
        """Меняет контролы, но НЕ вызывает update. Вызывается только из ticker."""
        with lock:
            files, pending["files"] = pending["files"], None
            msg, pending["msg"] = pending["msg"], None
            act = {i: (done[i], sizes[i]) for i in active}
            d, t, fin = acc["done"], acc["total"], acc["finished"]
            n = len(sizes)

        if msg is not None:
            status.value = msg
        if files is not None:
            file_list.controls = [
                ft.Text(f"{f['name']}  ({fmt_mb(f['size'])})", size=12, selectable=True)
                for f in files
            ]
            spinner.visible = False
            total_bar.visible = True
            if msg is None:
                status.value = ""

        for i in list(active_ctrls):
            if i not in act:
                active_box.controls.remove(active_ctrls.pop(i)[0])
        for i, (dn, sz) in act.items():
            pct = min(dn / sz, 1) if sz else 0
            if i not in active_ctrls:
                bar = ft.ProgressBar(value=pct, expand=True)
                label = ft.Text("", size=12, width=50, text_align=ft.TextAlign.RIGHT)
                col = ft.Column(
                    [
                        ft.Text(f"{names[i]}  ({fmt_mb(sz)})", size=12, no_wrap=True),
                        ft.Row(
                            [bar, label],
                            vertical_alignment=ft.CrossAxisAlignment.CENTER,
                        ),
                    ],
                    spacing=2,
                )
                active_ctrls[i] = (col, bar, label)
                active_box.controls.append(col)
            _, bar, label = active_ctrls[i]
            bar.value = pct
            label.value = f"{pct * 100:.0f}%" if sz else ""

        if t:
            total_bar.value = min(d / t, 1)
            total_text.value = (
                f"Файлов: {fin} из {n}  ·  "
                f"{total_bar.value * 100:.0f}% ({fmt_mb(d)} из {fmt_mb(t)})"
            )

    async def ticker(stop: threading.Event):
        while not stop.is_set():
            refresh()
            page.update()
            await asyncio.sleep(REFRESH)

    async def run_download():
        stop = threading.Event()
        page.run_task(ticker, stop)
        try:
            await asyncio.to_thread(
                core.run,
                url.value.strip(),
                dest.value.strip(),
                log,
                on_list,
                on_progress,
                on_state,
                cancel_ev.is_set,
                get_workers,
            )
        finally:
            stop.set()
            refresh()
            btn.content = "Скачать"
            clear_btn.disabled = False
            pick_btn.disabled = False
            spinner.visible = False
            page.update()

    def on_click(_):
        if btn.content == "Отмена":
            cancel_ev.set()
            return
        if not url.value.strip():
            return

        path = dest.value.strip()
        err = check_writable(path)
        if err:
            msg = f"Нет доступа к папке «{path}»: {err}"
            if page.platform.value == "android":
                msg += ". Включите приложению «Доступ ко всем файлам» в настройках Android."
            status.value = msg
            page.update()
            return
        save_settings({"dest": path})

        cancel_ev.clear()
        file_list.controls.clear()
        active_box.controls.clear()
        active_ctrls.clear()
        btn.content = "Отмена"
        clear_btn.disabled = True
        pick_btn.disabled = True
        status.value = "Получаю список файлов..."
        total_text.value = ""
        spinner.visible = True
        total_bar.visible = False
        page.update()
        page.run_task(run_download)

    def on_clear(_):
        if btn.content == "Отмена":  # во время закачки не очищаем
            return
        url.value = ""
        file_list.controls.clear()
        active_box.controls.clear()
        active_ctrls.clear()
        with lock:
            names.clear()
            sizes.clear()
            done.clear()
            active.clear()
            acc.update(done=0, total=0, finished=0)
            pending.update(files=None, msg=None)
        status.value = ""
        total_text.value = ""
        total_bar.value = 0
        total_bar.visible = False
        page.update()

    btn.on_click = on_click
    clear_btn.on_click = on_clear

    root = ft.Column(
        [
            ft.Container(height=12),  # доп. отступ сверху
            url,
            ft.Row([dest, pick_btn], vertical_alignment=ft.CrossAxisAlignment.CENTER),
            ft.Row(
                [btn, clear_btn, workers_dd],
                wrap=True,
                spacing=10,
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            ft.Row([spinner, status], vertical_alignment=ft.CrossAxisAlignment.CENTER),
            total_bar,
            total_text,
            active_box,
            list_box,
        ],
        expand=True,
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )

    def apply_layout(_=None):
        """Портрет: список занимает остаток экрана. Ландшафт: страница прокручивается."""
        w, h = page.width or 0, page.height or 0
        if w > h > 0:
            list_box.expand = False
            list_box.height = max(240, h * 0.85)
            list_box.margin = ft.Margin.only(right=56)  # полоса для прокрутки страницы
            root.scroll = ft.ScrollMode.AUTO
        else:
            list_box.expand = True
            list_box.height = None
            list_box.margin = 0
            root.scroll = None
        page.update()

    page.add(ft.SafeArea(expand=True, content=root))
    page.on_resize = apply_layout
    apply_layout()

ft.run(main)
