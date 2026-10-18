/// 网络（WebDAV / 飞牛 NAS）页字节解析器。
///
/// ## 设计取舍：为什么是"按需流式 + 磁盘缓存"，而不是"先整本下载"
///
/// 用户的核心诉求是"在线浏览 NAS 里的漫画"。这里有两种做法：
///
/// **A. 先整本下载再读。** 实现最简单，但看一本 300 页、每页 800KB 的漫画
///    要先等 240MB 下载完 —— 就算在千兆局域网也要几分钟，
///    用户会以为软件卡死了。
///
/// **B. 按需拉取。** 打开只需要一次目录列表，第一页立刻可见。
///
/// 这里选 B，并且补两件事把体验拉平：
///
/// 1. **磁盘缓存**：每页拉下来就落盘。第二次看就是本地文件，
///    断网也能看已缓存的部分。
/// 2. **邻近预取**：当前页开始加载时，后台悄悄预取前后各 2 页，
///    这样正常翻页几乎不会等到网络。
///
/// 第 2 点是关键 —— 没有它，每翻一页都要等一个 RTT，
/// 在 Wi-Fi 上会有明显"一顿一顿"的感觉。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/image_header.dart';
import '../data/webdav/webdav_client.dart';
import 'document.dart';
import 'page_cache.dart';

class WebDavPageByteResolver implements PageByteResolver {
  WebDavPageByteResolver({
    required this.client,
    required this.cacheDir,
    PageImageCache? cache,
    this.prefetchRadius = 2,
    List<PageNode>? pageList,
  })  : _cache = cache ?? PageImageCache(maxEntries: 24, maxBytes: 96 << 20),
        _pages = pageList ?? const [];

  final WebDavClient client;

  /// 磁盘缓存目录（app 私有）
  final Directory cacheDir;

  /// 前后各预取多少页
  final int prefetchRadius;

  final PageImageCache _cache;
  final List<PageNode> _pages;

  final _inflight = <String, Future<Uint8List>>{};

  /// 正在磁盘缓存里落地的页（避免同一页写两次）
  final _diskInflight = <String, Future<void>>{};
  final _diskDone = <String>{};

  /// 统计：命中内存 / 命中磁盘 / 走网络
  int memoryHits = 0;
  int diskHits = 0;
  int networkFetches = 0;

  // ------------------------------------------------------------------
  // PageByteResolver
  // ------------------------------------------------------------------

  @override
  Future<Uint8List> imageBytes(PageNode page) {
    final hit = _cache.get(page.id);
    if (hit != null) {
      memoryHits++;
      return Future.value(hit);
    }
    final existing = _inflight[page.id];
    if (existing != null) return existing;

    // ★ 不要写成 `_load(page).whenComplete(...)` —— 那个代理 Future
    //   在真机上不会正常完成，会让 await 永远挂住（这个坑踩过两次）。
    final future = _load(page);
    _inflight[page.id] = future;

    // 加载当前页时顺手预取邻居。**不 await**，失败也不影响当前页。
    unawaited(_prefetchAround(page));

    return future;
  }

  Future<Uint8List> _load(PageNode page) async {
    try {
      return await _loadInner(page);
    } finally {
      _inflight.remove(page.id);
    }
  }

  Future<Uint8List> _loadInner(PageNode page) async {
    final ref = _refOf(page);

    // ① 磁盘缓存
    final cachedFile = _fileFor(ref.url);
    if (await cachedFile.exists()) {
      try {
        final bytes = await cachedFile.readAsBytes();
        if (bytes.isNotEmpty) {
          diskHits++;
          _cache.put(page.id, bytes);
          return bytes;
        }
      } catch (_) {
        // 缓存坏了就当没有
      }
    }

    // ② 网络
    networkFetches++;
    final bytes = await client.get(ref.url);
    if (bytes.isEmpty) {
      throw GenericError('服务器返回了空文件：${_nameOf(ref.url)}');
    }
    _cache.put(page.id, bytes);
    unawaited(_writeDisk(ref.url, bytes));
    return bytes;
  }

