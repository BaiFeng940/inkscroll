/// 读取**网盘上压缩包里的条目**，并做内存/磁盘两级缓存。
///
/// ## 和 `WebDavPageByteResolver` 的区别
///
/// 那个直接 GET 一个图片 URL；这个要先定位到 ZIP 里的条目，
/// 读它的本地头 + 压缩数据，再解压。所以多了一层 `ZipArchiveSource`。
///
/// ## 流量账
///
/// 打开包：1~2 次 Range（EOCD + 中央目录，几十 KB）
/// 每读一页：2 次 Range（本地头 30 字节 + 该条目的压缩数据）
///
/// 所以翻一页的代价**只等于那一页**，与包有多大无关。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/errors.dart';
import '../data/archive/archive_source.dart';
import '../data/archive/zip_archive_source.dart';
import '../data/webdav/webdav_byte_source.dart';
import '../data/webdav/webdav_client.dart';
import 'document.dart';
import 'page_cache.dart';

class WebDavArchivePageResolver implements PageByteResolver {
  WebDavArchivePageResolver({
    required this.client,
    required this.archiveUrl,
    required this.cacheDir,
    required this.pages,
    this.archiveSize,
    this.prefetchRadius = 2,
  }) : _cache = PageImageCache(
          maxEntries: 24,
          maxBytes: 96 * 1024 * 1024,
        );

  /// 指向压缩包所在主机的客户端
  final WebDavClient client;

  /// 压缩包本身的绝对 URL
  final String archiveUrl;

  /// 解压后的条目缓存目录（磁盘）
  final Directory cacheDir;

  /// 全书页序（用来做邻近预取）
  final List<PageNode> pages;

  /// 已知的包大小（省一次 PROPFIND）
  final int? archiveSize;

  final int prefetchRadius;

  final PageImageCache _cache;
  final _inflight = <String, Future<Uint8List>>{};
  final _diskInflight = <String, Future<void>>{};
  final _diskDone = <String>{};

  ZipArchiveSource? _zip;
  WebDavByteSource? _source;
  Future<void>? _opening;
  final _entryByName = <String, ArchiveEntryInfo>{};

  /// 诊断计数
  int get requestCount => _source?.requestCount ?? 0;
  int get bytesFetched => _source?.bytesFetched ?? 0;

  Future<void> _ensureOpen() async {
    if (_zip != null) return;
    final existing = _opening;
    if (existing != null) return existing;

    final completer = Completer<void>();
    _opening = completer.future;
    try {
      final src = WebDavByteSource(
        url: archiveUrl,
        client: client,
        knownSize: archiveSize,
      );
      final zip = ZipArchiveSource(src);
      await zip.open();
      for (final e in zip.entries) {
        _entryByName[e.entryPath] = e;
      }
      _source = src;
      _zip = zip;
      completer.complete();
    } catch (e, st) {
      completer.completeError(e, st);
      _opening = null;
      rethrow;
    }
  }

  WebDavArchiveRef _refOf(PageNode page) {
    final content = page.content;
    if (content is ImageContent && content.ref is WebDavArchiveRef) {
      return content.ref as WebDavArchiveRef;
    }
    throw GenericError('页 ${page.id} 不是网盘压缩包条目');
  }

  @override
  Future<Uint8List> imageBytes(PageNode page) {
    final hit = _cache.get(page.id);
    if (hit != null) return Future.value(hit);

    final existing = _inflight[page.id];
    if (existing != null) return existing;

    final future = _load(page);
    _inflight[page.id] = future;
    return future.whenComplete(() => _inflight.remove(page.id));
  }

  Future<Uint8List> _load(PageNode page) async {
    final bytes = await _loadInner(page);
    _cache.put(page.id, bytes);
    // 不要在关键路径上等磁盘写入
    unawaited(_persist(page, bytes));
    _prefetchNeighbors(page);
    return bytes;
  }

  Future<Uint8List> _loadInner(PageNode page) async {
    final ref = _refOf(page);
    final file = _fileFor(ref);
    if (_diskDone.contains(page.id) || await file.exists()) {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _diskDone.add(page.id);
          return bytes;
        }
      } catch (_) {
        // 缓存损坏，重新拉
      }
    }

    await _ensureOpen();
    final entry = _entryByName[ref.entryPath];
    if (entry == null) {
      throw GenericError('压缩包里找不到 ${ref.entryPath}');
    }
    final zip = _zip!;
    return zip.readEntry(entry);
  }

  Future<void> _persist(PageNode page, Uint8List bytes) {
    if (_diskDone.contains(page.id)) return Future.value();
    final existing = _diskInflight[page.id];
    if (existing != null) return existing;
    final f = () async {
      try {
        final file = _fileFor(_refOf(page));
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.part');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(file.path);
        _diskDone.add(page.id);
      } catch (_) {
        // 缓存失败不影响阅读
      }
    }();
    _diskInflight[page.id] = f;
    return f.whenComplete(() => _diskInflight.remove(page.id));
  }

  void _prefetchNeighbors(PageNode page) {
    if (prefetchRadius <= 0) return;
    final i = pages.indexWhere((p) => p.id == page.id);
    if (i < 0) return;
    for (var d = 1; d <= prefetchRadius; d++) {
      for (final j in [i + d, i - d]) {
        if (j < 0 || j >= pages.length) continue;
        final neighbor = pages[j];
        if (_cache.get(neighbor.id) != null) continue;
        if (_inflight.containsKey(neighbor.id)) continue;
        final f = _loadQuiet(neighbor);
        _inflight[neighbor.id] = f;
      }
    }
  }

  Future<Uint8List> _loadQuiet(PageNode page) async {
    try {
      return await _load(page);
    } catch (_) {
      _inflight.remove(page.id);
      return Uint8List(0);
    }
  }

  File _fileFor(WebDavArchiveRef ref) {
    // 用 包URL+条目路径 的哈希做文件名，避免路径里有怪字符
    final key = '${ref.archiveUrl}#${ref.entryPath}';
    var h1 = 0x811c9dc5;
    var h2 = 0x01000193;
    for (final c in key.codeUnits) {
      h1 = ((h1 ^ c) * 0x01000193) & 0xffffffff;
      h2 = ((h2 + c * 31) * 0x01000193) & 0xffffffff;
    }
    final name =
        '${h1.toRadixString(16)}${h2.toRadixString(16)}_${_safeName(ref)}.img';
    return File('${cacheDir.path}/$name');
  }

  /// 从条目路径里取一个适合做文件名的片段（保留可读性，便于排查）
  String _safeName(WebDavArchiveRef ref) {
    final n = ref.entryPath.split('/').last;
    return n.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  @override
  Future<Uint8List> peekBytes(PageNode page, {int bytes = 192 * 1024}) async {
    final ref = _refOf(page);
    // 磁盘缓存优先
    try {
      final f = _fileFor(ref);
      if (await f.exists()) {
        final raf = await f.open();
        try {
          final len = await raf.length();
          final n = len < bytes ? len : bytes;
          await raf.setPosition(0);
          return await raf.read(n);
        } finally {
          await raf.close();
        }
      }
    } catch (_) {}

    await _ensureOpen();
    final entry = _entryByName[ref.entryPath];
    if (entry == null) throw GenericError('压缩包里找不到 ${ref.entryPath}');
    return _zip!.readEntry(entry, maxBytes: bytes);
  }

  @override
  Future<void> dispose() async {
    _cache.clear();
    await _zip?.close();
    _zip = null;
    _source = null;
  }
}
