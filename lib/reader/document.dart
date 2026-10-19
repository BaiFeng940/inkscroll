/// 统一文档模型。
///
/// 这是整个项目的"汇率表"：所有格式（zip / 文件夹 / TXT / 未来 PDF、DOCX、网页）
/// 先翻译成这套模型，阅读器只认这套模型。
///
/// 两条铁律：
///   1. **模型里绝不出现 Uint8List**。只存 ContentRef（"内容在哪"），
///      字节通过 ContentLoader 按需获取。否则 Document 一旦被共享就会 OOM。
///   2. **每页必须有 aspectRatio**（能算出来的话）。虚拟长页要在不加载图片的
///      前提下算出总高度，否则进度条与百分比跳转无法工作。
library;

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// 内容引用：只描述"内容在哪"
// ---------------------------------------------------------------------------

sealed class ContentRef {
  const ContentRef();
}

/// 散图 / 文件夹里的外部文件
final class LooseFileRef extends ContentRef {
  const LooseFileRef(this.path);

  /// 绝对路径
  final String path;

  @override
  String toString() => 'LooseFileRef($path)';
}

/// 压缩包内条目
final class ArchiveEntryRef extends ContentRef {
  const ArchiveEntryRef({
    required this.archivePath,
    required this.entryPath,
    required this.uncompressedSize,
  });

  /// 压缩包自身在磁盘上的路径（app 私有目录内）
  final String archivePath;

  /// 包内路径
  final String entryPath;

  final int uncompressedSize;

  @override
  String toString() => 'ArchiveEntryRef($archivePath::$entryPath)';
}

/// 内存字节：用于已经在小内存里的内容（分页后的 TXT 用 TextContent，不走这里）
final class InlineRef extends ContentRef {
  const InlineRef(this.bytes);
  final List<int> bytes;
}

/// 网络（WebDAV / NAS）上的文件
///
/// 只存"在哪"，绝不存字节 —— 和另外两种 ref 一样遵守模型的铁律。
/// 真正的字节由 `WebDavPageByteResolver` 按需拉取并落盘缓存。
final class WebDavRef extends ContentRef {
  const WebDavRef({required this.url, required this.connectionId});

  /// **绝对且已编码**的 URL，可直接 GET
  final String url;

  /// 指向哪个 NAS 连接（凭据按 id 存在连接表里，不散落在每一页上）
  final String connectionId;

  @override
  String toString() => 'WebDavRef($connectionId :: $url)';
}

/// **网盘上的压缩包里的一个条目**
///
/// 为什么不能复用 [ArchiveEntryRef]：那个假定压缩包在本地磁盘上
/// （`archivePath`），而这里的包在网盘上，要靠 Range 请求按需读取。
///
/// 只记录"哪个包里的哪个条目" —— 条目在包内的偏移、压缩方式、
/// 压缩后大小都由 `ZipArchiveSource` 现场解析（读中央目录通常只要
/// 1~2 次 Range 请求），不需要落到模型里，避免模型与包内容不一致。
final class WebDavArchiveRef extends ContentRef {
  const WebDavArchiveRef({
    required this.connectionId,
    required this.archiveUrl,
    required this.entryPath,
  });

  final String connectionId;

  /// 压缩包本身的**绝对且已编码** URL
  final String archiveUrl;

  /// 包内路径（例如 `第01话/001.jpg`）
  final String entryPath;

  @override
  String toString() =>
      'WebDavArchiveRef($connectionId :: $archiveUrl!$entryPath)';
}

// ---------------------------------------------------------------------------
// 页内容
// ---------------------------------------------------------------------------

sealed class PageContent {
  const PageContent();
}

final class ImageContent extends PageContent {
  const ImageContent({
    required this.ref,
    this.intrinsicWidth,
    this.intrinsicHeight,
    this.mimeType,
  });

  final ContentRef ref;
  final int? intrinsicWidth;
  final int? intrinsicHeight;
  final String? mimeType;
}

final class TextPageContent extends PageContent {
  const TextPageContent({
    required this.text,
    this.headingLevel,
    this.pageStartCharOffset = 0,
  });

  final String text;

  /// 1..6 表示标题层级
  final int? headingLevel;

