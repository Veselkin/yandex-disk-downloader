// Скачивание публичных ссылок Яндекс Диска без авторизации.
// Логика и тайминги соответствуют эталону yadisk_download.py.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show md5;
import 'package:path/path.dart' as p;

const _api = 'https://cloud-api.yandex.net/v1/disk/public/resources';

// --- тайминги эталона ---
const _retries = 8;
const _backoff = 5;
const _dlRetries = 5;
const _apiTimeout = Duration(seconds: 30);
const _dlTimeout = Duration(seconds: 60);
const _fatalCodes = {400, 404, 410, 500};

final HttpClient _client = HttpClient()
  ..connectionTimeout = _apiTimeout
  ..autoUncompress = false
  ..userAgent = 'Mozilla/5.0';

Future<HttpClientRequest> _open(Uri u) async {
  final req = await _client.getUrl(u);
  req.persistentConnection = false;
  req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  return req;
}

final _rnd = Random();

double _jit(double a, double b) => a + _rnd.nextDouble() * (b - a);
Duration _secs(double s) => Duration(milliseconds: (s * 1000).round());

class RemoteFile {
  final String name;
  final String path;
  final int size;
  final String md5;
  const RemoteFile(this.name, this.path, this.size, [this.md5 = '']);
}

class CancelledException implements Exception {
  @override
  String toString() => 'cancelled';
}

class HttpStatusException implements Exception {
  final int code;
  final String? msg;
  const HttpStatusException(this.code, [this.msg]);
  @override
  String toString() => 'HTTP $code${msg == null ? '' : ': $msg'}';
}

typedef CancelFn = bool Function();

({String key, String path}) splitPublicUrl(String s) {
  final src = s.trim();
  final m = RegExp(r'^(https?://[^/]+/[di]/[^/?#]+)(/[^?#]*)?').firstMatch(src);
  if (m == null) return (key: src, path: '/');
  var sub = (m.group(2) ?? '').replaceFirst(RegExp(r'/+$'), '');
  if (sub.isEmpty) return (key: m.group(1)!, path: '/');
  try {
    sub = Uri.decodeComponent(sub);
  } catch (_) {}
  return (key: m.group(1)!, path: sub);
}

String _relName(String base, String full) {
  var f = full;
  if (base != '/' && (f == base || f.startsWith('$base/'))) {
    f = f.substring(base.length);
  }
  return f.replaceFirst(RegExp(r'^/+'), '');
}

CancelFn _cancelNow = () => false;

Future<void> _sleep(Duration d) async {
  final end = DateTime.now().add(d);
  while (true) {
    if (_cancelNow()) throw CancelledException();
    final left = end.difference(DateTime.now());
    if (left <= Duration.zero) return;
    await Future.delayed(
      left < const Duration(milliseconds: 250)
          ? left
          : const Duration(milliseconds: 250),
    );
  }
}

DateTime _cooldownUntil = DateTime.now();
int _rateHits = 0;

void Function(DateTime until, int sec, bool fromServer)? rateLimitHook;

void restoreCooldown(DateTime until) {
  if (until.isAfter(_cooldownUntil)) _cooldownUntil = until;
}

Future<void> _waitCooldown() async {
  final w = _cooldownUntil.difference(DateTime.now());
  if (w > Duration.zero) await _sleep(w);
}

void _noteRateLimit(int retryAfter) {
  _rateHits++;
  final fromServer = retryAfter > 0;
  final w = fromServer
      ? retryAfter + _jit(2, 5)
      : _backoff * min(_rateHits, _retries) + _jit(1, 3);
  final until = DateTime.now().add(_secs(w));
  if (until.isAfter(_cooldownUntil)) _cooldownUntil = until;
  rateLimitHook?.call(until, w.round(), fromServer);
}

Future<String?> _errMsg(HttpClientResponse resp) async {
  try {
    final body = await resp.transform(utf8.decoder).join().timeout(_apiTimeout);
    final j = jsonDecode(body);
    if (j is Map) {
      final m = j['description'] ?? j['message'] ?? j['error'];
      if (m is String && m.isNotEmpty) return m;
    }
  } catch (_) {}
  return null;
}

