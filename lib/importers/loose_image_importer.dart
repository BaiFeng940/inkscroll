/// 散图导入：用户多选一批图片，直接成一本书。
///
/// ## 排序策略（用户反馈的重点）
///
/// 旧实现给每个文件加了 `00001_` 这样的序号前缀，**按选择顺序**排列。
/// 问题很明显：用户明明用文件名表达了顺序（`1.jpg`、`2.jpg`、`10.jpg`），
/// 结果被"选择顺序"覆盖 —— 于是出现"排序有些问题"。
///
/// 现在的策略：
///   1. **保留原始文件名**（不再加前缀），排序键就是文件名本身；
///   2. 用**自然排序**（`1 < 2 < 10`，而不是字典序 `1 < 10 < 2`）；
///   3. 用户在导入前手动调整过顺序时，**尊重手动顺序**，不再自动排序。
///
/// 这样既尊重用户的命名习惯，又给了"确实没有顺序时"的兜底。
library;

import 'dart:io';
import 'dart:math' as math;

import '../core/errors.dart';
import '../core/image_header.dart';
import '../data/byte_store.dart';
import '../data/importer.dart';
import '../reader/document.dart';
import 'import_utils.dart';

class LooseImageImporter implements Importer {
  LooseImageImporter({required this.store});

  final ByteStore store;

  static const int sniffBudget = 256 * 1024;

  @override
  String get id => 'looseImages';

  @override
  bool canHandle(SourceProbe probe) => probe.formatName == 'images';

  @override
  Future<ImportOutcome> run(ImportContext ctx) async {
    final paths = ctx.pick.paths;
    if (paths.isEmpty) return const ImportFailure(GenericError('没有选择图片'));

    final bookId = ctx.pick.sourceId;
    final dir = Directory(store.folderPathFor(bookId));
    if (!await dir.exists()) await dir.create(recursive: true);

    final manuallyOrdered = ctx.pick.manuallyOrdered;

    // ── 确定最终顺序 ──
    final ordered = [...paths];
    if (!manuallyOrdered) {
      // 按**原始文件名**自然排序（`1.jpg` < `2.jpg` < `10.jpg`）
      ordered.sort((a, b) => compareByOriginalName(_baseName(a), _baseName(b)));
    }

    // ── 复制到私有目录（保留原名，重名加后缀）──
    ctx.onProgress(0.05, '正在复制图片…');
    final copied = <String>[];
    final usedNames = <String>{};
    for (int i = 0; i < ordered.length; i++) {
      final src = File(ordered[i]);
      if (!await src.exists()) continue;

      var name = _baseName(ordered[i]);
      if (name.isEmpty) name = 'image_${i + 1}.jpg';
      if (usedNames.contains(name)) {
        final dot = name.lastIndexOf('.');
        final base = dot > 0 ? name.substring(0, dot) : name;
        final ext = dot > 0 ? name.substring(dot) : '';
        var n = 2;
        while (usedNames.contains('${base}_$n$ext')) {
          n++;
        }
        name = '${base}_$n$ext';
      }
      usedNames.add(name);

      final dst = File('${dir.path}/$name');
      try {
        await src.copy(dst.path);
        copied.add(dst.path);
      } catch (_) {
        // 单张失败不影响整本
      }
      if (i % 10 == 0 || i == ordered.length - 1) {
        ctx.onProgress(
          0.05 + 0.55 * ((i + 1) / ordered.length),
          '正在复制图片 ${i + 1}/${ordered.length}',
        );
      }
    }

    if (copied.isEmpty) {
      await store.deleteBook(bookId);
      return const ImportFailure(GenericError('选中的图片都无法读取'));
    }

    // ── 并行嗅探尺寸（只读文件头，不解码像素）──
    ctx.onProgress(0.62, '正在分析图片尺寸 0/${copied.length}…');
    final aspects = await mapConcurrent<String, double?>(
      copied,
      concurrency: 8,
      task: _sniffAspect,
      onProgress: (done) {
        if (done % 10 == 0 || done == copied.length) {
          ctx.onProgress(
            0.62 + 0.36 * (done / math.max(1, copied.length)),
            '正在分析图片尺寸 $done/${copied.length}…',
          );
        }
      },
    );

    final pages = <String, PageNode>{};
    final pageIds = <String>[];
    for (int i = 0; i < copied.length; i++) {
      final id = 'f:$i';
      pages[id] = PageNode(
        id: id,
        kind: PageKind.image,
        aspectRatio: aspects[i],
        content: ImageContent(ref: LooseFileRef(copied[i])),
      );
      pageIds.add(id);
    }

    ctx.onProgress(1.0, '完成');

    final unknown = aspects.where((a) => a == null).length;

    return ImportedDocument(Document(
      id: 'doc_$bookId',
      bookId: bookId,
      title: ctx.pick.displayName,
      kind: DocumentKind.comic,
      chapters: [Chapter(index: 0, title: '图片', pageIds: pageIds)],
      pages: pages,
      hint: looksLikeWebtoon(aspects)
          ? DocumentLayoutHint.webtoonPreferred
          : DocumentLayoutHint.pagePreferred,
      warnings: [
        if (!manuallyOrdered)
          '已按文件名自然排序（例如 2.jpg 排在 10.jpg 前面）。',
        if (manuallyOrdered) '已使用你手动调整的顺序。',
        if (unknown > 0 && unknown < copied.length)
          '有 $unknown 张图未取到尺寸，滚动到时自动测量。',
      ],
    ));
  }

  static String _baseName(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  Future<double?> _sniffAspect(String path) async {
    try {
      final f = File(path);
      final stat = await f.stat();
      final n = math.min(sniffBudget, stat.size);
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
}
