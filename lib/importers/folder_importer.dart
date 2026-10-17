/// 文件夹导入：递归收集图片/文本，自然排序，子目录 = 章。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../core/image_header.dart';
import '../data/byte_store.dart';
import '../data/importer.dart';
import '../reader/document.dart';
import 'import_utils.dart';
import 'text_parser.dart';

class FolderImporter implements Importer {
  FolderImporter({required this.store});

  final ByteStore store;

  /// 尺寸嗅探预算：只读文件头，不读整张图
  static const int sniffBudget = 256 * 1024;
  @override
  String get id => 'folder';

  @override
  bool canHandle(SourceProbe probe) => probe.formatName == 'folder';

  @override
  Future<ImportOutcome> run(ImportContext ctx) async {
    final srcPath = ctx.pick.path;
    if (srcPath == null) return const ImportFailure(GenericError('没有选择文件夹'));

    final bookId = ctx.pick.sourceId;
    final dstRoot = store.folderPathFor(bookId);

    int copiedCount;

    if (ctx.pick.alreadyLocal) {
      // Android SAF 路径：原生侧已经把文件直接复制进了 dstRoot，
      // 这里只需要清点数量，**不要再复制一次**（几百张图会明显拖慢导入）。
      ctx.onProgress(0.2, '正在清点文件…');
      if (!await Directory(dstRoot).exists()) {
        return const ImportFailure(GenericError(
          '导入目录不存在，请重新选择文件夹。',
          action: ErrorAction.chooseAnother,
        ));
      }
      copiedCount = 0;
      await for (final e in Directory(dstRoot).list(recursive: true, followLinks: false)) {
        if (e is File) copiedCount++;
      }
      if (copiedCount == 0) {
        await store.deleteBook(bookId);
        return const ImportFailure(GenericError(
          '这个文件夹里没有可读取的文件。\n'
          '可能是所选目录为空，或者里面的文件类型都不受支持。',
          action: ErrorAction.chooseAnother,
        ));
      }
    } else {
      // ── 第 0 步：预检源目录 ──
      // 桌面/iOS 或旧路径：走"先预检再复制"的老路。
      try {
        await ensureReadableDirectory(srcPath);
      } on AppError catch (e) {
        return ImportFailure(e);
      } catch (e) {
        return ImportFailure(GenericError(
          '无法访问该文件夹：$e',
          action: ErrorAction.chooseAnother,
        ));
      }

      // ── 第 1 步：复制到私有目录 ──
      // 为什么必须复制：授权可能随时失效，且原目录可能被用户移动/删除。
      ctx.onProgress(0.0, '正在复制文件夹…');
      try {
        copiedCount = await ByteStore.copyDirectory(
          srcPath,
          dstRoot,
          onProgress: (r, label) => ctx.onProgress(r * 0.45, label),
        );
      } on FileSystemException catch (e) {
        await store.deleteBook(bookId);
        return ImportFailure(GenericError(
          '复制文件夹失败：${e.message}\n'
          '常见原因：目录在外置存储/云盘上、授权已失效、或空间不足。',
          action: ErrorAction.chooseAnother,
          technicalDetail: '$e',
        ));
      } catch (e) {
        await store.deleteBook(bookId);
        return ImportFailure(GenericError('复制文件夹失败：$e'));
      }

      if (copiedCount == 0) {
        await store.deleteBook(bookId);
        return ImportFailure(const GenericError(
          '这个文件夹是空的（没有复制到任何文件）。\n'
          '请确认选择的目录里确实有图片或文本文件。',
          action: ErrorAction.chooseAnother,
        ));
      }
    }

    // ── 第 2 步：在私有目录里列文件 ──
    ctx.onProgress(0.46, '正在扫描内容…');
    final root = Directory(dstRoot);

    CollectResult collected;
    try {
      collected = await collectFiles(root, maxDepth: 12);
    } catch (e) {
      await store.deleteBook(bookId);
      return ImportFailure(GenericError('扫描内容失败：$e'));
    }

    final all = collected.files;

    // ── 分三级分类：按扩展名先筛，扩展名不认识的再读文件头按魔数判定 ──
    //
    // 用户反馈"文件夹导入找不到图片"，真实原因是：
    //   只按扩展名过滤，必然漏掉无扩展名文件、.dat、扩展名与内容不符的文件。
    //   这里加一层内容嗅探（每个文件只读前 4KB），把这类文件也能识别出来。
    final images = <File>[];
    final unsupportedImages = <String, int>{}; // 格式名 -> 数量
    final texts = <File>[];
    final otherExt = <String, int>{};
    final otherSniffed = <String, int>{};

    int sniffedCount = 0;
    for (final f in all) {
      final ext = p.extension(f.path).toLowerCase();

      if (isRenderableImagePath(f.path)) {
        images.add(f);
        continue;
      }
      if (isUnsupportedImagePath(f.path)) {
        final label = ext.isEmpty ? '未知' : ext;
        unsupportedImages[label] = (unsupportedImages[label] ?? 0) + 1;
        continue;
      }
      if (isTextPath(f.path)) {
        texts.add(f);
        continue;
      }

      // 扩展名不认识 → 内容嗅探
      sniffedCount++;
      final sniff = await sniffFileKind(f);
      switch (sniff?.kind) {
        case FileKind.image:
          images.add(f);
        case FileKind.unsupportedImage:
          final label = sniff!.formatLabel ?? '未知格式';
          unsupportedImages[label] = (unsupportedImages[label] ?? 0) + 1;
        case FileKind.text:
          texts.add(f);
        case FileKind.archive:
          // 文件夹里的压缩包：暂不递归处理，只提示
          final label = sniff?.formatLabel ?? '压缩包';
          otherSniffed[label] = (otherSniffed[label] ?? 0) + 1;
        case FileKind.other:
        case null:
          final key = ext.isEmpty ? '（无扩展名）' : ext;
          otherExt[key] = (otherExt[key] ?? 0) + 1;
      }
    }

    // 排序：内容判定的结果需要重新排一遍（原来依赖扩展名顺序）
    images.sort((a, b) => naturalComparePath(
          p.relative(a.path, from: dstRoot).replaceAll('\\', '/'),
          p.relative(b.path, from: dstRoot).replaceAll('\\', '/'),
        ));

    final diagnostics = <String>[
      if (sniffedCount > 0)
        '其中 $sniffedCount 个文件按内容识别（扩展名不标准）。',
      if (unsupportedImages.isNotEmpty)
        '识别到但当前引擎无法解码：'
            '${unsupportedImages.entries.map((e) => '${e.key}×${e.value}').join('、')}。',
      if (otherSniffed.isNotEmpty)
        '发现压缩包（请单独用"选择压缩包"导入）：'
            '${otherSniffed.entries.map((e) => '${e.key}×${e.value}').join('、')}。',
    ];

    if (images.isEmpty && texts.isEmpty) {
      await store.deleteBook(bookId);

      final histogram = <String, int>{};
      for (final f in all) {
        final ext = p.extension(f.path).toLowerCase();
        histogram[ext.isEmpty ? '（无扩展名）' : ext] =
            (histogram[ext.isEmpty ? '（无扩展名）' : ext] ?? 0) + 1;
      }
      final top = histogram.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      return ImportFailure(GenericError(
        '已复制 $copiedCount 个文件，但其中没有可识别的图片或文本。\n'
        '文件类型统计：${top.take(8).map((e) => '${e.key}×${e.value}').join('、')}\n'
        '${diagnostics.join('\n')}\n'
        '支持的图片：JPG / PNG / WebP / GIF / BMP / AVIF / HEIC / TIFF / ICO\n'
        '支持的文本：TXT / MD / LOG / SRT',
        technicalDetail: 'entriesSeen=${collected.entriesSeen} '
            'skippedByDepth=${collected.skippedByDepth} '
            'truncated=${collected.truncated} copied=$copiedCount',
      ));
    }

    // ── 第 3 步：判定结构 ──
    // 图片占多数 → 漫画；否则按文本处理。
    // 图片数 >= 1 即可成书（原来要求 >= 3，只有 1~2 张图的目录无法导入）。
    final warnings = <String>[
      ...diagnostics,
      if (collected.truncated) '文件数量过多，只读取了前 50000 个。',
      if (collected.skippedByDepth > 0)
        '有 ${collected.skippedByDepth} 个文件因目录层级过深被跳过（上限 12 层）。',
    ];

    if (images.isNotEmpty && images.length >= texts.length) {
      return ImportedDocument(
          await _buildComic(ctx, root, images, dstRoot, warnings));
    }
    if (texts.isNotEmpty) {
      return ImportedDocument(await _buildNovel(ctx, texts, dstRoot, warnings));
    }
    return ImportedDocument(
        await _buildComic(ctx, root, images, dstRoot, warnings));
  }

