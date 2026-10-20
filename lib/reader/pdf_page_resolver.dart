/// PDF 页的字节解析器。
///
/// 和其它解析器的关键区别：**字节不是"读出来的"，而是"渲染出来的"**。
/// 所以这里额外做了两件别处不需要的事：
///
/// 1. **渲染宽度限制**。PDF 页面是按向量描述的，可以渲染成任意尺寸；
///    A3 扫描件按原始尺寸渲染能瞬间吃掉几百 MB。统一按屏宽 1.5 倍渲染，
///    再交给 Flutter 缩放显示。
/// 2. **同页请求合并**。一页同时被"预取"和"当前可见"两条路径请求时
///    （滚动时很常见），如果不去重就会渲染两次、浪费一倍 CPU。
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../data/pdf/pdf_native.dart';
import 'document.dart';
import 'page_cache.dart';

class PdfPageResolver implements PageByteResolver {
  PdfPageResolver({
    required this.pdfPath,
    PdfNative? native,
    this.renderWidth = 1600,
  }) : _native = native ?? const PdfNative();

  final String pdfPath;
  final PdfNative _native;

  /// 渲染目标宽度（像素）。原生侧还有 2048 的硬上限。
  final int renderWidth;

  /// 已渲染页的字节缓存（页号 -> PNG）
  final PageImageCache _cache = PageImageCache(maxEntries: 12, maxBytes: 96 << 20);

  /// 正在进行中的渲染，用于合并同一页的并发请求
  final Map<int, Future<Uint8List>> _inflight = {};

  @override
  Future<Uint8List> imageBytes(PageNode page) async {
    final ref = page.content;
    if (ref is! ImageContent || ref.ref is! PdfPageRef) {
      throw const GenericError('该页不是 PDF 页面');
    }
    final pdfRef = ref.ref as PdfPageRef;
    final idx = pdfRef.pageIndex;

    final cached = _cache.get('$idx');
    if (cached != null) return cached;

    // 合并同一页的并发请求：两个调用方共享一次渲染
    final existing = _inflight[idx];
    if (existing != null) return existing;

    final fut = _render(idx);
    _inflight[idx] = fut;
    try {
      return await fut;
    } finally {
      _inflight.remove(idx);
    }
  }

  Future<Uint8List> _render(int index) async {
    try {
      final bytes = await _native.render(
        pdfPath,
        index,
        maxWidth: renderWidth,
      );
      _cache.put('$index', bytes);
      return bytes;
    } catch (e) {
      throw GenericError('PDF 第 ${index + 1} 页渲染失败：$e');
    }
  }

  @override
  Future<Uint8List> peekBytes(PageNode page, {int bytes = 192 * 1024}) async {
    // 尺寸嗅探也走渲染：PDF 没有"文件头"可读，PNG 头必须在渲染结果里。
    // 好在 imageBytes 有缓存，紧随其后的整页请求不会重复渲染。
    final full = await imageBytes(page);
    return full.length <= bytes ? full : Uint8List.sublistView(full, 0, bytes);
  }

  @override
  Future<void> dispose() async {
    _cache.clear();
    _inflight.clear();
    await _native.close(pdfPath);
  }
}
