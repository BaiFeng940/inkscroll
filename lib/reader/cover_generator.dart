import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'document.dart';
import 'page_cache.dart';

/// 从书的**第一张图片**生成封面缩略图。
///
/// ## 为什么在导入时生成而不是在列表里实时渲染
///
/// 在线库（WebDAV）的书，第一页在网盘上。如果等列表滚动到才去拉，
/// 一屏 6 本书就是 6 个并发网络请求 —— 用户感知是"封面一张张跳出来"，
/// 而且每次冷启动都要重来。
///
/// 导入时本来就在读目录、嗅探尺寸，顺手多取一页的代价很小；
/// 生成的缩略图落盘后，之后所有列表渲染都是纯本地文件读取。
///
/// ## 内存安全
///
/// 漫画单页可能是 800×6000 的长图。这里**不**先解码原图再缩放，
/// 而是把 `targetWidth` 交给 `instantiateImageCodec` —— 让解码器
/// 直接按目标宽度出图，峰值内存只有缩略图那么大。
class CoverGenerator {
  const CoverGenerator._();

  /// 缩略图宽度。列表里卡片宽度约 160dp，按 2x 密度 320px 足够，
  /// 留一点余量给平板/大屏。
  static const int defaultWidth = 420;

  /// 生成封面并返回文件路径；失败或没有图片页时返回 null。
  ///
  /// 失败一律**不抛异常** —— 封面只是锦上添花，绝不能因此让导入失败。
  static Future<String?> create({
    required PageByteResolver resolver,
    required Document document,
    required String bookDirPath,
    int targetWidth = defaultWidth,
  }) async {
    final page = _firstImagePage(document);
    if (page == null) return null;

    Uint8List bytes;
    try {
      bytes = await resolver.imageBytes(page);
    } catch (_) {
      return null;
    }
    if (bytes.isEmpty) return null;

    ui.Image? image;
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
      final frame = await codec.getNextFrame();
      image = frame.image;

      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;

      await Directory(bookDirPath).create(recursive: true);
      final file = File('$bookDirPath/cover.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return file.path;
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// 找到第一个"有图片内容"的页。
  ///
  /// 漫画的第一页通常就是封面，但前面可能有空白页或章节标题页，
  /// 所以要跳过没有图片引用的页。
  static PageNode? _firstImagePage(Document document) {
    for (final page in document.pagesInOrder) {
      if (page.content is ImageContent) return page;
    }
    // 兜底：只要有一页就试着拿它
    final all = document.pagesInOrder;
    return all.isEmpty ? null : all.first;
  }
}