  // ------------------------------------------------------------------
  Future<Document> _buildComic(
    ImportContext ctx,
    Directory root,
    List<File> images,
    String dstRoot,
    List<String> extraWarnings,
  ) async {
    // 按"相对路径的目录部分"分章
    final groups = <String, List<File>>{};
    for (final f in images) {
      final rel = p.relative(f.path, from: dstRoot).replaceAll('\\', '/');
      final dir = parentDirOf(rel);
      groups.putIfAbsent(dir, () => []).add(f);
    }

    final orderedDirs = groups.keys.toList()
      ..sort((a, b) => naturalComparePath(a, b));

    final pages = <String, PageNode>{};
    final chapters = <Chapter>[];
    final aspects = <double?>[];

    final total = images.length;

    // ── 并行嗅探尺寸 ──
    // 旧实现是逐张顺序 await，500 张图要开 500 次文件句柄，串起来很慢。
    // 这里限制并发 8 路（SSD 上收益明显，机械盘/手机闪存也不会因争抢而变慢）。
    // 预算随张数自适应：图多就少读一点，保证总读取量有界。
    final sniffBudgetBytes = total > 6000
        ? 48 * 1024
        : (total > 1500 ? 96 * 1024 : sniffBudget);

    ctx.onProgress(0.48, '正在分析图片尺寸 0/$total…');
    final sniffResults = await mapConcurrent<File, double?>(
      images,
      concurrency: 8,
      task: (f) => _sniffAspect(f, sniffBudgetBytes),
      onProgress: (done) {
        if (done % 25 == 0 || done == total) {
          ctx.onProgress(
            0.48 + 0.48 * (done / math.max(1, total)),
            '正在分析图片尺寸 $done/$total…',
          );
        }
      },
    );

    final aspectByPath = <String, double?>{};
    for (int i = 0; i < images.length; i++) {
      aspectByPath[images[i].path] = sniffResults[i];
    }

    int chapterIndex = 0;
    for (final dir in orderedDirs) {
      final list = groups[dir]!
        ..sort((a, b) => naturalComparePath(
              p.relative(a.path, from: dstRoot).replaceAll('\\', '/'),
              p.relative(b.path, from: dstRoot).replaceAll('\\', '/'),
            ));

      final slices = list.length > 200 ? chunk(list, 100) : [list];

      for (final slice in slices) {
        final pageIds = <String>[];
        for (final f in slice) {
          final rel = p.relative(f.path, from: dstRoot).replaceAll('\\', '/');
          final id = 'f:$rel';
          final aspect = aspectByPath[f.path];
          aspects.add(aspect);

          pages[id] = PageNode(
            id: id,
            kind: PageKind.image,
            aspectRatio: aspect,
            content: ImageContent(ref: LooseFileRef(f.path)),
          );
          pageIds.add(id);
        }

        chapters.add(Chapter(
          index: chapterIndex,
          title: slices.length > 1
              ? '${chapterTitleFromDir(dir)}（${chapterIndex + 1}）'
              : chapterTitleFromDir(dir),
          pageIds: pageIds,
          coverRef: (pages[pageIds.first]!.content as ImageContent).ref,
        ));
        chapterIndex++;
      }
    }

    ctx.onProgress(1.0, '完成');

    final unknownCount = aspects.where((a) => a == null).length;

    return Document(
      id: 'doc_${ctx.pick.sourceId}',
      bookId: ctx.pick.sourceId,
      title: ctx.pick.displayName,
      kind: DocumentKind.comic,
      chapters: chapters,
      pages: pages,
      hint: looksLikeWebtoon(aspects)
          ? DocumentLayoutHint.webtoonPreferred
          : DocumentLayoutHint.pagePreferred,
      warnings: [
        if (aspects.isEmpty && total > 0) '没有可用的页面。',
        if (unknownCount > 0 && unknownCount < total)
          '有 $unknownCount 页未取到尺寸，滚动到该页时会自动测量。',
        if (unknownCount == total && total > 0)
          '所有页面都未能解析出尺寸（图片可能损坏或格式特殊），'
              '已使用默认比例，阅读位置可能略有偏差。',
        ...extraWarnings,
      ],
    );
  }