  /// ★ 全书字符偏移。改字号重新分页时用它做锚点，比页号稳定。
  final int pageStartCharOffset;
}

/// PDF 页：不预渲染，交给渲染引擎按需出图
final class PdfPageContent extends PageContent {
  const PdfPageContent({
    required this.ref,
    required this.pageIndex,
    required this.widthPt,
    required this.heightPt,
  });

  final ContentRef ref;
  final int pageIndex;
  final double widthPt;
  final double heightPt;
}

enum PageKind { image, text, pdfPage }

// ---------------------------------------------------------------------------
// 页 / 章 / 文档
// ---------------------------------------------------------------------------

class PageNode {
  const PageNode({
    required this.id,
    required this.kind,
    required this.content,
    this.aspectRatio,
    this.title,
  });

  final String id;
  final PageKind kind;
  final PageContent content;

  /// width / height。★ 虚拟长页的总高度完全依赖它。
  /// 为 null 时 PageLayoutMetrics 会退回一个兜底比例，并在真实解码后回填。
  final double? aspectRatio;

  final String? title;

  bool get isImage => kind == PageKind.image;
  bool get isText => kind == PageKind.text;

  PageNode copyWith({double? aspectRatio}) => PageNode(
        id: id,
        kind: kind,
        content: content,
        aspectRatio: aspectRatio ?? this.aspectRatio,
        title: title,
      );
}

class Chapter {
  Chapter({
    required this.index,
    required this.title,
    required this.pageIds,
    this.coverRef,
  });

  final int index;
  final String title;
  final List<String> pageIds;
  final ContentRef? coverRef;

  int get pageCount => pageIds.length;
}

enum DocumentKind { comic, novel, pdf, web, doc }

/// 阅读进度的"计量单位"
enum ReadingUnit {
  /// 按页记进度（漫画、PDF、分页的 TXT）
  page,

  /// 按像素记进度（未来的网页长文、单张超长图）
  pixel,
}

/// 给阅读器的默认模式建议
enum DocumentLayoutHint {
  /// 漫画 → 建议 Webtoon 长图
  webtoonPreferred,

  /// 小说 → 建议左右点击或滑动
  pagePreferred,

  /// 长文 → 建议连续滚动
  continuousPreferred,
}

class Document {
  Document({
    required this.id,
    required this.bookId,
    required this.title,
    required this.kind,
    required this.chapters,
    required this.pages,
    this.unit = ReadingUnit.page,
    this.hint = DocumentLayoutHint.webtoonPreferred,
    this.warnings = const [],
  });

  final String id;
  final String bookId;
  final String title;
  final DocumentKind kind;
  final List<Chapter> chapters;

  /// 扁平索引：pageId -> PageNode，O(1) 取页
  final Map<String, PageNode> pages;

  final ReadingUnit unit;
  final DocumentLayoutHint hint;

  /// 导入时产生的非致命提示（例如"部分编码无法识别，已按 UTF-8 容错解码"）
  final List<String> warnings;

  int get pageCount => pages.length;
  int get chapterCount => chapters.length;

  /// 按阅读顺序展开的页列表（虚拟长页的顺序就是它）。
  ///
  /// 不用 late final 缓存：因为 [PageNode.aspectRatio] 可能在真实解码后被回填
  /// （见 ReaderController.backfillAspect），缓存住旧快照会导致度量算错。
  /// 每次重新组装一个 List 引用的成本可以忽略（不是深拷贝）。
  List<PageNode> get pagesInOrder {
    final out = <PageNode>[];
    final seen = <String>{};
    for (final c in chapters) {
      for (final id in c.pageIds) {
        final p = pages[id];
        if (p != null && seen.add(id)) out.add(p);
      }
    }
    // 兜底：有页没被任何章节引用时追加到末尾，避免"丢失内容"
    for (final p in pages.values) {
      if (seen.add(p.id)) out.add(p);
    }
    return out;
  }

  /// pageId -> 阅读顺序下标（构建一次，避免章节查找变成 O(n^2)）
  late final Map<String, int> _pageIndexById = () {
    final m = <String, int>{};
    final list = pagesInOrder;
    for (int i = 0; i < list.length; i++) {
      m[list[i].id] = i;
    }
    return m;
  }();

