/// 把**网盘上的压缩包**建成一本书（Document）。
///
/// ## 核心思路
///
/// 复用现成的 `ZipArchiveSource`：只要给它一个"能任意偏移读远端字节"的
/// `WebDavByteSource`，本地包和网盘包走的是**完全相同的解析代码**。
/// 不需要为网盘另写一套 ZIP 解析。
///
/// ## 为什么嗅探预算要小得多
///
/// 本地包的尺寸嗅探是"解压 360 张图的头部"，因为读磁盘几乎免费。
/// 网盘上每取一页都要走网络 —— 360 张就是 360 次请求，可能几十 MB。
/// 所以这里只嗅 **≤6 张**（前 3 + 抽样 3），其余用中位数兜底；
/// 翻到没嗅过的页时，解码器会用真实尺寸自愈（布局会微调一次）。
///
/// ## 这个文件不依赖 Flutter
///
/// 所以 `tool/probe_zip_webdav.dart` 能直接 `dart run` 验证它。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/errors.dart';
import '../data/archive/archive_source.dart';
import '../data/archive/zip_archive_source.dart';
import '../data/webdav/webdav_byte_source.dart';
import '../data/webdav/webdav_client.dart';
import '../reader/document.dart';
import 'import_utils.dart';

class WebDavArchiveImporter {
  const WebDavArchiveImporter._();

  /// 网盘包最多嗅探多少张图的真实尺寸。
  ///
  /// 同目录的漫画图几乎总是同一尺寸，3 个样本（首/中/尾）足够得到
  /// 可信中位数；再往上加只是拿流量换精度，不划算。
  /// 0.15.3 又降了一档：建册提速，布局差异交给解码后自愈。
  static const int sniffSamples = 3;

  /// 嗅探并发。网盘一般能承受 3~4 路；再高容易触发限流。
  static const int sniffConcurrency = 4;

  /// 一张图最多读多少字节来解析头部（网盘上按 Range 只取这么多）
  static const int sniffHeadBytes = 96 * 1024;

  /// 单本最大页数
  static const int maxPages = 5000;

