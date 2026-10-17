/// 页字节提供者 + 多级缓存。
///
/// 这是"模型不认识字节、View 不认识压缩包"之间唯一的桥。
///
/// 调用链：
///   PageImage(pageId)
///     → PageImageCache（LRU，避免重复解压）
///       → PageByteResolver
///         → ZipArchiveSource.readEntry()（只解这一个条目）
///           → RandomAccessByteSource.read()（只读这段偏移）
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/image_header.dart';
import '../core/lru_cache.dart';
import '../data/archive/archive_source.dart';
import '../data/byte_store.dart';
import 'document.dart';

abstract interface class PageByteResolver {
  /// 取图片页的完整字节。失败抛 [AppError]。
  Future<Uint8List> imageBytes(PageNode page);

  /// 只取头部字节，用于尺寸嗅探 / 格式判定。
  Future<Uint8List> peekBytes(PageNode page, {int bytes = 192 * 1024});

  Future<void> dispose();
}

// ---------------------------------------------------------------------------
// 缓存
// ---------------------------------------------------------------------------

/// 已解码前的原始字节缓存。
///
/// 为什么要独立于 Flutter 的 ImageCache：
///   ImageCache 缓存的是**解码后的 ui.Image**（内存更大），
///   而且淘汰策略按"张数"算，对 Webtoon 长条完全不够。
///   这里缓存原始字节，成本低、命中率高。
class PageImageCache {
  // 上限调高：滚动时前后各会预取约 1.5 屏的内容，
  // 16 项在大屏 / 长页场景下很容易被冲掉，
  // 导致往回滑一页就要重新读盘 + 重新解码 —— 这正是"卡顿"的来源之一。
  PageImageCache({int maxEntries = 32, int maxBytes = 128 << 20})
      : _lru = LruCache<String, Uint8List>(
          maxEntries: maxEntries,
          maxBytes: maxBytes,
          sizeOf: (v) => v.length,
        );

  final LruCache<String, Uint8List> _lru;

  Uint8List? get(String pageId) => _lru.get(pageId);
  void put(String pageId, Uint8List bytes) => _lru.put(pageId, bytes);
  bool contains(String pageId) => _lru.containsKey(pageId);

  void evict(String pageId) => _lru.remove(pageId);
  void clear() => _lru.clear();

  int get bytes => _lru.bytes;
  int get length => _lru.length;
}

// ---------------------------------------------------------------------------
// 压缩包实现
// ---------------------------------------------------------------------------

class ArchivePageByteResolver implements PageByteResolver {
  ArchivePageByteResolver({
    required ArchiveSource source,
    PageImageCache? cache,
    this.extractedDir,
  })  : _source = source,
        _cache = cache ?? PageImageCache();

  final ArchiveSource _source;
  final PageImageCache _cache;

  /// 后台解压产物目录（可空）。
  ///
  /// 非空时**优先读解压后的文件**：直接文件 I/O 比"读压缩数据 + DEFLATE 解压"
  /// 快一到两个数量级，而且能吃到系统页缓存。
  /// 文件不存在时自动回退到 zip 读取 —— 所以"解压到一半就开始看书"是安全的。
  ///
  /// 文件名规则见 [ByteStore.archiveEntryToFileName]（`/` → `__`）。
  final String? extractedDir;

  /// 同一页的并发请求合并（快速滚动时很常见）
  final _inflight = <String, Future<Uint8List>>{};

  /// 统计：走解压缓存 / 走 zip 解压 的页数（用于验证优化是否真的生效）
  int extractedHits = 0;
  int archiveReads = 0;

  @override
  Future<Uint8List> imageBytes(PageNode page) {
    final hit = _cache.get(page.id);
    if (hit != null) return Future.value(hit);

    final existing = _inflight[page.id];
    if (existing != null) return existing;

    // 注意：这里**不要**用 `_load(page).whenComplete(...)` 返回代理 Future。
    // 代理 Future 会让调用方的 `await` 多挂一层，行为更难排查；
    // 直接在 _load 内部清理 _inflight 更直观。
    final future = _load(page);
    _inflight[page.id] = future;
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
    final ref = page.content;
    if (ref is! ImageContent) {
      throw const GenericError('该页不是图片内容');
    }
    final contentRef = ref.ref;
    if (contentRef is! ArchiveEntryRef) {
      throw const GenericError('页内容引用类型与压缩包来源不匹配');
    }

    // ★ ① 优先：读后台解压好的文件
    //
    // 直接文件 I/O 比"读压缩数据 + DEFLATE 解压"快一到两个数量级。
    // 文件不存在时自动回退 —— 所以"解压到一半就开始看书"是安全的。
    final dir = extractedDir;
    if (dir != null) {
      final f = File('$dir/${ByteStore.archiveEntryToFileName(contentRef.entryPath)}');
      try {
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          if (bytes.isNotEmpty) {
            extractedHits++;
            _cache.put(page.id, bytes);
            return bytes;
          }
        }
      } catch (_) {
        // 读失败不致命，回退到 zip 读取
      }
    } else {
    }

