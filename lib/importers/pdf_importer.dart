/// PDF 导入：**只取元数据，绝不预渲染**。
///
/// ## 做法
///
/// 1. 把 PDF 复制进应用私有目录（file_picker 给的是临时缓存路径，
///    系统随时可能清掉，必须自己留一份）；
/// 2. 通过原生 `PdfRenderer` 只读**页数 + 每页尺寸**，一次遍历就够；
/// 3. 每页生成一个 `PageNode`，内容是 `PdfPageRef(路径, 页码)` ——
///    真正渲染推迟到阅读器按可见窗口做（见 `PdfPageResolver`）。
///
/// ## 为什么不用 pdfx
///
/// `pdfx` / `pdf_render` 会把整个 pdfium 打进 APK（约 100 MB，还是三份 ABI）。
/// Android 从 5.0 起系统自带 `PdfRenderer`（底层同样是 pdfium），
/// 零体积增长、随 ROM 更新维护，正好匹配我们"按需渲染一页"的架构。
/// 详见 `android/app/src/main/kotlin/com/inkscroll/reader/PdfPlugin.kt`。
///
/// ## 尺寸的作用
///
/// 每页写入 `aspectRatio = w / h`。虚拟长页的总高度完全依赖它 ——
/// 缺了它就只能用兜底比例，滚动条会跳、页面会先塌后撑。
/// 所以哪怕不渲染，也**必须**把每页尺寸读出来。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../data/byte_store.dart';
import '../data/importer.dart';
import '../data/pdf/pdf_native.dart';
import '../reader/document.dart';

class PdfImporter implements Importer {
  PdfImporter({required this.store, PdfNative? native})
      : _native = native ?? const PdfNative();

  final ByteStore store;
  final PdfNative _native;

  /// 超过这个页数只导入前面的部分，避免异常文件把内存撑爆
  static const int maxPages = 5000;

  @override
  String get id => 'pdf';

  @override
  bool canHandle(SourceProbe probe) => probe.formatName == 'pdf';

  @override
  Future<ImportOutcome> run(ImportContext ctx) async {
    final srcPath = ctx.pick.path;
    if (srcPath == null) {
      return const ImportFailure(GenericError('没有选择文件'));
    }

    final bookId = ctx.pick.sourceId;
    final bookDir = store.bookDir(bookId);

    // ── 第 1 步：复制到私有目录 ──
    final dstPath = p.join(bookDir, p.basename(srcPath));
    ctx.onProgress(0.05, '正在复制 PDF…');
    try {
      await Directory(bookDir).create(recursive: true);
      if (!await File(dstPath).exists()) {
        await ByteStore.copyFile(
          srcPath,
          dstPath,
          onProgress: (r, label) => ctx.onProgress(r * 0.35, label),
        );
      }
    } catch (e) {
      return ImportFailure(GenericError('复制 PDF 失败：$e'));
    }

    // ── 第 2 步：只读页数与尺寸（不渲染）──
    ctx.onProgress(0.4, '正在读取 PDF 页信息…');
    PdfInfo info;
    try {
      info = await _native.open(dstPath);
    } catch (e) {
      return ImportFailure(GenericError(
        '打不开这个 PDF：$e\n\n'
        '常见原因：文件已加密（需要密码）、文件损坏，或其实不是 PDF。',
      ));
    }

    if (info.pageCount <= 0) {
      return const ImportFailure(GenericError('这个 PDF 里没有页面'));
    }

    final warnings = <String>[];
    var count = info.pageCount;
    if (count > maxPages) {
      warnings.add('PDF 共 $count 页，已只导入前 $maxPages 页');
      count = maxPages;
    }

    // ── 第 3 步：建页（只存引用 + 宽高比，不碰像素）──
    final pages = <String, PageNode>{};
    final pageIds = <String>[];
    for (var i = 0; i < count; i++) {
      final id = 'p$i';
      final ref = PdfPageRef(path: dstPath, pageIndex: i);
      pages[id] = PageNode(
        id: id,
        // 用 pdfPage 标记，语义上区别于普通图片
        kind: PageKind.pdfPage,
        content: ImageContent(
          ref: ref,
          intrinsicWidth: info.widths.length > i ? info.widths[i] : null,
          intrinsicHeight: info.heights.length > i ? info.heights[i] : null,
          // 渲染结果是 PNG，提前告诉下游，省一次格式探测
          mimeType: 'image/png',
        ),
        aspectRatio: info.aspectOf(i),
        title: '第 ${i + 1} 页',
      );
      pageIds.add(id);
      if (i % 20 == 0) {
        ctx.onProgress(0.4 + 0.55 * (i / count), '正在解析页面 $i/$count');
      }
    }

    ctx.onProgress(1.0, '完成');
    return ImportedDocument(Document(
      id: 'doc-$bookId',
      bookId: bookId,
      title: ctx.pick.displayName,
      kind: DocumentKind.pdf,
      chapters: [
        Chapter(
          index: 0,
          title: ctx.pick.displayName,
          pageIds: pageIds,
          coverRef: pageIds.isEmpty
              ? null
              : (pages[pageIds.first]!.content as ImageContent).ref,
        ),
      ],
      pages: pages,
      // PDF 是"一页一屏"，默认左右翻页；用户可在设置里改
      unit: ReadingUnit.page,
      hint: DocumentLayoutHint.pagePreferred,
      warnings: warnings,
    ));
  }
}
