/// 原生压缩包桥（rar / 7z）。
///
/// 为什么必须有这一层：
///   RAR5 与 7z（LZMA/LZMA2 + BCJ 过滤器）是专有/复杂算法，
///   没有可用的成熟纯 Dart 实现。自研成本极高且极易出错。
///
/// 设计约束（重要）：
///   ★ 只允许"解出单个条目"，绝不允许"解压整个包"。
///   ★ 大条目写入临时文件后必须交给 LRU 管理，不能无限占用磁盘。
///
/// 本文件当前是**骨架 + 明确指引**，未接原生代码。
/// 接入步骤见文件末尾注释。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/errors.dart';
import '../byte_source.dart';
import 'archive_source.dart';

/// 原生解压的结果：小条目直接给字节，大条目给临时文件句柄
sealed class NativeExtractResult {
  const NativeExtractResult();
}

final class NativeBytes extends NativeExtractResult {
  const NativeBytes(this.bytes);
  final Uint8List bytes;
}

final class NativeTempFile extends NativeExtractResult {
  const NativeTempFile({
    required this.tempPath,
    required this.offset,
    required this.length,
    required this.evictKey,
  });

  final String tempPath;
  final int offset;
  final int length;

  /// 交给 TempFileCache 做 LRU 淘汰的键
  final String evictKey;
}

abstract interface class NativeArchiveBridge {
  /// 只列条目（读中央目录/头信息），不读数据
  Future<List<ArchiveEntryInfo>> listEntries(String archivePath, {String? password});

  /// ★ 只解这一个条目
  Future<NativeExtractResult> extractEntry(
    String archivePath,
    ArchiveEntryInfo entry, {
    String? password,
    int? maxBytes,
  });
}

/// 临时文件 LRU：原生解出来的大条目落盘后由它管理。
///
/// 为什么必须要有：一个 2GB 的 rar 里翻了 50 页，
/// 若每次解出 40MB 临时文件且从不清理，磁盘很快被吃光。
class TempFileCache {
  TempFileCache({this.maxBytes = 512 * 1024 * 1024});

  final int maxBytes;

  final _entries = <String, _TempEntry>{};
  int _bytes = 0;

  /// 用一个 key 换一个临时文件路径。若已存在且可用则直接复用。
  Future<String> materialize(
    String evictKey,
    Future<NativeTempFile> Function() producer,
  ) async {
    final hit = _entries.remove(evictKey);
    if (hit != null) {
      _entries[evictKey] = hit; // touch
      return hit.path;
    }
    final produced = await producer();
    _entries[evictKey] = _TempEntry(produced.tempPath, produced.length);
    _bytes += produced.length;
    await _evict();
    return produced.tempPath;
  }

  Future<void> _evict() async {
    while (_bytes > maxBytes && _entries.length > 1) {
      final key = _entries.keys.first;
      final e = _entries.remove(key);
      if (e != null) {
        _bytes -= e.size;
        await deleteQuietly(e.path);
      }
    }
  }

  /// App 启动时清理孤儿临时文件（上次崩溃留下的）
  Future<void> purgeAll() async {
    for (final e in _entries.values) {
      await deleteQuietly(e.path);
    }
    _entries.clear();
    _bytes = 0;
  }

  static Future<void> deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删除失败不影响主流程（下次启动 purgeAll 会再试）
    }
  }
}

class _TempEntry {
  _TempEntry(this.path, this.size);
  final String path;
  final int size;
}

/// 原生桥的 Dart 侧包装：把它适配成 ArchiveSource，对上层完全透明。
class NativeArchiveSource implements ArchiveSource {
  NativeArchiveSource({
    required this.archivePath,
    required this.bridge,
    required this.tempCache,
    this.password,
    this.maxEntryBytes = kDefaultMaxEntryBytes,
  });

  final String archivePath;
  final NativeArchiveBridge bridge;
  final TempFileCache tempCache;
  final String? password;
  final int maxEntryBytes;

  List<ArchiveEntryInfo> _entries = const [];
  bool _opened = false;

  @override
  List<ArchiveEntryInfo> get entries => _entries;

  @override
  int get totalUncompressedBytes =>
      _entries.fold<int>(0, (s, e) => s + e.uncompressedSize);

  Future<void> open() async {
    if (_opened) return;
    _opened = true;
    try {
      _entries = await bridge.listEntries(archivePath, password: password);
    } on ArchivePasswordRequiredError {
      rethrow;
    } catch (e) {
      // 原生侧把"密码错误"也抛进来时统一转换
      if (password != null && password!.isNotEmpty) {
        throw const ArchivePasswordWrongError();
      }
      rethrow;
    }
  }

  @override
  Future<Uint8List> readEntry(ArchiveEntryInfo entry, {int? maxBytes}) async {
    if (!_opened) await open();

    final need = maxBytes == null
        ? entry.uncompressedSize
        : math.min(maxBytes, entry.uncompressedSize);

    if (need > maxEntryBytes && maxBytes == null) {
      throw PayloadTooLargeError(entry.entryPath, need, maxEntryBytes);
    }

    final result = await bridge.extractEntry(
      archivePath,
      entry,
      password: password,
      maxBytes: maxBytes,
    );

    switch (result) {
      case NativeBytes(:final bytes):
        return bytes.length <= need ? bytes : Uint8List.sublistView(bytes, 0, need);
      case NativeTempFile temp:
        // 大条目已落盘：用 FileByteSource 按需读取它的区间，
        // 这样"读取图片头部"仍然只读几十 KB，不会把 40MB 全读进内存。
        final src = await FileByteSource.open(temp.tempPath);
        try {
          return await src.read(temp.offset, need);
        } finally {
          await src.close();
        }
    }
  }

  @override
  Future<void> close() async {
    await tempCache.purgeAll();
  }
}

// ---------------------------------------------------------------------------
// 接入步骤（Android）
// ---------------------------------------------------------------------------
//
// 1) pubspec.yaml 加：pigeon（生成类型安全通道）或直接用 MethodChannel
//
// 2) android/app/build.gradle：
//      dependencies {
//        implementation 'com.github.junrar:junrar:7.5.5'          // RAR
//        implementation 'org.apache.commons:commons-compress:1.26.2' // 7z / xz
//        implementation 'org.tukaani:xz:1.9'
//      }
//
// 3) 实现 NativeArchiveBridge 的 Kotlin 侧：
//      class ArchiveBridge : NativeArchiveBridge {
//        override fun listEntries(path: String, password: String?): List<Entry> {
//          // RAR: JunrarArchive(File(path)).use { it.fileHeaders.map { h -> ... } }
//          // 7z:  SevenZFile.builder().setFile(...).setPassword(...).get()
//          //           .use { it.nextEntry?.let { e -> ... } }
//        }
//        override fun extractEntry(path, entry, password, maxBytes): ExtractResult {
//          // ★ 只解这一个条目。大条目写 cacheDir 临时文件并返回句柄。
//          // 绝不要 SevenZFile.extractAll() / Archive.extractAll()
//        }
//      }
//
// 4) iOS：Podfile 加 pod 'UnrarKit' / pod 'PLzmaSDK'
//
// 5) 把 NativeArchiveSource 交给 ArchiveFactory 分派（见 archive_factory.dart）
//
// ---------------------------------------------------------------------------
