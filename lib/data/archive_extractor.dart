/// 压缩包后台解压到 app 缓存。
///
/// ## 为什么要有这个
///
/// 用户明确要求"允许解压到 app 缓存以获得更好的体验"。这个权衡是对的：
///
/// | | 不解压（按需） | 解压到缓存 |
/// |---|---|---|
/// | 导入耗时 | 快（只读中央目录） | 仍是快（解压放后台） |
/// | 翻页延迟 | 每页 DEFLATE 解压，几十~几百 ms | 直接读文件，几 ms |
/// | 磁盘占用 | 只占压缩包 | 压缩包 + 解压产物（约 1~3 倍） |
/// | 内存峰值 | 每次解压一个条目 | 无（读文件即可） |
///
/// ## 关键设计
///
/// 1. **解压放在后台**，导入完成、用户开始阅读之后才进行。
///    用户不需要等，翻到哪页哪页可用 —— 未解压到的页自动回退到 zip 读取。
/// 2. **有完整的资源护栏**：总量上限、失败上限、取消支持。
///    解压是"锦上添花"，绝不能因为它把手机写满或者卡死。
/// 3. **可随时中止与删除**：删掉解压产物只是回到按需解压，书不会坏。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/errors.dart';
import 'archive/archive_source.dart';
import 'byte_store.dart';

class ExtractProgress {
  const ExtractProgress({
    required this.done,
    required this.total,
    required this.bytesWritten,
    this.currentEntry,
  });

  final int done;
  final int total;
  final int bytesWritten;
  final String? currentEntry;

  double get ratio => total <= 0 ? 0 : done / total;
}

class ExtractResult {
  const ExtractResult({
    required this.extracted,
    required this.failed,
    required this.skippedReason,
    required this.bytesWritten,
  });

  final int extracted;
  final int failed;

  /// 非空表示没有完整解压，原因要展示给用户
  final String? skippedReason;
  final int bytesWritten;

  bool get ok => skippedReason == null;
}

/// 解压护栏配置
class ExtractLimits {
  const ExtractLimits({
    this.maxTotalBytes = 2 << 30, // 2GB：解压产物总量上限
    this.maxEntryBytes = 64 << 20, // 单个条目上限（同时是 zip bomb 防护）
    this.maxEntries = 50000,
    this.reserveBytes = 512 << 20, // 为系统保留的余量，不做精确磁盘探测
  });

  final int maxTotalBytes;
  final int maxEntryBytes;
  final int maxEntries;
  final int reserveBytes;
}

class ArchiveExtractor {
  ArchiveExtractor({required this.store, this.limits = const ExtractLimits()});

  final ByteStore store;
  final ExtractLimits limits;

  /// 正在解压的书籍（bookId -> 取消标记），避免重复起任务
  static final _running = <String, _CancelToken>{};

  static bool isRunning(String bookId) => _running.containsKey(bookId);

  static void cancel(String bookId) {
    final token = _running[bookId];
    if (token != null) token.cancelled = true;
  }

  /// 这本书的解压产物是否已经就绪（用于 UI 显示）
  Future<bool> isExtracted(String bookId) async {
    final marker = File(_doneMarker(bookId));
    return marker.exists();
  }

  String _doneMarker(String bookId) =>
      p.join(store.extractedDirFor(bookId), '.complete');

  /// 需要解压吗？（总量够小 + 尚未解压）
  bool shouldExtract(ArchiveSource source) {
    final total = source.totalUncompressedBytes;
    if (total <= 0) return false;
    if (total > limits.maxTotalBytes) return false;
    final images =
        source.entries.where((e) => !e.isDirectory).length;
    if (images > limits.maxEntries) return false;
    // 没什么可解压的（比如只有一两个条目）就不值得
    return images >= 3;
  }