Future<String> fetchWithRetry(Uri url) async {
  Object? last;
  var attempt = 0;
  while (true) {
    if (_cancelNow()) throw CancelledException();
    await _waitCooldown();
    var isRate = false;
    try {
      final req = await _open(url).timeout(_apiTimeout);
      final resp = await req.close().timeout(_apiTimeout);
      if (resp.statusCode < 400) {
        _rateHits = 0;
        return await resp.transform(utf8.decoder).join().timeout(_apiTimeout);
      }
      final ra = int.tryParse(resp.headers.value('retry-after') ?? '') ?? 0;
      final msg = await _errMsg(resp);
      if (resp.statusCode == 429) {
        isRate = true;
        last = HttpStatusException(429, msg);
        _noteRateLimit(ra);
      } else if (_fatalCodes.contains(resp.statusCode)) {
        throw HttpStatusException(resp.statusCode, msg);
      } else {
        last = HttpStatusException(resp.statusCode, msg);
      }
    } on HttpStatusException {
      rethrow;
    } on IOException catch (e) {
      last = e;
    } on TimeoutException catch (e) {
      last = e;
    }
    if (isRate) continue;
    if (++attempt >= _retries) throw last;
    await _sleep(_secs(_backoff * attempt + _jit(1, 3)));
  }
}

