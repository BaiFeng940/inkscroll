/// PDF 导入 —— **骨架 + 接入指引**（尚未实现）。
///
/// 核心原则：**只取元数据，绝不预渲染**。
///
///   1) pubspec 加 `pdfx: ^2.6.0`（MIT 许可）
///
///   2) 打开文档，只读页数与每页 MediaBox 尺寸（不 render）：
///
///        final doc = await PdfDocument.openFile(path);
///        final count = doc.pagesCount;
///        for (int i = 0; i < count; i++) {
///          final page = await doc.getPage(i);
///          final w = page.width, h = page.height;   // ← 只读尺寸
///          // PageNode(kind: pdfPage, aspectRatio: w / h, ...)
///        }
///
///   3) 渲染留在阅读器侧（ReaderScreen），按可见窗口做：
///        可见页 + 上下各预渲染 1 页；离开窗口立即释放位图。
///
///        final raster = await doc.render(
///          pageNumber: i,
///          width: min(viewportWidth * 2, 2048),   // ★ 必须限宽
///          height: min(viewportWidth * 2, 2048) / aspect,
///        );
///
///      ★ 限宽到 2048 的原因：2x 屏幕密度已足够清晰，
///        同时把单页位图控制在 ~16MB 以内，避免超宽页 OOM。
///
///   4) 大文件策略：
///        < 32MB  → 全部读入内存（PDF 解析需要随机访问）
///        ≥ 32MB  → 分块落盘临时文件，交给 TempFileCache 做 LRU
///
///   5) 内存释放：pdfx 内部有文档级缓存，离开阅读器时必须 doc.close()，
///      否则大 PDF 会常驻内存。
///
/// 引擎选择对比：
///   pdfx                          ✅ MIT、随机渲染单页   ← 推荐
///   Android PdfRenderer 原生通道   ✅ 内存控制最佳        ← 精细控制时用
///   syncfusion_flutter_pdfviewer   ⚠️ 商业许可，开源项目慎用
library;

import '../core/errors.dart';
import '../data/importer.dart';

class PdfImporter implements Importer {
  PdfImporter();

  @override
  String get id => 'pdf';

  @override
  bool canHandle(SourceProbe probe) => probe.formatName == 'pdf';

  @override
  Future<ImportOutcome> run(ImportContext ctx) async {
    return const ImportFailure(GenericError(
      'PDF 导入尚未启用。\n\n'
      '接入步骤见 lib/importers/pdf_importer.dart 顶部注释：\n'
      '  1. pubspec 加 pdfx: ^2.6.0\n'
      '  2. 只读 pagesCount 与每页 MediaBox 尺寸（不要预渲染）\n'
      '  3. 每页生成 PageNode(kind: pdfPage, aspectRatio: w/h)\n'
      '  4. 渲染放到阅读器里按可见窗口做，并限制渲染宽度 ≤ 2048\n'
      '  5. 离开阅读器时 close() 释放文档缓存',
      action: ErrorAction.convertFile,
    ));
  }
}