  /// 后台解压。**不阻塞调用方** —— 调用方用 unawaited 触发即可。
  ///
  /// 已经解压完成或正在解压时直接返回。
  Future<ExtractResult> extract({
    required String bookId,
    required ArchiveSource source,
    void Function(ExtractProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_running.containsKey(bookId)) {
      return const ExtractResult(
        extracted: 0,
        failed: 0,
        skippedReason: '该书已在解压中',
        bytesWritten: 0,
      );
    }

    final token = _CancelToken();
    _running[bookId] = token;

    try {
      return await _extractInner(
        bookId: bookId,
        source: source,
        token: token,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    } finally {
      _running.remove(bookId);
    }
  }

  Future<ExtractResult> _extractInner({
    required String bookId,
    required ArchiveSource source,
    required _CancelToken token,
    void Function(ExtractProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final entries =
        source.entries.where((e) => !e.isDirectory).toList(growable: false);

    if (entries.isEmpty) {
      return const ExtractResult(
        extracted: 0,
        failed: 0,
        skippedReason: '压缩包内没有文件',
        bytesWritten: 0,
      );
    }
    if (entries.length > limits.maxEntries) {
      return ExtractResult(
        extracted: 0,
        failed: 0,
        skippedReason: '条目数 ${entries.length} 超过上限 ${limits.maxEntries}，已跳过解压',
        bytesWritten: 0,
      );
    }
    if (source.totalUncompressedBytes > limits.maxTotalBytes) {
      return ExtractResult(
        extracted: 0,
        failed: 0,
        skippedReason:
            '解压后约 ${_human(source.totalUncompressedBytes)}，'
            '超过上限 ${_human(limits.maxTotalBytes)}，已跳过解压（不影响阅读）',
        bytesWritten: 0,
      );
    }

    final outDir = Directory(store.extractedDirFor(bookId));
    if (!await outDir.exists()) await outDir.create(recursive: true);

    int done = 0;
    int failed = 0;
    int bytesWritten = 0;
    bool aborted = false;
    String? abortReason;

    for (final e in entries) {
      if (token.cancelled || (isCancelled?.call() ?? false)) {
        aborted = true;
        abortReason = '已取消';
        break;
      }

      final target = File(store.extractedPathFor(bookId, e.entryPath));
      // 已经解压过就跳过（支持中断后续传）
      if (await target.exists()) {
        done++;
        continue;
      }

      // 单个条目过大 → 不解压（阅读时按需从 zip 读）
      if (e.uncompressedSize > limits.maxEntryBytes) {
        failed++;
        continue;
      }

      try {
        final bytes = await source.readEntry(e, maxBytes: limits.maxEntryBytes);
        if (bytes.isEmpty) {
          failed++;
        } else {
          await target.parent.create(recursive: true);
          await target.writeAsBytes(bytes, flush: false);
          bytesWritten += bytes.length;
          done++;
        }
      } catch (_) {
        failed++;
        if (failed >= ByteStore.maxExtractFailures) {
          aborted = true;
          abortReason = '连续 $failed 个条目解压失败，已中止';
          break;
        }
      }

      // 总量护栏：超了就停，保留已解压的部分
      if (bytesWritten > limits.maxTotalBytes) {
        aborted = true;
        abortReason =
            '已达解压总量上限 ${_human(limits.maxTotalBytes)}，'
            '剩余条目读取时按需解压';
        break;
      }

      if (done % 10 == 0 || done == entries.length) {
        onProgress?.call(ExtractProgress(
          done: done,
          total: entries.length,
          bytesWritten: bytesWritten,
          currentEntry: e.entryPath,
        ));
      }
    }

    onProgress?.call(ExtractProgress(
      done: done,
      total: entries.length,
      bytesWritten: bytesWritten,
    ));

    // 只有完整解压才写完成标记（否则下次继续）
    if (!aborted) {
      await File(_doneMarker(bookId)).writeAsString(
        DateTime.now().toIso8601String(),
        flush: true,
      );
    }

    return ExtractResult(
      extracted: done,
      failed: failed,
      skippedReason: aborted ? abortReason : null,
      bytesWritten: bytesWritten,
    );
  }

  static String _human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 一致性检查：解压产物里有文件但缺完成标记 → 说明上次中断了
  Future<bool> needsResume(String bookId) async {
    final dir = Directory(store.extractedDirFor(bookId));
    if (!await dir.exists()) return false;
    if (await File(_doneMarker(bookId)).exists()) return false;
    var count = 0;
    await for (final e in dir.list(followLinks: false)) {
      if (e is File) {
        count++;
        if (count > 1) break;
      }
    }
    return count > 0;
  }
}

class _CancelToken {
  bool cancelled = false;
}

/// 给 UI 用的解压状态快照
class ExtractionSnapshot {
  const ExtractionSnapshot({
    required this.bookId,
    required this.state,
    this.progress,
    this.result,
    this.errorMessage,
  });

  final String bookId;
  final ExtractionState state;
  final ExtractProgress? progress;
  final ExtractResult? result;
  final String? errorMessage;
}

enum ExtractionState { idle, running, done, skipped, failed }

/// 共享的解压管理器：让 UI（设置面板）能观察进度、取消、清空
class ExtractionManager {
  ExtractionManager({required this.store}) : extractor = ArchiveExtractor(store: store);

  final ByteStore store;
  final ArchiveExtractor extractor;

  final _controller = StreamController<ExtractionSnapshot>.broadcast();
  Stream<ExtractionSnapshot> get snapshots => _controller.stream;

  final Map<String, ExtractionState> _states = {};

  ExtractionState stateOf(String bookId) =>
      _states[bookId] ?? ExtractionState.idle;

  /// 带进度回调的解压。**这是唯一的解压入口** ——
  /// 既更新内部状态（设置面板的解压卡片会订阅），
  /// 也把进度转发给调用方（阅读前的准备界面）。
  Future<ExtractResult> extractWithProgress({
    required String bookId,
    required ArchiveSource source,
    void Function(ExtractProgress progress)? onProgress,
  }) async {
    if (ArchiveExtractor.isRunning(bookId)) {
      return const ExtractResult(
        extracted: 0,
        failed: 0,
        skippedReason: '该书已在解压中',
        bytesWritten: 0,
      );
    }
    if (await extractor.isExtracted(bookId)) {
      _states[bookId] = ExtractionState.done;
      return const ExtractResult(
        extracted: 0,
        failed: 0,
        skippedReason: null,
        bytesWritten: 0,
      );
    }
    if (!extractor.shouldExtract(source)) {
      _states[bookId] = ExtractionState.skipped;
      const r = ExtractResult(
        extracted: 0,
        failed: 0,
        skippedReason: '解压后体积超过上限，已保持按需读取',
        bytesWritten: 0,
      );
      _emit(ExtractionSnapshot(
        bookId: bookId,
        state: ExtractionState.skipped,
        result: r,
      ));
      return r;
    }

    _states[bookId] = ExtractionState.running;
    _emit(ExtractionSnapshot(bookId: bookId, state: ExtractionState.running));

    try {
      final result = await extractor.extract(
        bookId: bookId,
        source: source,
        onProgress: (p) {
          onProgress?.call(p);
          _emit(ExtractionSnapshot(
            bookId: bookId,
            state: ExtractionState.running,
            progress: p,
          ));
        },
      );
      _states[bookId] =
          result.ok ? ExtractionState.done : ExtractionState.skipped;
      _emit(ExtractionSnapshot(
        bookId: bookId,
        state: _states[bookId]!,
        result: result,
      ));
      return result;
    } on AppError catch (e) {
      _states[bookId] = ExtractionState.failed;
      _emit(ExtractionSnapshot(
        bookId: bookId,
        state: ExtractionState.failed,
        errorMessage: e.message,
      ));
      return ExtractResult(
        extracted: 0,
        failed: 0,
        skippedReason: e.message,
        bytesWritten: 0,
      );
    } catch (e) {
      _states[bookId] = ExtractionState.failed;
      _emit(ExtractionSnapshot(
        bookId: bookId,
        state: ExtractionState.failed,
        errorMessage: '$e',
      ));
      return ExtractResult(
        extracted: 0,
        failed: 0,
        skippedReason: '$e',
        bytesWritten: 0,
      );
    }
  }

  void cancel(String bookId) {
    ArchiveExtractor.cancel(bookId);
    _states[bookId] = ExtractionState.idle;
    _emit(ExtractionSnapshot(bookId: bookId, state: ExtractionState.idle));
  }

  Future<void> clearFor(String bookId) async {
    ArchiveExtractor.cancel(bookId);
    await store.deleteExtracted(bookId);
    _states[bookId] = ExtractionState.idle;
    _emit(ExtractionSnapshot(bookId: bookId, state: ExtractionState.idle));
  }

  void _emit(ExtractionSnapshot s) {
    if (!_controller.isClosed) _controller.add(s);
  }

  void dispose() {
    _controller.close();
  }
}
