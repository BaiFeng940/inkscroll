/// 随机访问字节源。
///
/// 这是"不解压整个压缩包"的物理基础：有了"任意偏移 + 任意长度"的读取能力，
/// 才能只读 ZIP 的中央目录、只读单个条目的压缩数据。
///
/// 后续可扩展的实现：
///   - HttpRangeByteSource      远程 zip（网盘直链 + Range 请求）
///   - ContentUriByteSource     Android SAF 的 content:// (fd + ffi pread)
///   - SparseIndexedGzipSource  tar.gz 的稀疏索引
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

abstract interface class RandomAccessByteSource {
  /// 总字节数
  Future<int> length();

  /// 读取 [offset, offset+length)。允许乱序、允许并发。
  /// 越界时返回实际可读的部分（调用方负责校验长度）。
  Future<Uint8List> read(int offset, int length);

  Future<void> close();
}

/// 基于 dart:io 的本地文件实现。
///
/// 用 RandomAccessFile 而不是 File.readAsBytes：
/// 后者会把整个文件读进内存，一个 2GB 的漫画包直接 OOM。
///
/// ★ 内部有读取互斥（[_lock]）。
///   原因：`setPosition` + `read` **不是原子操作**。导入时我们并发 8 路嗅探
///   图片尺寸，如果两路交叉执行，A 的 setPosition 可能被 B 覆盖，
///   导致 A 读到错误偏移的数据（表现为"图片头解析随机失败"）。
///   串行化读取开销极小（真正耗时的是 DEFLATE 解压，那部分仍然并发）。
class FileByteSource implements RandomAccessByteSource {
  FileByteSource._(this._raf, this._length);

  final RandomAccessFile _raf;
  final int _length;
  bool _closed = false;

  /// 简单互斥：用 Future 链把读取串起来，保证 setPosition+read 成对执行
  Future<void> _lock = Future<void>.value();

  static Future<FileByteSource> open(String path) async {
    final raf = await File(path).open(mode: FileMode.read);
    final len = await raf.length();
    return FileByteSource._(raf, len);
  }

  @override
  Future<int> length() async => _length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (_closed) throw StateError('FileByteSource 已关闭');
    if (offset < 0) throw ArgumentError('offset 不能为负: $offset');
    if (length <= 0) return Uint8List(0);
    if (offset >= _length) return Uint8List(0);

    final actual = (offset + length > _length) ? _length - offset : length;

    // 串行化：把本次读取接到锁链尾部
    final previous = _lock;
    final completer = Completer<void>();
    _lock = completer.future;

    try {
      await previous;
      if (_closed) throw StateError('FileByteSource 已关闭');
      await _raf.setPosition(offset);
      return await _raf.read(actual);
    } finally {
      completer.complete();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // 等正在进行的读取结束，避免 close 与 read 竞争
    try {
      await _lock;
    } catch (_) {
      // 忽略等待期间的异常
    }
    await _raf.close();
  }
}

/// 内存字节源。用于小文件的单元测试与临时场景。
class MemoryByteSource implements RandomAccessByteSource {
  MemoryByteSource(this._bytes);

  final Uint8List _bytes;

  @override
  Future<int> length() async => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset >= _bytes.length) return Uint8List(0);
    final end = (offset + length > _bytes.length) ? _bytes.length : offset + length;
    return Uint8List.sublistView(_bytes, offset, end);
  }

  @override
  Future<void> close() async {}
}

// ---------------------------------------------------------------------------
// P4 接入点：远程压缩包
// ---------------------------------------------------------------------------
//
// class HttpRangeByteSource implements RandomAccessByteSource {
//   final Dio dio;
//   final Uri uri;
//   final Map<String, String> headers;
//   bool _supportsRange = false;
//   int? _len;
//
//   /// 探测：HEAD 或 Range: bytes=0-0
//   /// 只有当服务端返回 206 Partial Content 时才算支持 Range。
//   Future<void> probe() async { ... }
//
//   /// 块级缓存是必需的：漫画相邻条目在 zip 里通常物理相邻，
//   /// 缓存 1MB 块能显著减少请求数（网盘请求多了会被限流）。
//   @override
//   Future<Uint8List> read(int offset, int length) async {
//     if (!_supportsRange) throw const RangeNotSupportedError();
//     final blockStart = (offset ~/ _blockSize) * _blockSize;
//     final block = await _getBlock(blockStart, blockStart + _blockSize - 1);
//     return Uint8List.sublistView(block, offset - blockStart, offset - blockStart + length);
//   }
// }