  /// ★ 只读文件头部若干字节 → 得到宽高，不解码像素
  Future<double?> _sniffAspect(File f, int budget) async {
    try {
      final stat = await f.stat();
      final n = math.min(budget, stat.size);
      if (n < 32) return null;
      final raf = await f.open();
      try {
        final bytes = await raf.read(n);
        return ImageHeaderParser.tryParse(bytes)?.aspectRatio;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------
  Future<Document> _buildNovel(
    ImportContext ctx,
    List<File> texts,
    String dstRoot,
    List<String> extraWarnings,
  ) async {
    final sorted = texts.toList()
      ..sort((a, b) => naturalComparePath(
            p.relative(a.path, from: dstRoot).replaceAll('\\', '/'),
            p.relative(b.path, from: dstRoot).replaceAll('\\', '/'),
          ));

    final pages = <String, PageNode>{};
    final chapters = <Chapter>[];
    final warnings = <String>[...extraWarnings];

    int chapterIndex = 0;
    for (int i = 0; i < sorted.length; i++) {
      ctx.onProgress(0.5 + 0.45 * (i / sorted.length), '正在解析 ${p.basename(sorted[i].path)}');

      final Uint8List bytes;
      try {
        bytes = await sorted[i].readAsBytes();
      } catch (e) {
        warnings.add('跳过 ${p.basename(sorted[i].path)}：$e');
        continue;
      }

      final parsed = parsePlainText(bytes, p.basename(sorted[i].path));
      warnings.addAll(parsed.warnings);

      for (final tc in parsed.chapters) {
        final pageIds = <String>[];
        for (int j = 0; j < tc.pages.length; j++) {
          final id = 't:${sorted[i].path}#$chapterIndex#$j';
          pages[id] = PageNode(
            id: id,
            kind: PageKind.text,
            content: TextPageContent(
              text: tc.pages[j],
              headingLevel: j == 0 ? 1 : null,
              pageStartCharOffset: tc.startCharOffset + tc.pageCharOffsets[j],
            ),
          );
          pageIds.add(id);
        }
        chapters.add(Chapter(
          index: chapterIndex,
          title: sorted.length > 1
              ? '${p.basename(sorted[i].path)} · ${tc.title}'
              : tc.title,
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
      hint: DocumentLayoutHint.pagePreferred,
      warnings: warnings.toSet().toList(),
    );
  }
}
