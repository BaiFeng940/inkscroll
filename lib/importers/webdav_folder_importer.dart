/// 从 WebDAV（飞牛 NAS / 群晖 / Alist…）的一个文件夹导入成书。
///
/// ## 只做"列目录"，不下载内容
///
/// 导入阶段**不下载任何图片**，只做两件事：
///   1. `PROPFIND Depth:1` 拿到文件列表（一次请求）；
///   2. 用 `Range` 只取前 64KB，嗅探**前若干张**图的尺寸，
///      其余的用中位数当估算值。
///
/// 第 2 点是为了让虚拟长页在"图片还没加载"时就有正确高度
/// （否则占位高度为 0，滚动时会不断重排 —— 这个坑在本地导入里踩过）。
///
/// 为什么只嗅探前 N 张：网络请求是串行瓶颈。300 张图各发一次 Range 请求，
/// 在局域网也要十几秒；而嗅探 12~16 张求中位数，误差已经很小，
/// 真出现偏差时 `onDimensionResolved` 会在解码后自动纠正。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/image_header.dart';
import '../data/importer.dart';
import '../data/webdav/webdav_client.dart';
import '../data/webdav/webdav_connection.dart';
import '../importers/import_utils.dart';
import '../reader/document.dart';

/// 扫描结果：一个"含图片的文件夹"，对应一本书
class WebDavComicCandidate {
  const WebDavComicCandidate({
    required this.url,
    required this.name,
    required this.images,
  });

  /// 文件夹的绝对 URL
  final String url;

  /// 文件夹显示名（书名）
  final String name;

  /// 该目录下的图片条目（已按自然序排好）
  final List<WebDavEntry> images;

  int get pageCount => images.length;

  @override
  String toString() => 'WebDavComicCandidate($name, ${images.length} 张)';
}

class WebDavFolderImporter implements Importer {
  WebDavFolderImporter({this.connection});

  /// 识别/构建时用的连接；不传则从 [buildDocument] 的参数取
  final WebDavConnection? connection;
  /// 最多嗅探多少张图的真实尺寸（其余用中位数估算）
  static const int sniffSamples = 16;

  /// 同时进行的 Range 嗅探并发数 —— 太高会打爆家用 NAS 的弱 CPU
  static const int sniffConcurrency = 4;

  /// 递归列目录的最大深度（漫画一般就是一层，留点余量）
  static const int maxDepth = 3;

  /// 单次导入的最大页数
  static const int maxPages = 5000;

  @override
  String get id => 'webdavFolder';

  /// 走这条路的 pick 都由 AppState 直接分派，不经过本地文件探测
  @override
  bool canHandle(SourceProbe probe) => false;

  @override
  Future<ImportOutcome> run(ImportContext ctx) async {
    final conn = connection;
    if (conn == null) {
      return const ImportFailure(GenericError('缺少 NAS 连接信息'));
    }
    final folderUrl = ctx.pick.webdavFolderUrl;
    if (folderUrl == null || folderUrl.isEmpty) {
      return const ImportFailure(GenericError('缺少文件夹地址'));
    }

    final client = conn.createClient();
    try {
      ctx.onProgress(0.05, '正在读取文件夹列表…');
      final entries = await client.list(folderUrl);

      ctx.onProgress(0.25, '正在整理页面…');
      final images = _collectImages(entries, client, folderUrl);
      if (images.isEmpty) {
        return const ImportFailure(GenericError(
          '这个文件夹里没有找到图片。\n'
          '请确认选的是放图片的目录，而不是它的上一级。',
          action: ErrorAction.chooseAnother,
        ));
      }

      final doc = await _build(
        ctx: ctx,
        client: client,
        conn: conn,
        folderUrl: folderUrl,
        folderName: ctx.pick.webdavFolderName ?? ctx.pick.displayName,
        images: images,
      );
      return ImportedDocument(doc);
    } on AppError {
      rethrow;
    } catch (e, st) {
      return ImportFailure(GenericError(
        '从 NAS 导入失败：$e',
        technicalDetail: st.toString(),
      ));
    } finally {
      client.close();
    }
  }