    // ② 回退：按需从压缩包解压单个条目
    final entry = _source.entries.firstWhere(
      (e) => e.entryPath == contentRef.entryPath,
      orElse: () => throw GenericError('压缩包内找不到条目：${contentRef.entryPath}'),
    );

    archiveReads++;
    try {
      final bytes = await _source.readEntry(entry);
      _cache.put(page.id, bytes);
      return bytes;
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<Uint8List> peekBytes(PageNode page, {int bytes = 192 * 1024}) async {
    final contentRef = (page.content as ImageContent).ref;
    if (contentRef is! ArchiveEntryRef) return Uint8List(0);
    final entry = _source.entries.firstWhere(
      (e) => e.entryPath == contentRef.entryPath,
      orElse: () => throw GenericError('压缩包内找不到条目：${contentRef.entryPath}'),
    );
    // ★ maxBytes 让 ZIP 层解出这么多就停手，不会解完整张图
    return _source.readEntry(entry, maxBytes: bytes);
  }

  @override
  Future<void> dispose() async {
    _inflight.clear();
    _cache.clear();
    await _source.close();
  }
}

// ---------------------------------------------------------------------------
// 本地文件（文件夹导入 / 散图导入）
// ---------------------------------------------------------------------------

class FilePageByteResolver implements PageByteResolver {
  FilePageByteResolver({PageImageCache? cache})
      : _cache = cache ?? PageImageCache();

  final PageImageCache _cache;
  final _inflight = <String, Future<Uint8List>>{};

  @override
  Future<Uint8List> imageBytes(PageNode page) {
    final hit = _cache.get(page.id);
    if (hit != null) return Future.value(hit);
    final existing = _inflight[page.id];
    if (existing != null) return existing;

    // ★★ 千万别写成 `_load(page).whenComplete(...)`。
    //
    //   `whenComplete` 返回的是一个**代理 Future**，实测在真机上这个代理
    //   不会正常完成 —— 调用方的 `await` 会**永远挂住**，
    //   表现就是"图片一直加载不出来 / 加载很久"，而且不报任何错。
    //
    //   同一个错误之前在 `ArchivePageByteResolver` 里出现过一次
    //   （那次让所有压缩包漫画都显示不出来）。这里必须用同样的写法：
    //   直接返回 `_load` 的 Future，清理逻辑放进它自己的 `finally`。
    final future = _load(page);
    _inflight[page.id] = future;
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
    final content = page.content;
    if (content is! ImageContent) throw const GenericError('该页不是图片内容');
    final ref = content.ref;
    if (ref is! LooseFileRef) throw const GenericError('页内容引用类型与文件来源不匹配');

    final file = File(ref.path);
    if (!await file.exists()) {
      throw GenericError('文件不存在或已被移动：${ref.path}', action: ErrorAction.chooseAnother);
    }
    final bytes = await file.readAsBytes();
    _cache.put(page.id, bytes);
    return bytes;
  }

  @override
  Future<Uint8List> peekBytes(PageNode page, {int bytes = 192 * 1024}) async {
    final content = page.content;
    if (content is! ImageContent) return Uint8List(0);
    final ref = content.ref;
    if (ref is! LooseFileRef) return Uint8List(0);
    // ★ 只读头部：不把整张图读进内存
    final raf = await File(ref.path).open();
    try {
      final len = await raf.length();
      return await raf.read(math.min(bytes, len));
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> dispose() async {
    _inflight.clear();
    _cache.clear();
  }
}

// ---------------------------------------------------------------------------
// 工厂：由 BookSource 构建对应的 resolver
// ---------------------------------------------------------------------------

/// 不需要页字节的解析器（纯文本文档）
class EmptyPageByteResolver implements PageByteResolver {
  @override
  Future<Uint8List> imageBytes(PageNode page) async => Uint8List(0);

  @override
  Future<Uint8List> peekBytes(PageNode page, {int bytes = 192 * 1024}) async => Uint8List(0);

  @override
  Future<void> dispose() async {}
}

/// 尺寸嗅探工具：给一页的头部字节，解析出宽高
class PageDimensionSniffer {
  static ImageDimension? sniff(Uint8List head) => ImageHeaderParser.tryParse(head);
}

