/// 压缩包抽象层：只暴露"条目列表 + 单条目读取"。
///
/// 设计要点：
///   1. 没有任何"解压全部"的 API —— 从接口层面杜绝误用。
///   2. readEntry 带 maxBytes，用于"只读图片头部拿尺寸"这种场景。
///   3. 密码错误与需要密码用 [AppError] 的子类表达，UI 只认 ErrorAction。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../core/errors.dart';
import '../byte_source.dart';

/// 一个压缩包条目的元数据（全部来自中央目录，不读数据）
class ArchiveEntryInfo {
  ArchiveEntryInfo({
    required this.entryPath,
    required this.uncompressedSize,
    required this.compressedSize,
    required this.compressionMethod,
    required this.localHeaderOffset,
    required this.isEncrypted,
    this.crc32,
    this.modified,
  });

  final String entryPath;
  final int uncompressedSize;
  final int compressedSize;

  /// 0 = STORE（未压缩）, 8 = DEFLATE, 12 = BZIP2, 14 = LZMA, 93 = ZSTD, 99 = AES
  final int compressionMethod;

  final int localHeaderOffset;
  final bool isEncrypted;
  final int? crc32;
  final DateTime? modified;

  bool get isDirectory => entryPath.endsWith('/');

  /// 目录前缀，'' 表示根目录
  String get parentDir {
    final i = entryPath.lastIndexOf('/');
    return i < 0 ? '' : entryPath.substring(0, i);
  }

  String get baseName {
    final i = entryPath.lastIndexOf('/');
    return i < 0 ? entryPath : entryPath.substring(i + 1);
  }

  @override
  String toString() => 'ArchiveEntryInfo($entryPath, $uncompressedSize B, m=$compressionMethod)';
}

abstract interface class ArchiveSource {
  /// 全部条目（含目录条目）。只读中央目录得到，不读数据。
  List<ArchiveEntryInfo> get entries;

  /// 所有条目的解压后总大小，用于给用户"这个包很大"的提示
  int get totalUncompressedBytes;

  /// ★ 只解出这一个条目。
  ///
  /// [maxBytes] 用于"只读图片头部"：解出这么多字节就立刻停下，
  /// 不继续解压该条目的剩余部分。
  Future<Uint8List> readEntry(ArchiveEntryInfo entry, {int? maxBytes});

  Future<void> close();
}

/// 条目字节缓存（跨条目共享）。按"条目数 + 字节数"双重限额。
///
/// 为什么要缓存：用户往回滑一页时，不应该重新解压一次。
class EntryCache {
  EntryCache({this.maxEntries = 16, this.maxBytes = 64 << 20});

  final int maxEntries;
  final int maxBytes;

  final _map = <String, Uint8List>{};
  int _bytes = 0;

  Uint8List? get(String key) {
    final v = _map.remove(key);
    if (v == null) return null;
    _map[key] = v; // 移到末尾 = 最近使用
    return v;
  }

  void put(String key, Uint8List value) {
    final old = _map.remove(key);
    if (old != null) _bytes -= old.length;
    _map[key] = value;
    _bytes += value.length;
    _evict();
  }

  void clear() {
    _map.clear();
    _bytes = 0;
  }

  int get bytes => _bytes;
  int get length => _map.length;

  void _evict() {
    while (_map.isNotEmpty && (_map.length > maxEntries || _bytes > maxBytes)) {
      final k = _map.keys.first;
      final v = _map.remove(k);
      if (v != null) _bytes -= v.length;
    }
  }
}

/// 单条目解压输出的安全上限。
/// 防 zip bomb：中央目录里声明的 uncompressedSize 可能是恶意的。
const int kDefaultMaxEntryBytes = 64 << 20; // 64MB

/// 文件名编码：ZIP 的 flag bit 11 没置位时，文件名多半是 GBK（中文压缩包）。
/// 这里做保守解码：先试 UTF-8，失败再按单字节（Latin-1）映射，绝不让文件名解析抛异常。
String decodeLegacyZipName(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // 真实的 GBK 解码需要 fast_gbk / charset_converter。
    // 起步阶段用 Latin-1 保底：文件名可能显示为乱码，但不影响读取内容，
    // 排序与分类只依赖'能否解析出图片扩展名'，仍可正常工作。
    return String.fromCharCodes(bytes);
  }
}

/// 借 package:archive 的 DEFLATE 实现来解压。
///
/// 为什么不直接用 archive 的 ZipDecoder：
///   ZipDecoder().decodeBytes() 会把**整个压缩包**读进内存，
///   这直接违反"不解压整个压缩包、不一次性加载"的约束。
///   我们只用它的 Inflate 算法，字节来源与解压范围完全由自己控制。
Uint8List inflateEntry(List<int> compressed, int uncompressedSize) {
  if (compressed.isEmpty) return Uint8List(0);
  final raw = Inflate(compressed, uncompressedSize).getBytes();
  final out = raw is Uint8List ? raw : Uint8List.fromList(raw);
  return out;
}

/// 工具：切出 [offset, offset+length) 的子视图（不复制）
Uint8List subView(Uint8List b, int offset, int length) {
  final start = math.max(0, math.min(offset, b.length));
  final end = math.max(start, math.min(offset + length, b.length));
  return Uint8List.sublistView(b, start, end);
}

/// 读魔术字节用的小工具（任何导入流程的第一步）
Future<Uint8List> peekHead(RandomAccessByteSource src, {int bytes = 8192}) async {
  final len = await src.length();
  return src.read(0, math.min(bytes, len));
}