  /// 只用 URL + 连接信息就能建好这本书。
  ///
  /// [knownSize] 来自目录列表的 `getcontentlength`，省一次 PROPFIND。
  static Future<Document> buildDocument({
    required WebDavClient client,
    required String connectionId,
    required String archiveUrl,
    required String archiveName,
    int? knownSize,
    String? password,
    void Function(double progress, String label)? onProgress,
  }) async {
    try {
      onProgress?.call(0.1, '正在读取压缩包目录…');
      final src = WebDavByteSource(
        url: archiveUrl,
        client: client,
        knownSize: knownSize,
      );
      final zip = ZipArchiveSource(src, password: password);
      try {
        await zip.open();

        final images = zip.entries
            .where((e) => kImageExtensions.contains(_ext(e.entryPath)))
            .toList()
          ..sort((a, b) => compareByOriginalName(a.entryPath, b.entryPath));

        if (images.isEmpty) {
          throw const GenericError(
            '这个压缩包里没有图片。\n'
            '请确认是漫画包（zip/cbz），而不是文档或视频包。',
          );
        }

        final capped =
            images.length > maxPages ? images.sublist(0, maxPages) : images;

        // ── 嗅探少量样本 ──
        onProgress?.call(0.3, '正在测量图片尺寸…');
        final targets = _pickSamples(capped);
        final aspectsByPath = <String, double?>{};
        for (var i = 0; i < targets.length; i += sniffConcurrency) {
          final end = math.min(i + sniffConcurrency, targets.length);
          final batch = <Future<double?>>[];
          for (var j = i; j < end; j++) {
            batch.add(_sniffAspect(zip, targets[j]));
          }
          final results = await Future.wait(batch);
          for (var k = 0; k < results.length; k++) {
            aspectsByPath[targets[i + k].entryPath] = results[k];
          }
          onProgress?.call(
            0.3 + 0.5 * (end / math.max(1, targets.length)),
            '正在测量图片尺寸 $end/${targets.length}…',
          );
        }

        final valid = aspectsByPath.values
            .whereType<double>()
            .where((a) => a > 0.02 && a < 50)
            .toList();
        final medianAspect = _median(valid);

        // ── 建页 ──
        onProgress?.call(0.9, '正在整理页面…');
        final pages = <String, PageNode>{};
        final pageIds = <String>[];
        final aspects = <double?>[];
        for (var i = 0; i < capped.length; i++) {
          final e = capped[i];
          final aspect = aspectsByPath[e.entryPath] ?? medianAspect;
          aspects.add(aspect);
          final id = 'n:$i';
          pageIds.add(id);
          pages[id] = PageNode(
            id: id,
            kind: PageKind.image,
            aspectRatio: aspect,
            content: ImageContent(
              ref: WebDavArchiveRef(
                connectionId: connectionId,
                archiveUrl: archiveUrl,
                entryPath: e.entryPath,
                password: password,
              ),
            ),
          );
        }

        final unsniffed = capped.length - targets.length;
        final truncated = images.length > maxPages;

        onProgress?.call(1.0, '完成');
        return Document(
          id: 'doczip_${connectionId}_${_hash(archiveUrl)}',
          bookId: '',
          title: archiveName.isEmpty ? '网盘压缩包' : archiveName,
          kind: DocumentKind.comic,
          chapters: [Chapter(index: 0, title: '图片', pageIds: pageIds)],
          pages: pages,
          hint: looksLikeWebtoon(aspects)
              ? DocumentLayoutHint.webtoonPreferred
              : DocumentLayoutHint.pagePreferred,
          warnings: [
            if (medianAspect == null) '没能读到图片尺寸，滚动时按实际解码结果自动校正。',
            if (unsniffed > 0 && medianAspect != null)
              '有 $unsniffed 张图的尺寸是估算的（按 ${targets.length} 张抽样推算），'
                  '翻到时会自动校正。',
            if (truncated) '压缩包里有 ${images.length} 张图，已只取前 $maxPages 张。',
            '图片在网盘上的压缩包里，阅读时按需下载单页并缓存；'
                '不会下载整个压缩包。',
          ],
        );
      } finally {
        await zip.close();
      }
    } on AppError {
      rethrow;
    } catch (e, st) {
      throw GenericError(
        '读取网盘压缩包失败：$e',
        technicalDetail: st.toString(),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 加密包：密码自愈（0.15.3）
  // ---------------------------------------------------------------------------

  /// 建册前的密码自愈。
  ///
  /// 1. 依次试 [password]（书源里固化的）→ [guesses]（密码字典），
  ///    每个候选只做「开中央目录 + 1KB 试读」判对错（见 [probePassword]）；
  /// 2. 命中的密码用来建册并随 (Document, 密码) 返回，调用方固化进书源；
  /// 3. 全部失败 → 抛 [ArchivePasswordRequiredError]，阅读器据此弹密码框。
  ///
  /// 未加密的包：第一个候选直接探过，几乎零额外代价。
  /// 注意 [_sniffAspect] 会把密码错误吞成 null（当成"尺寸未知"），
  /// 所以加密检测必须在这层做，不能指望 buildDocument 抛错。
  static Future<(Document, String?)> buildDocumentWithGuesses({
    required WebDavClient client,
    required String connectionId,
    required String archiveUrl,
    required String archiveName,
    int? knownSize,
    String? password,
    List<String> guesses = const [],
    void Function(double progress, String label)? onProgress,
  }) async {
    final candidates = <String?>[
      password,
      ...guesses.where((g) => g.isNotEmpty && g != password),
    ];
    Object? last;
    for (final pwd in candidates) {
      final ok = await probePassword(
        client: client,
        archiveUrl: archiveUrl,
        knownSize: knownSize,
        password: pwd,
      );
      if (!ok) {
        last = pwd == null
            ? const ArchivePasswordRequiredError()
            : const ArchivePasswordWrongError();
        continue;
      }
      final doc = await buildDocument(
        client: client,
        connectionId: connectionId,
        archiveUrl: archiveUrl,
        archiveName: archiveName,
        knownSize: knownSize,
        password: pwd,
        onProgress: onProgress,
      );
      return (doc, pwd);
    }
    if (last is AppError) throw last;
    throw const ArchivePasswordRequiredError();
  }

  /// 用给定密码开包并试读第一个加密条目（≤1KB）。
  /// true = 密码可用（或包内没有加密条目）；false = 缺失/不正确/不支持。
  static Future<bool> probePassword({
    required WebDavClient client,
    required String archiveUrl,
    int? knownSize,
    String? password,
  }) async {
    final src = WebDavByteSource(
      url: archiveUrl,
      client: client,
      knownSize: knownSize,
    );
    final zip = ZipArchiveSource(src, password: password);
    try {
      await zip.open();
      final encrypted =
          zip.entries.where((e) => e.isEncrypted && !e.isDirectory);
      if (encrypted.isEmpty) return true;
      await zip.readEntry(encrypted.first, maxBytes: 1024);
      return true;
    } on ArchivePasswordWrongError {
      return false;
    } on ArchivePasswordRequiredError {
      // AES 等不支持的加密形式也会走到这里
      return false;
    } finally {
      await zip.close();
    }
  }

  /// 抽样策略：均匀取 [sniffSamples] 张（首张必中：第一页最常先看）。
  static List<ArchiveEntryInfo> _pickSamples(List<ArchiveEntryInfo> all) {
    if (all.length <= sniffSamples) return all;
    final picked = <int>{
      for (var i = 0; i < sniffSamples; i++)
        (all.length - 1) * i ~/ (sniffSamples - 1),
    };
    final list = picked.where((i) => i >= 0 && i < all.length).toList()..sort();
    return list.map((i) => all[i]).toList();
  }

  static Future<double?> _sniffAspect(
    ZipArchiveSource zip,
    ArchiveEntryInfo entry,
  ) async {
    try {
      final head = await zip.readEntry(entry, maxBytes: sniffHeadBytes);
      return _aspectOf(head);
    } catch (_) {
      return null;
    }
  }

  /// 从图片头部解析宽高比。识别不了就返回 null（交给中位数兜底）。
  static double? _aspectOf(Uint8List b) {
    // PNG: 16..24 是 IHDR 的宽高（大端 32 位）
    if (b.length > 24 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      if (w > 0 && h > 0) return w / h;
      return null;
    }
    // JPEG: 扫描 SOF 段
    if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        if (marker == 0xD8 ||
            marker == 0x01 ||
            (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2;
          continue;
        }
        final segLen = (b[i + 2] << 8) | b[i + 3];
        if (segLen < 2) return null;
        // SOF0..SOF15（排除 DHT=C4, JPG=C8, DAC=CC）
        if (marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          if (w > 0 && h > 0) return w / h;
          return null;
        }
        i += 2 + segLen;
      }
      return null;
    }
    // GIF: 6..10 是宽高（小端 16 位）
    if (b.length > 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      final w = b[6] | (b[7] << 8);
      final h = b[8] | (b[9] << 8);
      if (w > 0 && h > 0) return w / h;
    }
    return null;
  }

  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final s = [...values]..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }

  static String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i).toLowerCase();
  }

  static String _hash(String input) {
    var h = 0x811c9dc5;
    for (final c in input.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }
}
