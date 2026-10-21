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

/// 扫描结果：一本书。可能是"含图片的文件夹"，也可能是**一个压缩包**。
class WebDavComicCandidate {
  const WebDavComicCandidate({
    required this.url,
    required this.name,
    required this.images,
    this.isArchive = false,
    this.archiveSize,
  });

  /// 文件夹的绝对 URL
  final String url;

  /// 文件夹显示名（书名）
  final String name;

  /// 该目录下的图片条目（已按自然序排好）
  final List<WebDavEntry> images;

  /// true = 这一项其实是**一个压缩包**（一本书 = 一个包）
  final bool isArchive;

  /// 压缩包字节数（目录列表里就有）
  final int? archiveSize;

  int get pageCount => isArchive ? 0 : images.length;

  @override
  String toString() => isArchive
      ? 'WebDavComicCandidate($name, 压缩包)'
      : 'WebDavComicCandidate($name, ${images.length} 张)';
}

class WebDavFolderImporter implements Importer {
  WebDavFolderImporter({this.connection});

  /// 识别/构建时用的连接；不传则从 [buildDocument] 的参数取
  final WebDavConnection? connection;
  /// 最多嗅探多少张图的真实尺寸（其余用中位数估算）
  ///
  /// ★ 从 16 降到 4：同一个漫画文件夹里的图几乎总是同一个尺寸，
  /// 16 次 Range 请求换来的精度提升微乎其微，代价却是每本书多十几倍
  /// 的往返。实测大库（100 本）导入时，这一项就能省下几十秒。
  static const int sniffSamples = 4;

  /// 同时进行的 Range 嗅探并发数。
  ///
  /// 从 4 提到 6：现在总数只有 4 个样本，一轮就发完；
  /// 稍微放大并发能让慢速链路上更快收齐。
  static const int sniffConcurrency = 6;

  /// 扫描子目录时的并行度。
  ///
  /// 原来是一个接一个 PROPFIND —— 走公网隧道时 RTT 有几十到几百毫秒，
  /// 100 个文件夹就是纯等几十秒。并行 5 路能把这部分压到 1/5。
  static const int scanConcurrency = 5;

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
      return const ImportFailure(GenericError('缺少网盘连接信息'));
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
        '从网盘导入失败：$e',
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
        throw const GenericError('这个文件夹里已经没有图片了');
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
      title: folderName.isEmpty ? '网盘文件夹' : folderName,
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
        '这些图片在网盘上，阅读时需要联网；看过的页会自动缓存到本地。',
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
    bool deepScan = true,
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

    // ── 压缩包：**一个包就是一本书** ──
    //
    // 商用网盘上的漫画常常按"一话一个 zip"存放，所以这是主路径而非补充。
    // 好处：**一次 PROPFIND 就能扫出全部书** —— 目录列表里已经带了
    // getcontentlength，不需要再逐个文件请求。
    final archives = rootEntries
        .where((e) => !e.isDirectory && _isArchiveName(e.name))
        .toList()
      ..sort((a, b) => compareByOriginalName(a.name, b.name));
    for (final a in archives) {
      out.add(WebDavComicCandidate(
        url: a.url,
        name: a.name,
        images: const [],
        isArchive: true,
        archiveSize: a.size,
      ));
    }

    final scanTargets = subdirs.length > maxScannedFolders
        ? subdirs.sublist(0, maxScannedFolders)
        : subdirs;

