import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backend.dart';
import 'engine.dart';
import 'yadisk_core.dart' as core;

const appVersion = '1.2.0';
const androidPublicDir = '/storage/emulated/0/Download/yadisk';

String defaultDir() {
  if (Platform.isAndroid) return androidPublicDir;
  final home =
      Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '.';
  return p.join(home, 'Downloads', 'yadisk');
}

/// null, если в папку можно писать, иначе текст ошибки.
Future<String?> checkWritable(String path) async {
  try {
    await Directory(path).create(recursive: true);
    final t = File(p.join(path, '.write_test'));
    await t.writeAsString('1');
    await t.delete();
    return null;
  } on FileSystemException catch (e) {
    return e.message + (e.osError != null ? ' (${e.osError!.message})' : '');
  }
}

void main() {
  // канал связи UI <-> foreground-сервис
  if (Platform.isAndroid) FlutterForegroundTask.initCommunicationPort();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Yandex Disk downloader',
    theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.blue,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _url = TextEditingController();
  final _dest = TextEditingController(text: defaultDir());

  Backend? _backend;
  late String _taskFile;
  TaskData? _task; // сохранённый список файлов (имена/размеры для UI)
  int _lv = -1;
  String _localStatus = ''; // ошибки доступа к папке и т.п.

  Snapshot get _s => _backend?.snap.value ?? const Snapshot();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final d = prefs.getString('dest');
    if (d != null && d.isNotEmpty) _dest.text = d;

    final dir = await getApplicationSupportDirectory();
    _taskFile = p.join(dir.path, 'task.json');
    final b = Platform.isAndroid
        ? AndroidBackend(_taskFile)
        : LocalBackend(_taskFile);
    await b.init();
    b.snap.addListener(_onSnap);
    _backend = b;

    // незавершённая загрузка с прошлого запуска
    final t = loadTaskSync(_taskFile);
    if (t != null) {
      _task = t;
      _url.text = t.url;
      _dest.text = t.dest;
      if (!b.snap.value.running) {
        final done = core.scanLocal(t.dest, t.files);
        final total = t.files.fold<int>(0, (a, f) => a + f.size);
        var fin = 0;
        for (var i = 0; i < t.files.length; i++) {
          final f = t.files[i];
          if (done[i] >= f.size &&
              File(core.destPathOf(t.dest, f)).existsSync()) {
            fin++;
          }
        }
        b.snap.value = Snapshot(
          n: t.files.length,
          accTotal: total,
          accDone: done.fold(0, (a, b) => a + b),
          finished: fin,
          lv: b.snap.value.lv,
          lastWait: t.rate.wait,
          lastWaitAt: t.rate.at,
          waitFromServer: t.rate.fromServer,
          status: 'Найдена незавершённая загрузка. Нажмите «Продолжить».',
        );
      }
    }
    if (mounted) setState(() {});
  }

  void _onSnap() {
    final s = _s;
    if (s.lv != _lv && s.running) {
      _lv = s.lv;
      _task = loadTaskSync(
        _taskFile,
      ); // список обновился (сервис мог записать его сам)
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _backend?.snap.removeListener(_onSnap);
    _backend?.dispose();
    _url.dispose();
    _dest.dispose();
    super.dispose();
  }

  Future<void> _saveDest(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dest', path);
  }

  Future<void> _pickDir() async {
    final cur = _dest.text.trim();
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Папка загрузки',
      initialDirectory: Directory(cur).existsSync() ? cur : null,
    );
    if (path != null) {
      setState(() => _dest.text = path);
      await _saveDest(path);
    }
  }

  bool get _canResume {
    final t = _task;
    if (t == null || _s.running) return false;
    return _s.finished < t.files.length &&
        _url.text.trim() == t.url &&
        _dest.text.trim() == t.dest;
  }

  Future<void> _onMain() async {
    final b = _backend;
    if (b == null) return;
    if (_s.running) {
      b.cancel();
      return;
    }
    final link = _url.text.trim();
    if (link.isEmpty) return;

    final path = _dest.text.trim();
    var err = await checkWritable(path);
    if (err != null && Platform.isAndroid) {
      await Permission.manageExternalStorage.request();
      err = await checkWritable(path);
    }
    if (err != null) {
      var msg = 'Нет доступа к папке «$path»: $err';
      if (Platform.isAndroid) {
        msg += '. Включите приложению «Доступ ко всем файлам» в настройках Android.';
      }
      setState(() => _localStatus = msg);
      return;
    }
    await _saveDest(path);
    final resume = _canResume;
    setState(() {
      _localStatus = '';
      if (!resume) {
        _task = null; // новая задача — старый список не показываем
        _lv = -1;
      }
    });
    await b.start(link, path, resume: resume);
  }

  void _onClear() {
    if (_s.running) return;
    deleteTaskSync(_taskFile);
    _backend?.snap.value = const Snapshot();
    setState(() {
      _task = null;
      _lv = -1;
      _url.clear();
      _localStatus = '';
    });
  }

  /// Пауза Яндекса (429) — это ожидание, а не ошибка.
  Widget _rateInfo(Snapshot s) {
    final now = DateTime.now();
    final until = s.pauseUntil > 0
        ? DateTime.fromMillisecondsSinceEpoch(s.pauseUntil)
        : null;
    final paused = s.running && until != null && until.isAfter(now);
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[];

    if (paused) {
      final left = until.difference(now).inSeconds + 1;
      children.add(
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.hourglass_top, color: scheme.onTertiaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Яндекс поставил загрузку на паузу — ожидаем.\n'
                  'Продолжу в ${fmtClock(until)} (через ${fmtDur(left)})',
                  style: TextStyle(color: scheme.onTertiaryContainer),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (s.lastWait > 0) {
      final at = DateTime.fromMillisecondsSinceEpoch(s.lastWaitAt);
      children.add(
        Padding(
          padding: EdgeInsets.only(top: paused ? 6 : 0),
          child: Text(
            'Последний таймаут Яндекса: ${fmtDur(s.lastWait)} '
            '(получен в ${fmtClock(at)}, '
            '${s.waitFromServer ? 'указан Яндексом' : 'Яндекс не указал, выбран автоматически'})',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _activeTile(int i, int done, int total) {
    final f = _task!.files[i];
    final size = total > 0 ? total : f.size;
    final known = size > 0;
    final pct = known ? (done / size).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            known ? '${f.name}  (${fmtMb(size)})' : f.name,
            style: const TextStyle(fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(child: LinearProgressIndicator(value: pct)),
              SizedBox(
                width: 70,
                child: Text(
                  known ? '${(pct! * 100).toStringAsFixed(0)}%' : fmtMb(done),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final running = s.running;
    final files = _task?.files ?? const <core.RemoteFile>[];
    final n = files.length;
    final totalPct = s.accTotal > 0
        ? (s.accDone / s.accTotal).clamp(0.0, 1.0)
        : 0.0;
    final border = Theme.of(context).colorScheme.outlineVariant;
    final status = _localStatus.isNotEmpty ? _localStatus : s.status;
    final mainLabel = running
        ? 'Отмена'
        : (_canResume ? 'Продолжить' : 'Скачать');

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    TextField(
                      controller: _url,
                      enabled: !running,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Публичная ссылка',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _dest,
                            enabled: !running,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Папка назначения',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.folder_open),
                          tooltip: 'Выбрать папку',
                          onPressed: running ? null : _pickDir,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton(
                          onPressed: _onMain,
                          child: Text(mainLabel),
                        ),
                        OutlinedButton(
                          onPressed: running ? null : _onClear,
                          child: const Text('Очистить'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (running && s.n == 0) ...[
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(child: Text(status)),
                      ],
                    ),
                    _rateInfo(s),
                    if (n > 0) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: totalPct),
                      const SizedBox(height: 4),
                      Text(
                        'Файлов: ${s.finished} из $n  ·  '
                        '${(totalPct * 100).toStringAsFixed(0)}% '
                        '(${fmtMb(s.accDone)} из ${fmtMb(s.accTotal)})',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      for (final e
                          in (s.active.entries.toList()
                            ..sort((a, b) => a.key.compareTo(b.key))))
                        if (e.key < n)
                          _activeTile(e.key, e.value.done, e.value.total),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
              SliverList.builder(
                itemCount: n,
                itemBuilder: (_, i) => Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: border),
                      right: BorderSide(color: border),
                      top: i == 0 ? BorderSide(color: border) : BorderSide.none,
                      bottom: i == n - 1
                          ? BorderSide(color: border)
                          : BorderSide.none,
                    ),
                  ),
                  child: SelectableText(
                    files[i].size > 0
                        ? '${files[i].name}  (${fmtMb(files[i].size)})'
                        : files[i].name,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
