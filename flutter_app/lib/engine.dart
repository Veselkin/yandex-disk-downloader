// Модель загрузки + сохранение задачи на диск. Не зависит от Flutter,
// поэтому работает и в основном изоляте (десктоп), и в изоляте foreground-сервиса (Android).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'yadisk_core.dart' as core;

/// Последняя пауза, назначенная Яндексом (429). Хранится в задаче,
/// поэтому переживает перезапуск приложения.
class RateInfo {
  final int until; // epoch ms, когда закончится пауза (0 — не было)
  final int wait; // длина последней паузы, сек
  final int at; // epoch ms, когда получили последний 429
  final bool fromServer; // пауза указана Яндексом (Retry-After)
  const RateInfo({
    this.until = 0,
    this.wait = 0,
    this.at = 0,
    this.fromServer = false,
  });

  Map<String, dynamic> toJson() => {
    'until': until,
    'wait': wait,
    'at': at,
    'fromServer': fromServer,
  };

  factory RateInfo.fromJson(Map<String, dynamic> j) => RateInfo(
    until: (j['until'] as int?) ?? 0,
    wait: (j['wait'] as int?) ?? 0,
    at: (j['at'] as int?) ?? 0,
    fromServer: (j['fromServer'] as bool?) ?? false,
  );
}

class TaskData {
  final String url;
  final String dest;
  final List<core.RemoteFile> files;
  final RateInfo rate;
  const TaskData(
    this.url,
    this.dest,
    this.files, [
    this.rate = const RateInfo(),
  ]);
}

TaskData? loadTaskSync(String path) {
  try {
    final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final files = [
      for (final e in (j['files'] as List))
        core.RemoteFile(
          e[0] as String,
          e[1] as String,
          e[2] as int,
          e.length > 3 ? (e[3] as String) : '',
        ),
    ];
    final rj = j['rate'];
    return TaskData(
      j['url'] as String,
      j['dest'] as String,
      files,
      rj is Map
          ? RateInfo.fromJson(rj.cast<String, dynamic>())
          : const RateInfo(),
    );
  } catch (_) {
    return null;
  }
}

void saveTaskSync(
  String path,
  String url,
  String dest,
  List<core.RemoteFile> files, {
  RateInfo rate = const RateInfo(),
}) {
  final tmp = File('$path.tmp');
  tmp.parent.createSync(recursive: true);
  tmp.writeAsStringSync(
    jsonEncode({
      'url': url,
      'dest': dest,
      'files': [
        for (final f in files) [f.name, f.path, f.size, f.md5],
      ],
      'rate': rate.toJson(),
    }),
  );
  final target = File(path);
  if (target.existsSync()) target.deleteSync();
  tmp.renameSync(path);
}

void deleteTaskSync(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

class Engine {
  Engine(this.taskFile);

  final String taskFile;

  String _url = '';
  String _dest = '';
  RateInfo rate = const RateInfo();

  List<core.RemoteFile> files = [];
  List<int> _done = [];
  List<int> _total = [];
  final Set<int> _active = {};
  int accDone = 0, accTotal = 0, finished = 0, failed = 0;
  int listVersion = 0;
  String status = '';
  String _lastError = '';
  bool running = false;
  bool _cancel = false;
  Completer<void> _cancelSignal = Completer<void>();

  /// Отмена срабатывает сразу: обрываются соединения и ожидания (в т.ч. паузу 429).
  void cancel() {
    if (!running || _cancel) return;
    _cancel = true;
    status = 'Отмена...';
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
  }

  void _reset() {
    files = [];
    _done = [];
    _total = [];
    _active.clear();
    accDone = accTotal = finished = failed = 0;
    _lastError = '';
  }

  void _save() {
    if (files.isEmpty) return;
    saveTaskSync(taskFile, _url, _dest, files, rate: rate);
  }

  /// [resume]: взять список файлов и состояние паузы из сохранённой задачи
  /// (без запроса к API). Уже скачанное определяется по файлам на диске.
  Future<void> start(String url, String dest, {bool resume = false}) async {
    if (running) return;
    running = true;
    _cancel = false;
    _cancelSignal = Completer<void>();
    _reset();
    rate = const RateInfo();
    _url = url;
    _dest = dest;
    status = 'Получаю список файлов...';

    core.rateLimitHook = (until, sec, fromServer) {
      rate = RateInfo(
        until: until.millisecondsSinceEpoch,
        wait: sec,
        at: DateTime.now().millisecondsSinceEpoch,
        fromServer: fromServer,
      );
      try {
        _save(); // пауза запоминается сразу
      } catch (_) {}
    };

    List<core.RemoteFile>? restored;
    if (resume) {
      final t = loadTaskSync(taskFile);
      if (t != null) {
        restored = t.files;
        _url = t.url;
        _dest = t.dest;
        rate = t.rate;
        if (rate.until > DateTime.now().millisecondsSinceEpoch) {
          // пауза Яндекса ещё не кончилась — досиживаем остаток
          core.restoreCooldown(DateTime.fromMillisecondsSinceEpoch(rate.until));
        }
      }
    }

    void onList(List<core.RemoteFile> f) {
      files = f;
      _done = List.filled(f.length, 0);
      _total = [for (final x in f) x.size];
      _active.clear();
      accDone = 0;
      accTotal = _total.fold(0, (a, b) => a + b);
      finished = failed = 0;
      status = '';
      // список запоминаем сразу — до завершения скачивания
      if (restored == null) _save();
      listVersion++;
    }

    void onProgress(int i, int d, int t) {
      if (t > 0 && t != _total[i]) {
        accTotal += t - _total[i];
        _total[i] = t;
      }
      accDone += d - _done[i];
      _done[i] = d;
    }

    void onState(int i, String s) {
      if (s == 'start') {
        _active.add(i);
        return;
      }
      _active.remove(i);
      if (s == 'skip' || s == 'done') {
        accDone += _total[i] - _done[i];
        _done[i] = _total[i];
      }
      if (s == 'error') failed++;
      if (s == 'skip' || s == 'done' || s == 'error') finished++;
    }

    void log(String msg) {
      status = msg;
      if (msg.startsWith('Ошибка')) _lastError = msg;
    }

    try {
      await core.run(
        _url,
        _dest,
        files: restored,
        log: log,
        onList: onList,
        onProgress: onProgress,
        onState: onState,
        cancel: () => _cancel,
        cancelSignal: _cancelSignal.future,
      );
    } catch (e) {
      status = 'Ошибка: $e';
    } finally {
      core.rateLimitHook = null;
      running = false;
      _active.clear();
      if (!_cancel && files.isNotEmpty) {
        if (failed == 0 && finished == files.length) {
          deleteTaskSync(taskFile); // всё скачано — задачу забываем
        } else {
          status =
              'Скачано $finished из ${files.length}. '
              '${_lastError.isEmpty ? '' : '$_lastError. '}'
              'Нажмите «Продолжить», чтобы повторить.';
        }
      }
    }
  }

  /// Компактный снимок для UI / уведомления.
  Map<String, dynamic> snapshot() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'running': running,
      'status': status,
      'n': files.length,
      'accDone': accDone,
      'accTotal': accTotal,
      'finished': finished,
      'lv': listVersion,
      // пауза активна, только пока не истекла
      'pauseUntil': running && rate.until > now ? rate.until : 0,
      'lastWait': rate.wait,
      'lastWaitAt': rate.at,
      'waitServer': rate.fromServer,
      'active': [
        for (final i in _active) ...[i, _done[i], _total[i]],
      ],
    };
  }
}