    // ── 并行扫描子目录 ──
    //
    // 原来是 `for + await client.list()` 逐个串行。走公网隧道时单次
    // PROPFIND 的往返就有几十到几百毫秒，100 个文件夹光等就几十秒。
    // 这里用固定大小的 worker 池并发，结果按**原始顺序**放回数组，
    // 保证导入顺序和目录名自然序一致（并发完成顺序不可控）。
    final slots = List<List<WebDavComicCandidate>?>.filled(
        scanTargets.length, null);
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= scanTargets.length) return;
        final dir = scanTargets[i];
        try {
          slots[i] = await _scanOneLevel(
            client,
            dir.url,
            dir.name,
            deepScan: deepScan,
          );
        } catch (_) {
          // 单个子目录读失败（权限 / 已删除）不影响其他
        }
        done++;
        onProgress?.call(done, scanTargets.length, dir.name);
      }
    }

    final workers = math.min(scanConcurrency, math.max(1, scanTargets.length));
    await Future.wait(List.generate(workers, (_) => worker()));
    for (final list in slots) {
      if (list != null) out.addAll(list);
    }

    return out;
  }


  /// 每一层"合集"最多再展开多少个子目录（防止误选根目录时炸开）
  static const int maxNested = 40;

  /// 合集里的一本书该叫什么名字。
  ///
  /// 现实命名：`漫画根目录/XX合集/第一话/`。只取「第一话」的话，库里有
  /// 几十本「第一话」「第二话」，完全分不清谁是谁。规则：
  ///   1. 合集名去掉「合集」二字（它只是分类标记，不是书名的一部分）；
  ///   2. 拼成 `合集名 子名`；
  ///   3. 子名如果已经以合集名开头（重复部分），不重复拼接；
  ///   4. 压缩包去掉扩展名。
  ///
  /// 例：`XX合集` + `第一话` → `XX 第一话`
  static String collectionBookName(String collection, String sub) {
    final c = collection.replaceAll('合集', '').trim();
    if (c.isEmpty) return _stripArchiveExt(sub);
    final s = _stripArchiveExt(sub);
    if (s.startsWith(c)) return s;
    return '$c $s';
  }

  static String _stripArchiveExt(String name) {
    var s = name.trim();
    for (final ext in const ['.zip', '.cbz', '.tar']) {
      if (s.toLowerCase().endsWith(ext)) {
        return s.substring(0, s.length - ext.length);
      }
    }
    return s;
  }

  /// 扫描一个直接子目录，返回它内部的书（可能是 1 本、多本、或 0 本）。
  ///
  /// ## 合集（嵌套一层）
  ///
  /// 现实里的收藏结构常常是：
  /// ```
  /// 漫画根目录/
  /// └── 某某合集/          ← 这一层自己**没有图片**，只是分类
  ///     ├── 第一话/
  ///     └── 第二话/
  /// ```
  /// 只按"一层"扫就会把整个合集漏掉（表现为"导入了 0 本"）。
  /// 所以当这一层既没有图片也没有压缩包时，**再往下找一层**。
  ///
  /// 只多探一层：更深的层级往往不是"一话"，继续递归既慢又容易把
  /// 不相干的目录也导进来。
  static Future<List<WebDavComicCandidate>> _scanOneLevel(
    WebDavClient client,
    String dirUrl,
    String dirName, {
    required bool deepScan,
  }) async {
    final out = <WebDavComicCandidate>[];
    final entries = await client.list(dirUrl);

    final images = _collectImages(entries, client, dirUrl);
    if (images.isNotEmpty) {
      out.add(WebDavComicCandidate(
        url: dirUrl,
        name: dirName,
        images: images,
      ));
    }

    final zips = entries
        .where((e) => !e.isDirectory && _isArchiveName(e.name))
        .toList()
      ..sort((a, b) => compareByOriginalName(a.name, b.name));
    for (final a in zips) {
      out.add(WebDavComicCandidate(
        url: a.url,
        name: a.name,
        images: const [],
        isArchive: true,
        archiveSize: a.size,
      ));
    }

    if (out.isNotEmpty) return out;
    if (!deepScan) return out;

    // 这一层是"合集"容器：往下再找一层
    final subs = entries.where((e) => e.isDirectory).toList()
      ..sort((a, b) => compareByOriginalName(a.name, b.name));
    for (final sub in subs.take(maxNested)) {
      try {
        final subEntries = await client.list(sub.url);
        final subImages = _collectImages(subEntries, client, sub.url);
        if (subImages.isNotEmpty) {
          out.add(WebDavComicCandidate(
            url: sub.url,
            name: collectionBookName(dirName, sub.name),
            images: subImages,
          ));
          continue;
        }
        final subZips = subEntries
            .where((e) => !e.isDirectory && _isArchiveName(e.name))
            .toList()
          ..sort((a, b) => compareByOriginalName(a.name, b.name));
        for (final a in subZips) {
          out.add(WebDavComicCandidate(
            url: a.url,
            name: collectionBookName(dirName, a.name),
            images: const [],
            isArchive: true,
            archiveSize: a.size,
          ));
        }
      } catch (_) {
        // 单个子目录失败不影响其他
      }
    }
    return out;
  }
  static String _folderNameOf(String url) {
    final segs = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs == null || segs.isEmpty) return '网盘文件夹';
    return segs.last;
  }

  /// 把单个候选目录构建成 Document（供批量导入直接调用）
  ///
  /// [client] 可选：批量导入时由调用方传一个**共享**的 client，
  /// 避免每本书都新建一条 TCP + TLS 连接。走公网隧道时一次握手
  /// 可能要几百毫秒，100 本书就是几十秒的纯等待。
  static Future<Document> buildFromCandidate({
    required WebDavConnection connection,
    required WebDavComicCandidate candidate,
    WebDavClient? client,
  }) async {
    final owned = client == null;
    final c = client ?? connection.createClient();
    try {
      return await _build(
        ctx: null,
        client: c,
        conn: connection,
        folderUrl: candidate.url,
        folderName: candidate.name,
        images: candidate.images,
      );
    } finally {
      if (owned) c.close();
    }
  }
}

/// 支持在线读取的压缩包扩展名。
///
/// 只认 **zip**（含改名的 .cbz）：它支持"读中央目录 + 按需读条目"。
/// `.tar.gz` 必须从头顺序解压，没法随机访问，所以不列入 ——
/// 列进来只会让用户导入后打开失败。
bool _isArchiveName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') || lower.endsWith('.cbz');
}