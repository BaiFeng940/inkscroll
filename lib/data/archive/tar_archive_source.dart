/// TAR 随机访问：tar 本身不压缩，所以可以精确定位后直接切片读取。
///
/// 建立索引只需顺序读每个条目的 **512 字节头部**（跳过数据块），
/// 不读任何数据内容 —— 所以大 tar 也能快速索引。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/errors.dart';
import '../byte_source.dart';
import 'archive_source.dart';

class TarArchiveSource implements ArchiveSource {
  TarArchiveSource(this._src, {this.maxEntryBytes = kDefaultMaxEntryBytes});

  final RandomAccessByteSource _src;
  final int maxEntryBytes;

  List<ArchiveEntryInfo> _entries = const [];
  int _totalUncompressed = 0;
  bool _opened = false;

  /// entryPath -> 数据起始偏移（不放在 ArchiveEntryInfo 里，因为那是通用模型）
  final _dataOffsets = <String, int>{};

  static const int _blockSize = 512;

  @override
  List<ArchiveEntryInfo> get entries => _entries;

  @override
  int get totalUncompressedBytes => _totalUncompressed;

  Future<void> open() async {
    if (_opened) return;
    _opened = true;

    final fileLen = await _src.length();
    int offset = 0;
    String? pendingLongName;

    final out = <ArchiveEntryInfo>[];

    while (offset + _blockSize <= fileLen) {
      final header = await _src.read(offset, _blockSize);
      if (header.length < _blockSize) break;

      // 结束标志：连续两个全零块
      if (_isAllZero(header)) break;

      // 校验 magic（v7 老 tar 没有 ustar，只要字段合法也接受）
      final magic = _ascii(header, 257, 5);
      if (magic != 'ustar' && !_looksLikeTarHeader(header)) break;

      final nameA = _cString(header, 0, 100);
      final prefix = _cString(header, 345, 155);
      final size = _parseOctal(header, 124, 12);
      final typeFlag = header[156];
      final name = prefix.isEmpty ? nameA : '$prefix/$nameA';
      final dataOffset = offset + _blockSize;

      // 数据块按 512 对齐
      final padded = _paddedSize(size);
      offset = dataOffset + padded;

      if (size < 0 || size > fileLen) break; // 头损坏

      switch (typeFlag) {
        case 0x4C: // 'L' GNU 长文件名：数据区就是真实文件名
          pendingLongName = await _readLongName(dataOffset, size);
          continue;
        case 0x4B: // 'K' GNU 长链接名，跳过
          continue;
        case 0x78: // 'x' POSIX pax 扩展头，跳过
        case 0x67: // 'g' pax 全局头，跳过
          continue;
        case 0x30: // '0' 普通文件
        case 0x00: // 老 tar：NUL 也表示普通文件
        case 0x37: // '7' 连续文件
          break;
        default:
          continue; // 目录/链接/设备等一律跳过
      }

      final realName = pendingLongName ?? name;
      pendingLongName = null;

      final sanitized = _sanitize(realName);
      if (sanitized.isEmpty) continue;

      _dataOffsets[sanitized] = dataOffset;
      out.add(ArchiveEntryInfo(
        entryPath: sanitized,
        uncompressedSize: size,
        compressedSize: size, // tar 不压缩
        compressionMethod: 0, // STORE
        localHeaderOffset: dataOffset,
        isEncrypted: false,
      ));
    }

    _entries = out;
    _totalUncompressed = out.fold<int>(0, (s, e) => s + e.uncompressedSize);
  }

  @override
  Future<Uint8List> readEntry(ArchiveEntryInfo entry, {int? maxBytes}) async {
    if (!_opened) await open();

    if (entry.uncompressedSize > maxEntryBytes && maxBytes == null) {
      throw PayloadTooLargeError(
          entry.entryPath, entry.uncompressedSize, maxEntryBytes);
    }

    final dataOffset = _dataOffsets[entry.entryPath] ?? entry.localHeaderOffset;
    final need = maxBytes == null
        ? entry.uncompressedSize
        : math.min(maxBytes, entry.uncompressedSize);
    if (need <= 0) return Uint8List(0);

    // ★ tar 不压缩：直接切片，零解压成本
    return _src.read(dataOffset, need);
  }

  @override
  Future<void> close() async {
    _dataOffsets.clear();
    await _src.close();
  }

  // ------------------------------------------------------------------

  Future<String> _readLongName(int dataOffset, int size) async {
    if (size <= 0 || size > 64 * 1024) return '';
    final b = await _src.read(dataOffset, size);
    return _cString(b, 0, b.length);
  }

  static int _paddedSize(int size) => ((size + _blockSize - 1) ~/ _blockSize) * _blockSize;

  static bool _isAllZero(Uint8List b) {
    for (final v in b) {
      if (v != 0) return false;
    }
    return true;
  }

  /// v7 tar 没有 ustar magic，用"名字区可读 + 大小区是八进制"来粗判
  static bool _looksLikeTarHeader(Uint8List h) {
    final sizeField = _cString(h, 124, 12).trim();
    if (sizeField.isEmpty) return false;
    return RegExp(r'^[0-7]+$').hasMatch(sizeField);
  }

  static int _parseOctal(Uint8List b, int offset, int length) {
    int value = 0;
    int i = offset;
    final end = math.min(offset + length, b.length);
    // 跳过前导空格/NUL
    while (i < end && (b[i] == 0x20 || b[i] == 0)) {
      i++;
    }
    // GNU base-256 编码（超大文件）
    if (i < end && (b[i] & 0x80) != 0) {
      int v = b[i] & 0x7F;
      for (int k = i + 1; k < end; k++) {
        v = (v << 8) | b[k];
      }
      return v;
    }
    while (i < end) {
      final c = b[i];
      if (c < 0x30 || c > 0x37) break;
      value = value * 8 + (c - 0x30);
      i++;
    }
    return value;
  }

  static String _cString(Uint8List b, int offset, int length) {
    final end = math.min(offset + length, b.length);
    int stop = offset;
    while (stop < end && b[stop] != 0) {
      stop++;
    }
    return String.fromCharCodes(b.sublist(offset, stop));
  }

  static String _ascii(Uint8List b, int o, int n) {
    if (o + n > b.length) return '';
    return String.fromCharCodes(b.sublist(o, o + n));
  }

  static String _sanitize(String raw) {
    var p = raw.replaceAll('\\', '/');
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    final segments = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(seg);
    }
    return segments.join('/');
  }
}
