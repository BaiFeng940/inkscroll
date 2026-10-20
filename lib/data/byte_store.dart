/// 导入内容落盘。
///
/// 为什么必须复制到 app 私有目录：
///   file_picker 在 Android 上返回的往往是**临时缓存路径**，
///   系统随时可能清理。不复制就会出现"导出时好好的，第二天打不开"。
///   复制到私有目录同时也天然满足"已导入内容可离线阅读"。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ByteStore {
  ByteStore._(this.root);

  /// <root>/books/<bookId>/...
  final Directory root;

  static const _folderName = 'books';

  static Future<ByteStore> open() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, _folderName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return ByteStore._(dir);
  }

  /// 写入 `.nomedia`，让系统相册 / 媒体库**不要扫描**本应用的私有目录。
  ///
  /// 我们导入的漫画（含从压缩包解压出来的图、从网盘缓存的页）全都存在
  /// 应用私有目录里，正常不会被 MediaStore 收录；但不同厂商的媒体扫描器
  /// 行为不一致，显式放一个 `.nomedia` 是零成本的保险 ——
  /// 用户导入的漫画不应该出现在系统相册里。
  Future<void> ensureNoMedia() async {
    try {
      final marker = File(p.join(root.path, '.nomedia'));
      if (!await marker.exists()) {
        await marker.writeAsString('');
      }
      // 解压/缓存目录也可能被单独扫描，各放一份
      for (final sub in const ['.', 'cache']) {
        final dir = Directory(p.join(root.path, sub));
        if (await dir.exists()) {
          final m = File(p.join(dir.path, '.nomedia'));
          if (!await m.exists()) await m.writeAsString('');
        }
      }
    } catch (_) {
      // 写不进去也不影响功能
    }
  }
  String bookDir(String bookId) => p.join(root.path, bookId);

  /// 供 DocumentCodec 直接使用
  Directory directoryOf(String bookId) => Directory(bookDir(bookId));

  Future<Directory> ensureBookDir(String bookId) async {
    final dir = Directory(bookDir(bookId));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 压缩包导入到私有目录后的路径
  String archivePathFor(String bookId, String originalName) {
    final ext = p.extension(originalName).toLowerCase();
    return p.join(bookDir(bookId), 'archive${ext.isEmpty ? '.zip' : ext}');
  }

  /// 文件夹导入后的根目录
  String folderPathFor(String bookId) => p.join(bookDir(bookId), 'content');

  // ------------------------------------------------------------------
  // 压缩包解压缓存
  //
  // 设计取舍（用户明确要求"允许解压到 app 缓存以换取更好体验"）：
  //
  // ★ 解压**不是**为了让导入变快 —— 导入阶段仍然只读中央目录。
  //   解压的价值在于**阅读时的翻页延迟**：
  //     不解压：每翻一页都要读压缩数据 + DEFLATE 解压（几十到几百毫秒）
  //     已解压：直接读文件（几毫秒），还能吃到系统页缓存
  //
  // ★ 所以解压放在**后台**做：导入完成、用户已经在看书时静默进行。
  //   用户不需要等，翻到哪页哪页可用（未解压到的页自动回退到 zip 读取）。
  //
  // ★ 可随时删除：删掉只是回到"按需解压"，不影响书籍完整性。
  // ------------------------------------------------------------------

  /// 解压产物目录：<bookDir>/extracted
  String extractedDirFor(String bookId) => p.join(bookDir(bookId), 'extracted');

  /// WebDAV 页的磁盘缓存目录：<bookDir>/netcache
  ///
  /// 和 `extracted` 一样属于**可随时删除**的缓存：
  /// 删掉只是回到"每次翻页都走网络"，不影响书籍本身。
  String webdavCacheDirFor(String bookId) => p.join(bookDir(bookId), 'netcache');

  /// 某个压缩包条目解压后的落盘路径。
  ///
  /// 条目名形如 `第01话/001.jpg`，直接当路径会有目录层级与非法字符问题，
  /// 所以做扁平化：`/` → `__`，非法字符替换为 `_`。
  String extractedPathFor(String bookId, String entryPath) =>
      p.join(extractedDirFor(bookId), archiveEntryToFileName(entryPath));

  static String archiveEntryToFileName(String entryPath) {
    final safe = entryPath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
    return safe.replaceAll('/', '__');
  }

  /// 已解压产物占用的字节数
  Future<int> extractedSizeOf(String bookId) async {
    final dir = Directory(extractedDirFor(bookId));
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  /// 删除解压产物（保留压缩包本身）
  Future<void> deleteExtracted(String bookId) async {
    final dir = Directory(extractedDirFor(bookId));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// 解压多少张之后强制中断（防止一张损坏的图把整个后台任务卡死）
  static const int maxExtractFailures = 20;

  // ------------------------------------------------------------------
  // 去重指纹
  // ------------------------------------------------------------------

  /// 由文件"路径 + 大小 + 修改时间"计算指纹。
  ///
  /// 刻意不读文件内容：2GB 的包算 hash 要几十秒，用户等不起。
  /// 元数据组合在现实中已经足够避免重复导入。
  static Future<String> fingerprintFile(String path) async {
    final f = File(path);
    final stat = await f.stat();
    final raw = '$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    return 'file:${sha1.convert(utf8.encode(raw)).toString().substring(0, 16)}';
  }

  /// 压缩包指纹：用中央目录的"条目数 + 总解压大小 + 首尾条目名"。
  /// 不需要解压任何数据，大包也能瞬间算出。
  static String fingerprintArchiveEntries({
    required int entryCount,
    required int totalUncompressed,
    required String firstEntry,
    required String lastEntry,
  }) {
    final raw = '$entryCount|$totalUncompressed|$firstEntry|$lastEntry';
    return 'arc:${sha1.convert(utf8.encode(raw)).toString().substring(0, 16)}';
  }

  // ------------------------------------------------------------------
  // 复制
  // ------------------------------------------------------------------

  /// 流式复制（不把整个文件读进内存），带进度回调。
  static Future<void> copyFile(
    String from,
    String to, {
    void Function(double ratio, String label)? onProgress,
    void Function()? isCancelled,
  }) async {
    final src = File(from);
    final total = await src.length();
    final dst = File(to);
    await dst.parent.create(recursive: true);
    if (await dst.exists()) await dst.delete();

    final sink = dst.openWrite();
    int copied = 0;
    int lastReported = 0;
    try {
      // 64KB 缓冲：兼顾吞吐与进度粒度
      await for (final chunk in src.openRead()) {
        isCancelled?.call();
        sink.add(chunk);
        copied += chunk.length;
        // 每 1% 或 2MB 报一次，避免进度回调本身成为瓶颈
        if (total > 0 &&
            (copied - lastReported > total / 100 || copied - lastReported > 2 << 20)) {
          lastReported = copied;
          onProgress?.call(
            (copied / total).clamp(0, 1),
            '正在复制 ${_human(total)}，共 $total 字节（${(copied / total * 100).toStringAsFixed(0)}%）',
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    onProgress?.call(1.0, '复制完成');
  }

  /// 递归复制目录（用于文件夹导入）
  static Future<int> copyDirectory(
    String from,
    String to, {
    void Function(double ratio, String label)? onProgress,
    void Function()? isCancelled,
  }) async {
    final srcRoot = Directory(from);
    final dstRoot = Directory(to);
    if (await dstRoot.exists()) await dstRoot.delete(recursive: true);
    await dstRoot.create(recursive: true);

    final files = <File>[];
    await for (final entity in srcRoot.list(recursive: true, followLinks: false)) {
      isCancelled?.call();
      if (entity is File) files.add(entity);
    }

    int done = 0;
    for (final f in files) {
      isCancelled?.call();
      final rel = p.relative(f.path, from: srcRoot.path);
      final target = File(p.join(dstRoot.path, rel));
      await target.parent.create(recursive: true);
      await f.copy(target.path);
      done++;
      if (files.isNotEmpty) {
        onProgress?.call(
          done / files.length,
          '正在复制 $done/${files.length}',
        );
      }
    }
    return done;
  }

  /// 复制一批散图
  static Future<List<String>> copyLooseFiles(
    String bookId,
    List<String> paths, {
    required Directory Function(String) dirFor,
    void Function(double ratio, String label)? onProgress,
    void Function()? isCancelled,
  }) async {
    final out = <String>[];
    for (int i = 0; i < paths.length; i++) {
      isCancelled?.call();
      final src = File(paths[i]);
      if (!await src.exists()) continue;
      // 保留原名，并加序号前缀保证顺序稳定
      final name = '${(i + 1).toString().padLeft(5, '0')}_${p.basename(paths[i])}';
      final dst = File(p.join(dirFor(bookId).path, name));
      await dst.parent.create(recursive: true);
      await src.copy(dst.path);
      out.add(dst.path);
      onProgress?.call((i + 1) / paths.length, '正在复制 ${i + 1}/${paths.length}');
    }
    return out;
  }

  // ------------------------------------------------------------------
  Future<void> deleteBook(String bookId) async {
    final dir = Directory(bookDir(bookId));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 统计某本书占用的磁盘空间
  Future<int> sizeOfBook(String bookId) async {
    final dir = Directory(bookDir(bookId));
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        total += await e.length();
      }
    }
    return total;
  }

  static String _human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String humanSize(int bytes) => _human(bytes);

  /// 生成稳定的书籍 id
  static String newBookId() {
    final r = math.Random();
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = r.nextInt(1 << 32).toRadixString(36);
    return 'b_${ts}_$salt';
  }
}
