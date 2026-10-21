/// 压缩包导入（zip / tar）。本项目的技术核心。
///
/// 关键约束的落地方式：
///   ✗ 不解压整个包   → 只读中央目录（ZipArchiveSource.open）
///   ✗ 不一次性加载   → 每页只解出前 256KB 用于尺寸嗅探
///   ✗ 不合成大图     → 每页独立成 PageNode，阅读器逐页渲染
///
/// 尺寸嗅探是虚拟长页能工作的前提：
///   有了每页的 aspectRatio，PageMetrics 就能在不加载任何图片的情况下
///   算出整条长页的总高度 —— 进度条、百分比跳转因此才成立。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../core/image_header.dart';
import '../data/archive/archive_source.dart';
import '../data/archive/tar_archive_source.dart';
import '../data/archive/zip_archive_source.dart';
import '../data/byte_source.dart';
import '../data/byte_store.dart';
import '../data/importer.dart';
import '../reader/document.dart';
import 'import_utils.dart';
import 'text_parser.dart';

/// 尺寸嗅探的解压预算：只解这么多字节就够拿到图片头。
/// 实际使用时会按张数自适应下调（图越多，每张读得越少），保证总解压量有界。
const int kDimensionSniffBudget = 256 * 1024;

class ArchiveImporter implements Importer {
  ArchiveImporter({required this.store});

  final ByteStore store;

  @override
  String get id => 'archive';

  @override
  bool canHandle(SourceProbe probe) =>
      probe.formatName == 'zip' || probe.formatName == 'tar';

  @override
  Future<ImportOutcome> run(ImportContext ctx) async {
    final srcPath = ctx.pick.path;
    if (srcPath == null) {
      return const ImportFailure(GenericError('没有选择文件'));
    }

    // ── 第 1 步：复制到 app 私有目录（file_picker 给的是临时缓存路径）──
    final bookId = ctx.pick.sourceId;
    final dstPath = store.archivePathFor(bookId, p.basename(srcPath));
    final needsCopy = !await File(dstPath).exists();
    if (needsCopy) {
      ctx.onProgress(0.0, '正在复制压缩包…');
      await ByteStore.copyFile(
        srcPath,
        dstPath,
        onProgress: (r, label) => ctx.onProgress(r * 0.35, label),
      );
    }

    // ── 第 2 步：打开压缩包，只读中央目录 ──
    ctx.onProgress(0.36, '正在读取压缩包目录…');
    final byteSource = await FileByteSource.open(dstPath);

    ArchiveSource source;
    try {
      source = await _openSource(byteSource, dstPath, password: ctx.password);
    } on NotAnArchiveError {
      await byteSource.close();
      return const ImportFailure(NotAnArchiveError());
    } catch (e) {
      await byteSource.close();
      return ImportFailure(GenericError('打开压缩包失败：$e'));
    }

    try {
      // 加密检测：没有密码 → 让 UI 弹密码框；
      // 已经有密码但条目仍标记为加密 → 说明我们无法解密（纯 Dart 不支持），
      // 交给 readEntry 抛出明确的可操作错误。
      final encrypted = source.entries.where((e) => e.isEncrypted).isNotEmpty;
      if (encrypted && (ctx.password == null || ctx.password!.isEmpty)) {
        return NeedPassword(attempt: ctx.passwordAttempt);
      }

      // ── 第 3 步：过滤 + 分类 ──
      final files = source.entries.where((e) => !e.isDirectory).toList();
      final images = files.where((e) => isImagePath(e.entryPath)).toList();
      final texts = files.where((e) => isTextPath(e.entryPath)).toList();

      if (images.isEmpty && texts.isEmpty) {
        // 嵌套压缩包 / 不支持的内容 → 给出明确原因
        final nested =
            files.where((e) => isArchivePath(e.entryPath)).map((e) => e.entryPath).toList();
        if (nested.isNotEmpty) {
          return ImportFailure(GenericError(
            '压缩包里套着压缩包（${nested.first}）。'
            '建议先解出内层压缩包再单独导入。',
          ));
        }
        return const ImportFailure(ImportEmptyError());
      }

      // ── 第 4 步：图片为主 → 漫画；文本为主 → 小说 ──
      if (images.length >= 3 && images.length >= texts.length) {
        return ImportedDocument(await _buildComic(ctx, source, images, dstPath));
      }
      if (texts.isNotEmpty) {
        return ImportedDocument(await _buildNovel(ctx, source, texts, dstPath));
      }
      return ImportedDocument(await _buildComic(ctx, source, images, dstPath));
    } finally {
      await source.close();
    }
  }