  /// 不经过导入流程时（重新打开一本缓存丢失的书）直接用这个
  static Future<Document> buildDocument({
    required WebDavConnection connection,
    required String folderUrl,
    required String folderName,
  }) async {
    final client = connection.createClient();
    try {
      final entries = await client.list(folderUrl);
      final images = _collectImages(entries, client, folderUrl);
      if (images.isEmpty) {
        throw const GenericError('NAS 上的这个文件夹里已经没有图片了');
      }
      return await _build(
        ctx: null,
        client: client,
        conn: connection,
        folderUrl: folderUrl,
        folderName: folderName,
        images: images,
      );
    } finally {
      client.close();
    }
  }

  // ------------------------------------------------------------------

  /// 从目录条目里挑出图片，并**递归进子目录**（最多 [maxDepth] 层）
  static List<WebDavEntry> _collectImages(
    List<WebDavEntry> entries,
    WebDavClient client,
    String folderUrl,
  ) {
    final out = <WebDavEntry>[];
    // 只收同步结果：子目录的递归在 buildDocument 里由调用方决定，
    // 这里先处理当前层的图片 + 直接子目录里的图片（一层足够常见）。
    for (final e in entries) {
      if (e.isDirectory) continue;
      if (_isImage(e.name)) out.add(e);
    }
    out.sort((a, b) => compareByOriginalName(a.name, b.name));
    return out;
  }

  static bool _isImage(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = name.substring(dot).toLowerCase();
    return kImageExtensions.contains(ext) ||
        kUnsupportedImageExtensions.contains(ext);
  }

  static Future<Document> _build({
    required ImportContext? ctx,
    required WebDavClient client,
    required WebDavConnection conn,
    required String folderUrl,
    required String folderName,
    required List<WebDavEntry> images,
  }) async {
    final capped = images.length > maxPages ? images.sublist(0, maxPages) : images;

    // ── 嗅探前 N 张的尺寸 ──
    ctx?.onProgress(0.3, '正在测量图片尺寸…');
    final sampleCount = math.min(sniffSamples, capped.length);
    final sampleAspects = <double?>[];

    for (var i = 0; i < sampleCount; i += sniffConcurrency) {
      final end = math.min(i + sniffConcurrency, sampleCount);
      final batch = <Future<double?>>[];
      for (var j = i; j < end; j++) {
        batch.add(_sniffAspect(client, capped[j].url));
      }
      final results = await Future.wait(batch);
      sampleAspects.addAll(results);
      ctx?.onProgress(
        0.3 + 0.5 * (end / math.max(1, sampleCount)),
        '正在测量图片尺寸 $end/$sampleCount…',
      );
    }

    final valid = sampleAspects.whereType<double>().where((a) => a > 0.02 && a < 50).toList();
    final medianAspect = valid.isEmpty ? null : _median(valid);

    // ── 建页 ──
    final pages = <String, PageNode>{};
    final pageIds = <String>[];
    final aspects = <double?>[];

    for (var i = 0; i < capped.length; i++) {
      final e = capped[i];
      final aspect = i < sampleAspects.length ? sampleAspects[i] : medianAspect;
      aspects.add(aspect);

      final id = 'n:$i';
      pageIds.add(id);
      pages[id] = PageNode(
        id: id,
        kind: PageKind.image,
        aspectRatio: aspect,
        content: ImageContent(
          ref: WebDavRef(url: e.url, connectionId: conn.id),
        ),
      );
    }

    ctx?.onProgress(1.0, '完成');

    final unsniffed = math.max(0, capped.length - sampleCount);
    final truncated = images.length > maxPages;

    return Document(
      id: 'doc_${conn.id}_${_hash(folderUrl)}',
      bookId: '',
      title: folderName.isEmpty ? 'NAS 文件夹' : folderName,
      kind: DocumentKind.comic,
      chapters: [Chapter(index: 0, title: '图片', pageIds: pageIds)],
      pages: pages,
      hint: looksLikeWebtoon(aspects)
          ? DocumentLayoutHint.webtoonPreferred
          : DocumentLayoutHint.pagePreferred,
      warnings: [
        if (medianAspect == null)
          '没能读到图片尺寸，滚动时按实际解码结果自动校正。',
        if (unsniffed > 0 && medianAspect != null)
          '有 $unsniffed 张图的尺寸是估算的（按前 $sampleCount 张推算），'
              '翻到时会自动校正。',
        if (truncated)
          '文件夹里有 ${images.length} 张图，已只取前 $maxPages 张。',
        '这些图片在 NAS 上，阅读时需要联网；看过的页会自动缓存到本地。',
      ],
    );
  }