Future<Map<String, dynamic>> _getJson(
  String endpoint,
  Map<String, String> q,
) async {
  final uri = Uri.parse(endpoint).replace(queryParameters: q);
  return jsonDecode(await fetchWithRetry(uri)) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> getItems(
  String key,
  String path,
  int offset, [
  int limit = 100,
]) {
  return _getJson(_api, {
    'public_key': key,
    'path': path,
    'offset': '$offset',
    'limit': '$limit',
    'fields':
        '_embedded.items.name,_embedded.items.type,_embedded.items.path,'
        '_embedded.items.file,_embedded.items.size,_embedded.items.md5,'
        '_embedded.total',
  });
}

Future<String> getDownloadUrl(String key, String path) async {
  final data = await _getJson('$_api/download', {
    'public_key': key,
    if (path.isNotEmpty && path != '/') 'path': path,
  });
  final href = data['href'] as String?;
  if (href == null || href.isEmpty) {
    throw Exception('В ответе API нет ссылки на скачивание');
  }
  return href;
}

Future<Map<String, dynamic>> getMeta(String key, [String path = '/']) =>
    _getJson(_api, {
      'public_key': key,
      if (path.isNotEmpty && path != '/') 'path': path,
      'fields': 'name,size,type,md5',
    });

Future<T> _orCancel<T>(Future<T> f, Future<void>? c) => c == null
    ? f
    : Future.any([f, c.then<T>((_) => throw CancelledException())]);

Future<void> _pump(
  HttpClientResponse resp,
  IOSink sink,
  int offset,
  int total,
  void Function(int done, int total)? onProgress,
  Future<void>? cancel,
) {
  final finished = Completer<void>();
  var got = offset;
  Timer? idle;
  late StreamSubscription<List<int>> sub;

  void fail(Object e) {
    idle?.cancel();
    if (!finished.isCompleted) finished.completeError(e);
    sub.cancel();
  }

  void arm() {
    idle?.cancel();
    idle = Timer(_dlTimeout, () => fail(TimeoutException('idle')));
  }

  arm();
  sub = resp.listen(
    (chunk) {
      sink.add(chunk);
      got += chunk.length;
      onProgress?.call(got, total);
      arm();
    },
    onError: fail,
    onDone: () {
      idle?.cancel();
      if (!finished.isCompleted) finished.complete();
    },
    cancelOnError: true,
  );
  cancel?.then((_) => fail(CancelledException()));
  return finished.future;
}

Future<void> _closeQuiet(IOSink? sink) async {
  try {
    await sink?.close();
  } catch (_) {}
}

Future<void> _finish(String part, String dest) async {
  final d = File(dest);
  if (await d.exists()) await d.delete();
  await File(part).rename(dest);
}

void _deleteQuiet(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

Future<bool> _md5Ok(String file, String expected) async {
  if (expected.isEmpty) return true;
  final d = await md5.bind(File(file).openRead()).first;
  return d.toString() == expected.toLowerCase();
}

String destPathOf(String destDir, RemoteFile f) =>
    p.joinAll([destDir, ...f.name.split('/')]);

List<int> scanLocal(String destDir, List<RemoteFile> files) {
  return [for (final f in files) _localDone(destPathOf(destDir, f), f.size)];
}

int _localDone(String dest, int size) {
  final d = File(dest);
  if (d.existsSync() && d.lengthSync() == size) return size;
  final pf = File('$dest.part');
  if (!pf.existsSync()) return 0;
  return size > 0 ? min(pf.lengthSync(), size) : pf.lengthSync();
}

Future<void> downloadFile(
  Future<String> Function() getUrl,
  String destPath,
  int size, {
  String expectedMd5 = '',
  void Function(int done, int total)? onProgress,
  CancelFn? cancel,
  Future<void>? cancelSignal,
  int retries = _dlRetries,
}) async {
  final isCancel = cancel ?? () => false;
  final part = '$destPath.part';
  await Directory(p.dirname(destPath)).create(recursive: true);
  Object? last;
  for (var attempt = 1; attempt <= retries; attempt++) {
    IOSink? sink;
    var isRate = false;
    try {
      var offset = File(part).existsSync() ? File(part).lengthSync() : 0;
      if (size > 0 && offset > size) {
        _deleteQuiet(part);
        offset = 0;
      }
      if (size > 0 && offset == size) {
        if (await _md5Ok(part, expectedMd5)) {
          await _finish(part, destPath);
          return;
        }
        _deleteQuiet(part);
        offset = 0;
      }
      final url = await _orCancel(getUrl(), cancelSignal);
      await _orCancel(_waitCooldown(), cancelSignal);
      final req = await _orCancel(
        _open(Uri.parse(url)).timeout(_dlTimeout),
        cancelSignal,
      );
      if (offset > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final resp = await _orCancel(
        req.close().timeout(_dlTimeout),
        cancelSignal,
      );
      if (resp.statusCode == 416) {
        await resp.drain<void>();
        if (size == 0 && offset > 0) {
          await _finish(part, destPath);
          return;
        }
        _deleteQuiet(part);
        last = const HttpStatusException(416);
      } else if (resp.statusCode == 429) {
        final msg = await _errMsg(resp);
        last = HttpStatusException(429, msg);
        isRate = true;
        _noteRateLimit(
          int.tryParse(resp.headers.value('retry-after') ?? '') ?? 0,
        );
      } else if (resp.statusCode >= 400) {
        final msg = await _errMsg(resp);
        if (_fatalCodes.contains(resp.statusCode)) {
          throw HttpStatusException(resp.statusCode, msg);
        }
        last = HttpStatusException(resp.statusCode, msg);
      } else {
        _rateHits = 0;
        final resumed = resp.statusCode == 206 && offset > 0;
        if (!resumed) offset = 0;
        final total = resp.contentLength > 0
            ? offset + resp.contentLength
            : size;
        sink = File(part)
            .openWrite(mode: resumed ? FileMode.append : FileMode.write);
        onProgress?.call(offset, total);
        await _pump(resp, sink, offset, total, onProgress, cancelSignal);
        await sink.close();
        sink = null;
        final len = File(part).lengthSync();
        if (size > 0 && len != size) {
          last = HttpException('Неполный файл: $len из $size');
          if (len > size) _deleteQuiet(part);
        } else if (!await _md5Ok(part, expectedMd5)) {
          _deleteQuiet(part);
          last = const HttpException('Контрольная сумма md5 не совпала');
        } else {
          await _finish(part, destPath);
          return;
        }
      }
    } on CancelledException {
      await _closeQuiet(sink);
      rethrow;
    } on HttpStatusException {
      await _closeQuiet(sink);
      rethrow;
    } on IOException catch (e) {
      last = e;
      await _closeQuiet(sink);
    } on TimeoutException catch (e) {
      last = e;
      await _closeQuiet(sink);
    }
    if (isCancel()) throw CancelledException();
    if (isRate) {
      attempt--;
      continue;
    }
    final wait =
        5 * attempt + (last is HttpStatusException ? _jit(2, 5) : _jit(1, 3));
    await _orCancel(_sleep(_secs(wait)), cancelSignal);
  }
  throw last!;
}

Future<List<Map<String, dynamic>>> listAll(
  String key, [
  String path = '/',
]) async {
  var offset = 0;
  final files = <Map<String, dynamic>>[];

  while (true) {
    final data = await getItems(key, path, offset);
    final emb =
        (data['_embedded'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};

    final items = ((emb['items'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    final total = (emb['total'] as int?) ?? 0;

    for (final item in items) {
      if (item['type'] == 'file') {
        files.add(item);
      } else if (item['type'] == 'dir') {
        files.addAll(await listAll(key, item['path'] as String));
      }
    }

    offset += items.length;
    if (items.isEmpty || offset >= total) break;
  }

  return files;
}

Future<void> run(
  String publicUrl,
  String destDir, {
  void Function(String msg)? log,
  void Function(List<RemoteFile> files)? onList,
  void Function(int i, int done, int total)? onProgress,
  void Function(int i, String state)? onState,
  CancelFn? cancel,
  Future<void>? cancelSignal,
  List<RemoteFile>? files,
}) async {
  void say(String m) => log?.call(m);
  final isCancel = cancel ?? () => false;
  _cancelNow = isCancel;
  _rateHits = 0;
  final src = splitPublicUrl(publicUrl);
  final publicKey = src.key;
  final base = src.path;

  late final List<RemoteFile> list;
  if (files != null) {
    list = files;
  } else {
    say('Получаю список файлов...');
    try {
      final tmp = [
        for (final it in await _orCancel(
          listAll(publicKey, base),
          cancelSignal,
        ))
          RemoteFile(
            _relName(base, it['path'] as String),
            it['path'] as String,
            (it['size'] ?? 0) as int,
            ((it['md5'] ?? '') as String).toLowerCase(),
          ),
      ];
      if (tmp.isEmpty) {
        final meta = await _orCancel(getMeta(publicKey, base), cancelSignal);
        if (meta['type'] != 'file') {
          say('Папка пуста');
          return;
        }
        tmp.add(
          RemoteFile(
            (meta['name'] ?? 'file') as String,
            base,
            (meta['size'] ?? 0) as int,
            ((meta['md5'] ?? '') as String).toLowerCase(),
          ),
        );
      }
      list = tmp;
    } on CancelledException {
      say('Отменено');
      return;
    } catch (e) {
      say('Ошибка API: $e');
      return;
    }
  }

  onList?.call(list);

  final skip = List<bool>.filled(list.length, false);
  for (var i = 0; i < list.length; i++) {
    final f = list[i];
    final dest = destPathOf(destDir, f);
    final d = _localDone(dest, f.size);
    if (d == f.size && File(dest).existsSync()) {
      skip[i] = true;
      onState?.call(i, 'skip');
    } else if (d > 0) {
      onProgress?.call(i, d, f.size);
    }
  }

  for (var i = 0; i < list.length; i++) {
    if (isCancel()) break;
    if (skip[i]) continue;
    final f = list[i];
    try {
      onState?.call(i, 'start');
      await downloadFile(
        () => getDownloadUrl(publicKey, f.path),
        destPathOf(destDir, f),
        f.size,
        expectedMd5: f.md5,
        onProgress: onProgress == null ? null : (d, t) => onProgress(i, d, t),
        cancel: isCancel,
        cancelSignal: cancelSignal,
      );
      onState?.call(i, 'done');
    } on CancelledException {
      onState?.call(i, 'cancel');
      break;
    } on HttpStatusException catch (e) {
      onState?.call(i, 'error');
      if (e.code == 404 || e.code == 410) {
        say(
          'Ошибка: ${f.name}: файл удалён или недоступен на сервере '
          '(HTTP ${e.code}), пропускаю',
        );
      } else if (e.code == 500) {
        say(
          'Ошибка: ${f.name}: внутренняя ошибка сервера (HTTP 500), '
          'файл поврежден на сервере, пропускаю',
        );
      } else {
        say('Ошибка: ${f.name}: $e');
      }
    } catch (e) {
      onState?.call(i, 'error');
      say('Ошибка: ${f.name}: $e');
    }

    var more = false;
    for (var j = i + 1; j < list.length; j++) {
      if (!skip[j]) {
        more = true;
        break;
      }
    }
    if (more && !isCancel()) {
      try {
        await _sleep(_secs(_jit(3, 5)));
      } on CancelledException {
        break;
      }
    }
  }

  say(isCancel() ? 'Отменено' : 'Готово: ${p.absolute(destDir)}');
}