  Future<ArchiveSource> _openSource(
    RandomAccessByteSource byteSource,
    String path, {
    String? password,
  }) async {
    final lower = path.toLowerCase();
    if (lower.endsWith('.tar')) {
      final tar = TarArchiveSource(byteSource);
      await tar.open();
      return tar;
    }
    final zip = ZipArchiveSource(byteSource, password: password);
    await zip.open();
    return zip;
  }

  // ------------------------------------------------------------------
  // 漫画：目录 → 章，条目 → 页
  // ------------------------------------------------------------------
  Future<Document> _buildComic(
    ImportContext ctx,
    ArchiveSource source,
    List<ArchiveEntryInfo> images,
    String archivePath,
  ) async {
    // 分章：按目录分组
    final groups = <String, List<ArchiveEntryInfo>>{};
    for (final e in images) {
      groups.putIfAbsent(e.parentDir, () => []).add(e);
    }

    // 单章过长 → 按每 100 页切分，避免"一章一万页"导致章节导航失效
    final orderedDirs = groups.keys.toList()
      ..sort((a, b) => naturalComparePath(a, b));

    final pages = <String, PageNode>{};
    final chapters = <Chapter>[];
    final aspects = <double?>[];

    final total = images.length;

    // ── 尺寸嗅探策略（这是"压缩包导入太慢"的核心修复）──
    //
    // 先说清真正的瓶颈：
    //   为了读几十字节的图片头，必须 DEFLATE 解压条目。而 DEFLATE 是流式的 ——
    //   想要前 100KB 的输出，无法只读压缩数据的前 10KB（没有可靠的字节对应关系），
    //   只能从头解。所以 `readEntry(maxBytes: 256KB)` 省的是**拷贝**，
    //   省不掉**解压**：一张 5MB 的漫画页，光为了拿尺寸就要解压 5MB。
    //   500 张图 = 解压几 GB → 用户体感"导入太慢"。
    //
    // 修复：**不再全量嗅探，改为"前段精确 + 全篇抽样"**。
    //
    //   ① 前 [kSniffHeadCount] 张全部嗅探 —— 这些是用户打开后最先看到的页，
    //      必须精确，否则长页一进去就是错位 + 自愈跳动。
    //   ② 其余按固定间隔抽样 —— 用来估计"这本书的整体页面比例中位数"
    //      和判断是否 Webtoon 模式（只需要统计量，不需要每页都精确）。
    //   ③ 未抽到的页用中位数兜底。阅读时 PageImage 会在真实解码后
    //      **自愈回填**（见 page_image.dart 的 onDimensionResolved），
    //      所以位置会随阅读进度自动校正。
    //
    //   代价：未抽到的页首次显示时高度是估计值，滚过去的一瞬间可能微调。
    //   收益：导入 I/O 与 CPU 从"解压整包"降到"解压约 N 张"，
    //        几千页的包从分钟级降到秒级。
    const kSniffHeadCount = 120;
    const kSniffSampleTarget = 240;

    List<ArchiveEntryInfo> toSniff;
    if (total <= kSniffHeadCount + kSniffSampleTarget) {
      toSniff = images; // 图不多，全量精确
    } else {
      final indices = <int>{
        // 前段：精确覆盖用户最先看到的部分
        for (int i = 0; i < kSniffHeadCount; i++) i,
        // 全篇均匀抽样：保证能拿到整体比例中位数与 Webtoon 判定
        for (int k = 1; k <= kSniffSampleTarget; k++)
          (k * (total - 1) / (kSniffSampleTarget + 1)).round(),
      };
      toSniff = (indices.where((i) => i >= 0 && i < total).toList()..sort())
          .map((i) => images[i])
          .toList();
    }

    final sniffBudgetBytes = total > 6000
        ? 48 * 1024
        : (total > 2000 ? 96 * 1024 : kDimensionSniffBudget);

    ctx.onProgress(
      0.38,
      total <= toSniff.length
          ? '正在分析图片尺寸 0/${toSniff.length}…'
          : '正在分析图片尺寸 0/${toSniff.length}（共 $total 页，抽样）…',
    );
    final sniffedValues = await mapConcurrent<ArchiveEntryInfo, double?>(
      toSniff,
      concurrency: 8,
      task: (e) => _sniffAspect(source, e, sniffBudgetBytes),
      onProgress: (done) {
        if (done % 25 == 0 || done == toSniff.length) {
          ctx.onProgress(
            0.38 + 0.58 * (done / math.max(1, toSniff.length)),
            '正在分析图片尺寸 $done/${toSniff.length}…',
          );
        }
      },
    );

    // 抽样得到的中位数：给未抽到的页做兜底，并用于 Webtoon 判定
    final sniffedAspects = sniffedValues.whereType<double>().toList();
    final medianAspect = _median(sniffedAspects);

    final aspectByEntry = <String, double?>{};
    for (int i = 0; i < toSniff.length; i++) {
      aspectByEntry[toSniff[i].entryPath] = sniffedValues[i];
    }
    // 未抽到的页：先用中位数兜底（阅读时会自愈为真实值）
    for (final e in images) {
      aspectByEntry.putIfAbsent(e.entryPath, () => medianAspect);
    }

    int chapterIndex = 0;
    for (final dir in orderedDirs) {
      final list = groups[dir]!
        ..sort((a, b) => naturalComparePath(a.entryPath, b.entryPath));

      // 单章 > 200 页时切分
      final slices = list.length > 200 ? chunk(list, 100) : [list];

      for (final slice in slices) {
        final pageIds = <String>[];
        for (final e in slice) {
          final id = 'p:${e.entryPath}';
          final aspect = aspectByEntry[e.entryPath];
          aspects.add(aspect);

          pages[id] = PageNode(
            id: id,
            kind: PageKind.image,
            aspectRatio: aspect,
            content: ImageContent(
              ref: ArchiveEntryRef(
                archivePath: archivePath,
                entryPath: e.entryPath,
                uncompressedSize: e.uncompressedSize,
              ),
              intrinsicWidth: null,
              intrinsicHeight: null,
              mimeType: _mimeOf(e.entryPath),
            ),
          );
          pageIds.add(id);
        }

        final sliceLabel = slices.length > 1
            ? '${chapterTitleFromDir(dir)}（${chapterIndex + 1}）'
            : chapterTitleFromDir(dir);

        chapters.add(Chapter(
          index: chapterIndex,
          title: sliceLabel,
          pageIds: pageIds,
          coverRef: (pages[pageIds.first]!.content as ImageContent).ref,
        ));
        chapterIndex++;
      }
    }

    ctx.onProgress(1.0, '完成');

    final webtoon = looksLikeWebtoon(aspects);
    final isSampled = toSniff.length < total;
    final sniffFailCount =
        sniffedValues.where((v) => v == null).length;

    return Document(
      id: 'doc_${ctx.pick.sourceId}',
      bookId: ctx.pick.sourceId,
      title: ctx.pick.displayName,
      kind: DocumentKind.comic,
      chapters: chapters,
      pages: pages,
      unit: ReadingUnit.page,
      hint: webtoon
          ? DocumentLayoutHint.webtoonPreferred
          : DocumentLayoutHint.pagePreferred,
      warnings: [
        if (isSampled)
          '共 $total 页，已精确测量前 $kSniffHeadCount 页并对全篇抽样'
              '（${toSniff.length} 页）。其余页按中位比例排版，'
              '滚动到时自动校正 —— 这是为了让大压缩包能秒开。',
        if (sniffFailCount > 0 && !isSampled)
          '有 $sniffFailCount 页未取到尺寸（图片可能损坏或格式特殊），'
              '滚动到该页时会自动测量。',
        if (sniffedAspects.isEmpty && total > 0)
          '未能解析出任何页面尺寸，已使用默认比例，阅读位置可能略有偏差。',
      ],
    );
  }