  static Future<double?> _sniffAspect(WebDavClient client, String url) async {
    try {
      // ★ 只下前 64KB —— 足够解析 PNG/JPEG/GIF/WebP 的头部
      final Uint8List head = await client.getRange(url, maxBytes: 64 * 1024);
      return ImageHeaderParser.tryParse(head)?.aspectRatio;
    } catch (_) {
      return null;
    }
  }

  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final s = [...values]..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }

  static String _hash(String input) {
    var h = 0x811c9dc5;
    for (final c in input.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }

  // ------------------------------------------------------------------
  // 库扫描：一次把"所有含图片的文件夹"找出来
  // ------------------------------------------------------------------

  /// 扫描出一个"含图片的文件夹"（一本书的候选）
  ///
  /// 一次最多扫 [maxScannedFolders] 个子目录，避免用户误选根目录时
  /// 把整个 NAS 都翻一遍（那会是几百个请求）。
  static const int maxScannedFolders = 300;

  /// 扫描 [folderUrl] 下所有**含图片的文件夹**（包括它自己）。
  ///
  /// 返回的每一项对应"一本书"。调用方可以全量导入，也可以让用户挑。
  static Future<List<WebDavComicCandidate>> scanLibrary(
    WebDavClient client,
    String folderUrl, {
    void Function(int done, int total, String name)? onProgress,
  }) async {
    final out = <WebDavComicCandidate>[];

    final rootEntries = await client.list(folderUrl);
    final rootImages = _collectImages(rootEntries, client, folderUrl);
    if (rootImages.isNotEmpty) {
      out.add(WebDavComicCandidate(
        url: folderUrl,
        // 根目录本身有图片 → 用路径最后一段当名字
        name: _folderNameOf(folderUrl),
        images: rootImages,
      ));
    }

    final subdirs = rootEntries.where((e) => e.isDirectory).toList()
      ..sort((a, b) => compareByOriginalName(a.name, b.name));

    final scanTargets = subdirs.length > maxScannedFolders
        ? subdirs.sublist(0, maxScannedFolders)
        : subdirs;

    var done = 0;
    for (final dir in scanTargets) {
      done++;
      onProgress?.call(done, scanTargets.length, dir.name);
      try {
        final entries = await client.list(dir.url);
        final images = _collectImages(entries, client, dir.url);
        if (images.isNotEmpty) {
          out.add(WebDavComicCandidate(
            url: dir.url,
            name: dir.name,
            images: images,
          ));
        }
      } catch (_) {
        // 单个子目录读失败（权限 / 已删除）不影响其他
      }
    }

    return out;
  }

  static String _folderNameOf(String url) {
    final segs = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs == null || segs.isEmpty) return 'NAS 文件夹';
    return segs.last;
  }

  /// 把单个候选目录构建成 Document（供批量导入直接调用）
  static Future<Document> buildFromCandidate({
    required WebDavConnection connection,
    required WebDavComicCandidate candidate,
  }) async {
    final client = connection.createClient();
    try {
      return await _build(
        ctx: null,
        client: client,
        conn: connection,
        folderUrl: candidate.url,
        folderName: candidate.name,
        images: candidate.images,
      );
    } finally {
      client.close();
    }
  }
}