  int indexOfPage(String pageId) => _pageIndexById[pageId] ?? 0;

  Chapter? chapterOfPage(int pageIndex) {
    if (chapters.isEmpty) return null;
    for (final c in chapters) {
      if (c.pageIds.isEmpty) continue;
      final first = _pageIndexById[c.pageIds.first];
      final last = _pageIndexById[c.pageIds.last];
      if (first == null || last == null) continue;
      if (pageIndex >= first && pageIndex <= last) return c;
    }
    return chapters.first;
  }

  /// 风格统一的兜底比例（漫画常见 1.4，即 A4 竖版近似）
  static const double fallbackAspectRatio = 1.4;

  /// 只统计有真实比例的页，用于给未知比例的页取中位数
  double medianAspectRatio() {
    final list = pagesInOrder
        .map((p) => p.aspectRatio)
        .whereType<double>()
        .where((a) => a.isFinite && a > 0.05 && a < 50)
        .toList()
      ..sort();
    if (list.isEmpty) return fallbackAspectRatio;
    return list[list.length ~/ 2];
  }
}

// ---------------------------------------------------------------------------
// 虚拟长页度量
// ---------------------------------------------------------------------------

/// 整条虚拟长页的几何度量。
///
/// 构建是 O(n) 前缀和，1 万页也是微秒级。
/// **完全不需要加载任何图片** —— 高度来自导入阶段嗅探到的 aspectRatio。
class PageLayoutMetrics {
  PageLayoutMetrics._({
    required this.viewportWidth,
    required this.tops,
    required this.heights,
    required this.totalHeight,
  });

  factory PageLayoutMetrics.build({
    required List<PageNode> pages,
    required double viewportWidth,
    double fallbackAspect = Document.fallbackAspectRatio,
  }) {
    final tops = <double>[];
    final heights = <double>[];
    double y = 0;
    for (final p in pages) {
      final a = _sanitizeAspect(p.aspectRatio, fallbackAspect);
      tops.add(y);
      // ★ 高度 = 宽度 / 比例。图片之间没有任何 padding/gap，
      //   所以直接累加即得到"一条长页"。
      final h = viewportWidth / a;
      heights.add(h);
      y += h;
    }
    return PageLayoutMetrics._(
      viewportWidth: viewportWidth,
      tops: tops,
      heights: heights,
      totalHeight: y,
    );
  }

  final double viewportWidth;
  final List<double> tops;
  final List<double> heights;
  final double totalHeight;

  int get pageCount => heights.length;

  /// 当前滚动像素落在第几页（二分查找）
  int pageAt(double y) {
    if (tops.isEmpty) return 0;
    if (y <= 0) return 0;
    if (y >= totalHeight) return tops.length - 1;
    int lo = 0;
    int hi = tops.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (tops[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  double topOf(int index) {
    if (tops.isEmpty) return 0;
    return tops[index.clamp(0, tops.length - 1)];
  }

  double heightOf(int index) {
    if (heights.isEmpty) return 0;
    return heights[index.clamp(0, heights.length - 1)];
  }

  /// 页内比例（0~1）
  double ratioInPage(int pageIndex, double y) {
    final h = heightOf(pageIndex);
    if (h <= 0) return 0;
    return ((y - topOf(pageIndex)) / h).clamp(0.0, 1.0);
  }

  double ratioAt(double y) =>
      totalHeight <= 0 ? 0 : (y / totalHeight).clamp(0.0, 1.0);

  double offsetForRatio(double r) =>
      (r.clamp(0.0, 1.0)) * totalHeight;

  /// 由"页 + 页内比例"还原像素位置
  double pixelFor(int pageIndex, double ratioInPage) =>
      topOf(pageIndex) + ratioInPage * heightOf(pageIndex);

  /// ★ 横竖屏切换：宽度变了，所有高度按比例缩放，
  ///   用相同锚点重算位置即可保持"停在原页原位"。
  bool sameWidth(double w) => (w - viewportWidth).abs() < 0.5;

  static double _sanitizeAspect(double? raw, double fallback) {
    if (raw == null) return fallback;
    if (!raw.isFinite || raw <= 0.02 || raw > 50) return fallback;
    return math.max(raw, 0.02);
  }
}