  /// 中位数：给未抽样的页做比例兜底
  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// ★ 只解出压缩包内该条目的前若干字节，解析图片头部得到宽高。
  /// 这一步完全不解码像素，成本极低。
  Future<double?> _sniffAspect(
    ArchiveSource source,
    ArchiveEntryInfo entry,
    int budget,
  ) async {
    try {
      final head = await source.readEntry(entry, maxBytes: budget);
      final dim = ImageHeaderParser.tryParse(head);
      return dim?.aspectRatio;
    } on AppError {
      // 尺寸嗅探失败不该让整本书导入失败
      return null;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------
  // 小说：txt 条目 → 分章 → 分页
  // ------------------------------------------------------------------
  Future<Document> _buildNovel(
    ImportContext ctx,
    ArchiveSource source,
    List<ArchiveEntryInfo> texts,
    String archivePath,
  ) async {
    final sorted = texts.toList()
      ..sort((a, b) => naturalComparePath(a.entryPath, b.entryPath));

    final pages = <String, PageNode>{};
    final chapters = <Chapter>[];
    final warnings = <String>[];

    int chapterIndex = 0;
    for (int i = 0; i < sorted.length; i++) {
      final e = sorted[i];
      ctx.onProgress(0.4 + 0.55 * (i / sorted.length), '正在解码 ${e.baseName}');

      // 文本条目通常不大，但也要有上限保护
      final Uint8List bytes;
      try {
        bytes = await source.readEntry(e, maxBytes: 64 << 20);
      } on AppError catch (err) {
        warnings.add('跳过 ${e.entryPath}：${err.message}');
        continue;
      }

      final parsed = parsePlainText(bytes, e.entryPath);
      warnings.addAll(parsed.warnings);

      for (final textChapter in parsed.chapters) {
        final pageIds = <String>[];
        for (int j = 0; j < textChapter.pages.length; j++) {
          final id = 't:${e.entryPath}#${textChapter.title}#$j';
          pages[id] = PageNode(
            id: id,
            kind: PageKind.text,
            content: TextPageContent(
              text: textChapter.pages[j],
              headingLevel: j == 0 ? 1 : null,
              // 全书字符偏移：改字号重新分页时用它做锚点
              pageStartCharOffset:
                  textChapter.startCharOffset + textChapter.pageCharOffsets[j],
            ),
          );
          pageIds.add(id);
        }
        chapters.add(Chapter(
          index: chapterIndex,
          title: sorted.length > 1
              ? '${e.baseName} · ${textChapter.title}'
              : textChapter.title,
          pageIds: pageIds,
        ));
        chapterIndex++;
      }
    }

    ctx.onProgress(1.0, '完成');

    return Document(
      id: 'doc_${ctx.pick.sourceId}',
      bookId: ctx.pick.sourceId,
      title: ctx.pick.displayName,
      kind: DocumentKind.novel,
      chapters: chapters,
      pages: pages,
      unit: ReadingUnit.page,
      hint: DocumentLayoutHint.pagePreferred,
      warnings: warnings.toSet().toList(),
    );
  }

  static String? _mimeOf(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
      case '.jfif':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.bmp':
        return 'image/bmp';
      default:
        return null;
    }
  }
}