  @override
  Future<Uint8List> peekBytes(PageNode page, {int bytes = 192 * 1024}) async {
    final ref = _refOf(page);
    final cachedFile = _fileFor(ref.url);
    if (await cachedFile.exists()) {
      try {
        final raf = await cachedFile.open();
        try {
          return await raf.read(bytes);
        } finally {
          await raf.close();
        }
      } catch (_) {}
    }
    // 只取头部，不下载整张图
    return client.getRange(ref.url, maxBytes: bytes);
  }

  @override
  Future<void> dispose() async {
    client.close();
  }

  // ------------------------------------------------------------------
  // 预取
  // ------------------------------------------------------------------

  Future<void> _prefetchAround(PageNode page) async {
    if (prefetchRadius <= 0 || _pages.isEmpty) return;
    final idx = _pages.indexWhere((p) => p.id == page.id);
    if (idx < 0) return;

    for (var d = 1; d <= prefetchRadius; d++) {
      for (final i in [idx + d, idx - d]) {
        if (i < 0 || i >= _pages.length) continue;
        final p = _pages[i];
        if (_cache.get(p.id) != null) continue;
        if (_diskDone.contains(p.id)) continue;
        if (_inflight.containsKey(p.id) || _diskInflight.containsKey(p.id)) {
          continue;
        }
        final ref = _refOf(p);

        // 已经在磁盘上 → 只预热内存，不发网络请求
        final f = _fileFor(ref.url);
        if (await f.exists()) {
          try {
            final b = await f.readAsBytes();
            if (b.isNotEmpty) {
              _cache.put(p.id, b);
              _diskDone.add(p.id);
            }
          } catch (_) {}
          continue;
        }

        // 后台拉取，不阻塞当前页
        final task = _prefetchOne(p, ref.url);
        _diskInflight[p.id] = task;
        unawaited(task.whenComplete(() => _diskInflight.remove(p.id)));
      }
    }
  }

  Future<void> _prefetchOne(PageNode page, String url) async {
    try {
      final bytes = await client.get(url);
      if (bytes.isEmpty) return;
      _cache.put(page.id, bytes);
      await _writeDisk(url, bytes);
    } catch (_) {
      // 预取失败无所谓：用户真翻到那一页时会重新请求并给出错误提示
    }
  }

  // ------------------------------------------------------------------
  // 磁盘缓存
  // ------------------------------------------------------------------

  Future<void> _writeDisk(String url, Uint8List bytes) async {
    try {
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      final f = _fileFor(url);
      // 先写临时文件再 rename，避免进程被杀导致半个文件被当成有效缓存
      final tmp = File('${f.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
      _diskDone.add(f.path);
    } catch (_) {
      // 磁盘写失败不影响阅读（下次重新下载即可）
    }
  }

  File _fileFor(String url) =>
      File('${cacheDir.path}/${_hashOf(url)}.img');

  static String _hashOf(String url) {
    // 用 url 的 hashCode + 长度做文件名。
    // 不用 crypto 的 sha1 是为了省一次依赖调用 —— 这里只需要"够散列"，
    // 碰撞概率对抗的是同一个 book 内的 url 集合，完全够用。
    var h = 0x811c9dc5; // FNV-1a 32bit
    for (final c in url.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return '${h.toRadixString(16)}_${url.length}';
  }

  static String _nameOf(String url) {
    final segs = Uri.parse(url).pathSegments;
    return segs.isEmpty ? url : segs.last;
  }

  WebDavRef _refOf(PageNode page) {
    final content = page.content;
    if (content is! ImageContent) {
      throw const GenericError('该页不是图片内容');
    }
    final ref = content.ref;
    if (ref is! WebDavRef) {
      throw const GenericError('页内容引用类型与网络来源不匹配');
    }
    return ref;
  }

  /// 清空磁盘缓存
  Future<void> clearDiskCache() async {
    try {
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    } catch (_) {}
    _diskDone.clear();
  }

  /// 磁盘缓存占用（字节）
  Future<int> diskCacheSize() async {
    try {
      if (!await cacheDir.exists()) return 0;
      var total = 0;
      await for (final e in cacheDir.list()) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 嗅探单页尺寸（只下头部）
  Future<ImageDimension?> sniffDimension(PageNode page) async {
    try {
      final head = await peekBytes(page);
      return ImageHeaderParser.tryParse(head);
    } catch (_) {
      return null;
    }
  }
}
