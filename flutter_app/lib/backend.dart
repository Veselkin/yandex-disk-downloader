import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'engine.dart';

String fmtMb(int b) => '${(b / 1024 / 1024).toStringAsFixed(1)} МБ';

String _pad2(int v) => v.toString().padLeft(2, '0');

/// Длительность: 05:07 или 1:05:07.
String fmtDur(int sec) {
  if (sec < 0) sec = 0;
  final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
  return h > 0 ? '$h:${_pad2(m)}:${_pad2(s)}' : '${_pad2(m)}:${_pad2(s)}';
}

/// Время суток: 14:05:32.
String fmtClock(DateTime t) =>
    '${_pad2(t.hour)}:${_pad2(t.minute)}:${_pad2(t.second)}';

/// Снимок состояния загрузки для UI.
class Snapshot {
  final bool running;
  final String status;
  final int n, accDone, accTotal, finished, lv;
  final int pauseUntil; // epoch ms; 0 — пауза Яндекса не активна
  final int lastWait; // последняя пауза от Яндекса, сек (0 — не было)
  final int lastWaitAt; // epoch ms получения последнего 429
  final bool waitFromServer; // пауза указана самим Яндексом
  final Map<int, ({int done, int total})>
  active; // индекс файла -> (скачано, всего; 0 = неизвестно)

  const Snapshot({
    this.running = false,
    this.status = '',
    this.n = 0,
    this.accDone = 0,
    this.accTotal = 0,
    this.finished = 0,
    this.lv = 0,
    this.pauseUntil = 0,
    this.lastWait = 0,
    this.lastWaitAt = 0,
    this.waitFromServer = false,
    this.active = const {},
  });

  factory Snapshot.fromMap(Map m) {
    final a = (m['active'] as List).cast<int>();
    return Snapshot(
      running: m['running'] as bool,
      status: m['status'] as String,
      n: m['n'] as int,
      accDone: m['accDone'] as int,
      accTotal: m['accTotal'] as int,
      finished: m['finished'] as int,
      lv: m['lv'] as int,
      pauseUntil: (m['pauseUntil'] as int?) ?? 0,
      lastWait: (m['lastWait'] as int?) ?? 0,
      lastWaitAt: (m['lastWaitAt'] as int?) ?? 0,
      waitFromServer: (m['waitServer'] as bool?) ?? false,
      active: {
        for (var i = 0; i + 2 < a.length; i += 3)
          a[i]: (done: a[i + 1], total: a[i + 2]),
      },
    );
  }
}

abstract class Backend {
  final ValueNotifier<Snapshot> snap = ValueNotifier(const Snapshot());
  Future<void> init();
  Future<void> start(String url, String dest, {required bool resume});
  void cancel();
  void dispose() => snap.dispose();
}

// ======================= Desktop: движок в основном изоляте =======================
class LocalBackend extends Backend {
  LocalBackend(String taskFile) : engine = Engine(taskFile);
  final Engine engine;
  Timer? _t;

  void _push() => snap.value = Snapshot.fromMap(engine.snapshot());

  @override
  Future<void> init() async {}

  @override
  Future<void> start(String url, String dest, {required bool resume}) async {
    _t = Timer.periodic(const Duration(milliseconds: 300), (_) => _push());
    try {
      await engine.start(url, dest, resume: resume);
    } finally {
      _t?.cancel();
      _push();
    }
  }

  @override
  void cancel() => engine.cancel();
}

// ======================= Android: foreground-сервис =======================
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(DownloadTaskHandler());
}

/// Работает в изоляте сервиса: переживает закрытие приложения из «недавних».
class DownloadTaskHandler extends TaskHandler {
  Engine? _engine;
  int _tick = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final raw = await FlutterForegroundTask.getData<String>(key: 'job');
    if (raw == null) {
      await FlutterForegroundTask.stopService();
      return;
    }
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final e = Engine(j['taskFile'] as String);
    _engine = e;
    unawaited(_run(e, j));
  }

  Future<void> _run(Engine e, Map<String, dynamic> j) async {
    await e.start(
      j['url'] as String,
      j['dest'] as String,
      resume: j['resume'] as bool,
    );
    FlutterForegroundTask.sendDataToMain(e.snapshot());
    await FlutterForegroundTask.stopService();
  }

  void _notify(Engine e) {
    final s = e.snapshot();
    final n = s['n'] as int;
    final total = s['accTotal'] as int;
    final done = s['accDone'] as int;
    final pauseUntil = s['pauseUntil'] as int;
    final left = pauseUntil - DateTime.now().millisecondsSinceEpoch;
    final String text;
    if (left > 0) {
      text =
          'Яндекс на паузе, ожидаем: ещё ${fmtDur((left / 1000).ceil())}'
          '${n > 0 ? ' · файлов: ${s['finished']} из $n' : ''}';
    } else if (n == 0) {
      text = (s['status'] as String).isEmpty
          ? 'Подготовка...'
          : s['status'] as String;
    } else {
      final pct = total > 0 ? (done * 100 / total).toStringAsFixed(0) : '0';
      text =
          'Файлов: ${s['finished']} из $n · $pct% (${fmtMb(done)} из ${fmtMb(total)})';
    }
    FlutterForegroundTask.updateService(
      notificationTitle: 'Yandex Disk downloader',
      notificationText: text,
    );
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    final e = _engine;
    if (e == null) return;
    FlutterForegroundTask.sendDataToMain(e.snapshot());
    if (++_tick % 2 == 0) _notify(e); // уведомление раз в секунду
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    if (data['cmd'] == 'cancel') _engine?.cancel();
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'cancel') _engine?.cancel();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _engine?.cancel(); // .part-файлы и task.json остаются, загрузку можно продолжить
  }
}

class AndroidBackend extends Backend {
  AndroidBackend(this.taskFile);
  final String taskFile;

  void _onData(Object data) {
    if (data is Map) snap.value = Snapshot.fromMap(data);
  }

  @override
  Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'yadisk_download',
        channelName: 'Загрузка файлов',
        channelDescription: 'Статус загрузки с Яндекс Диска',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(500),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onData);
    // приложение открыли заново, а сервис ещё качает
    if (await FlutterForegroundTask.isRunningService) {
      snap.value = const Snapshot(
        running: true,
        status: 'Подключаюсь к загрузке...',
      );
    }
  }

  @override
  Future<void> start(String url, String dest, {required bool resume}) async {
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    await FlutterForegroundTask.saveData(
      key: 'job',
      value: jsonEncode({
        'url': url,
        'dest': dest,
        'resume': resume,
        'taskFile': taskFile,
      }),
    );
    snap.value = const Snapshot(
      running: true,
      status: 'Получаю список файлов...',
    );
    final res = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Yandex Disk downloader',
      notificationText: 'Подготовка...',
      notificationButtons: [
        const NotificationButton(id: 'cancel', text: 'Отмена'),
      ],
      callback: startCallback,
    );
    if (res is ServiceRequestFailure) {
      snap.value = Snapshot(
        running: false,
        status: 'Не удалось запустить сервис: ${res.error}',
      );
    }
  }

  @override
  void cancel() => FlutterForegroundTask.sendDataToTask({'cmd': 'cancel'});

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    super.dispose();
  }
}
