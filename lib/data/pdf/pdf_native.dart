/// PDF 原生通道（Android `PdfRenderer`）。
///
/// 不引 `pdfx` / `pdf_render` 的原因见 `PdfPlugin.kt` 注释：
/// 它们会把约 100 MB 的 pdfium 打进 APK，而系统已自带同样的渲染器。
///
/// 这个文件只负责「调通道 + 解析返回值」，不含任何布局逻辑。
library;

import 'package:flutter/services.dart';

/// 一份 PDF 的元数据
class PdfInfo {
  const PdfInfo({
    required this.pageCount,
    required this.widths,
    required this.heights,
  });

  final int pageCount;

  /// 每页的原始尺寸（PDF 的 pt 单位，只用来算宽高比）
  final List<int> widths;
  final List<int> heights;

  double aspectOf(int index) {
    if (index < 0 || index >= pageCount) return 1.0;
    final w = widths[index];
    final h = heights[index];
    if (w <= 0 || h <= 0) return 1.0;
    return w / h;
  }
}

class PdfNative {
  const PdfNative();

  static const MethodChannel _ch = MethodChannel('inkscroll/pdf');

  /// 打开并读取页数/尺寸。失败抛异常（调用方转成 AppError）。
  Future<PdfInfo> open(String path) async {
    final r = await _ch.invokeMapMethod<String, dynamic>('open', {'path': path});
    if (r == null) throw StateError('PDF 打开失败');
    return PdfInfo(
      pageCount: (r['pageCount'] as int?) ?? 0,
      widths: ((r['widths'] as List?) ?? const []).cast<int>(),
      heights: ((r['heights'] as List?) ?? const []).cast<int>(),
    );
  }

  /// 渲染一页为 PNG 字节。
  ///
  /// [maxWidth] 会被原生侧再夹一次上限（2048），防止大页面吃爆内存 ——
  /// A3 扫描件按原始尺寸渲染能瞬间占几百 MB。
  Future<Uint8List> render(
    String path,
    int index, {
    int maxWidth = 1600,
  }) async {
    final r = await _ch.invokeMethod<Uint8List>('render', {
      'path': path,
      'index': index,
      'maxWidth': maxWidth,
    });
    if (r == null) throw StateError('PDF 渲染返回空');
    return r;
  }

  Future<void> close(String path) async {
    try {
      await _ch.invokeMethod<void>('close', {'path': path});
    } catch (_) {
      // 关闭失败不影响用户
    }
  }
}
