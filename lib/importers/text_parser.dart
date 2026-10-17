/// 纯文本解析：编码探测 → 分章 → 分页。
///
/// 为什么分页是"近似"的：
///   真实分页取决于字号、行距、边距、屏幕宽度，这些在导入时还不确定。
///   所以这里只做**按字数的粗分页**（让虚拟长页能立刻算出高度），
///   阅读器拿到真实排版参数后可以再做一次精确分页。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/charset.dart';

/// 一章的解析结果
class TextChapter {
  TextChapter({
    required this.title,
    required this.pages,
    required this.pageCharOffsets,
    required this.startCharOffset,
  });

  final String title;
  final List<String> pages;

  /// 每页首字符在"本章"内的偏移（用于改字号后的位置锚点）
  final List<int> pageCharOffsets;

  /// 本章首字符在全书内的偏移
  final int startCharOffset;
}

class ParsedText {
  ParsedText({
    required this.chapters,
    required this.encoding,
    required this.warnings,
  });

  final List<TextChapter> chapters;
  final String encoding;
  final List<String> warnings;
}

/// 分章正则。顺序有意义：先匹配更具体的模式。
final _chapterPatterns = <RegExp>[
  // 第1章 / 第一章 / 第 12 节 / 第3回 / 第4卷 / 第5话
  RegExp(
    r'^[ \t]*第\s*[0-9零一二三四五六七八九十百千万两]+\s*[章节回卷篇部集话幕]\s*[^\n]{0,40}$',
    multiLine: true,
  ),
  // Chapter 1 / CHAPTER IV
  RegExp(
    r'^[ \t]*chapter\s+[0-9ivxlcdm]+\b[^\n]{0,60}$',
    multiLine: true,
    caseSensitive: false,
  ),
  // 序章 / 楔子 / 尾声 / 番外
  RegExp(
    r'^[ \t]*(序章|序言|楔子|引子|尾声|终章|后记|番外[^\n]{0,20})[ \t]*$',
    multiLine: true,
  ),
];

/// 每页目标字数。真实分页在阅读器里按排版参数重算。
const int kDefaultCharsPerPage = 1200;

/// 单章过大时的硬切阈值（避免"一整本书只有一章"）
const int kMaxCharsPerChapter = 40000;

ParsedText parsePlainText(Uint8List bytes, String name) {
  final warnings = <String>[];

  // ── ① 编码探测 ──
  final sampleLen = math.min(bytes.length, CharsetDetector.sampleBytes);
  final sample = Uint8List.sublistView(bytes, 0, sampleLen);
  final charset = CharsetDetector.detect(sample);

  var text = CharsetDetector.decode(bytes, charset);

  // ── ② 质量校验：UTF-8 解析出来的中文小说，CJK 占比不应该低得离谱 ──
  if (charset.confidence < 0.5) {
    final ratio = CharsetDetector.cjkRatio(text);
    final replacementCount = '�'.allMatches(text).length;
    if (ratio < 0.15 && replacementCount > 20) {
      warnings.add(
        '「$name」的编码可能不是 UTF-8（疑似 GBK/GB18030）。'
        '如需正确显示，请在 pubspec 中加入 fast_gbk 或 charset_converter 后重新导入。',
      );
    }
  }

  // 去掉 BOM 残留
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
    text = text.substring(1);
  }

  // ── ③ 分章 ──
  final hits = <_ChapterHit>[];
  for (final re in _chapterPatterns) {
    for (final m in re.allMatches(text)) {
      if (!_isLineStart(text, m.start)) continue;
      if (m.group(0)!.trim().length > 60) continue;
      hits.add(_ChapterHit(m.start, m.group(0)!.trim()));
    }
  }
  hits.sort((a, b) => a.offset.compareTo(b.offset));

  // 去重 + 合并：相邻 200 字内的连续命中视为同一标题的多行
  final merged = <_ChapterHit>[];
  for (final h in hits) {
    if (merged.isEmpty || h.offset - merged.last.offset > 200) {
      merged.add(h);
    } else if (h.title.length > merged.last.title.length) {
      merged[merged.length - 1] = h; // 保留更完整的标题写法
    }
  }

  final chapters = <TextChapter>[];

  if (merged.isEmpty) {
    // 兜底：没有章节标记 → 按每 kMaxCharsPerChapter 字硬切
    chapters.addAll(_hardSplit(text, '正文', 0));
  } else {
    // 第一段（第一个标题之前的内容）单独成章
    if (merged.first.offset > 200) {
      chapters.addAll(_hardSplit(text.substring(0, merged.first.offset), '卷首', 0));
    }
    for (int i = 0; i < merged.length; i++) {
      final start = merged[i].offset;
      final end = (i + 1 < merged.length) ? merged[i + 1].offset : text.length;
      if (end <= start) continue;
      final body = text.substring(start, end);
      chapters.addAll(_hardSplit(body, merged[i].title, start));
    }
  }

  if (chapters.isEmpty) {
    chapters.add(TextChapter(
      title: '正文',
      pages: [text.isEmpty ? '（空文件）' : text],
      pageCharOffsets: [0],
      startCharOffset: 0,
    ));
  }

  return ParsedText(
    chapters: chapters,
    encoding: charset.encoding,
    warnings: warnings,
  );
}

/// 把一段文本切成"章"和"页"。
///
/// 分页策略：优先在段落边界断开（不要把一句话劈成两页），
/// 段落本身超过目标字数时退化为按字符硬切。
List<TextChapter> _hardSplit(String body, String title, int bodyStartOffset) {
  final paragraphs = _splitParagraphs(body);
  final out = <TextChapter>[];

  final pages = <String>[];
  final pageStartInBody = <int>[];

  final buf = StringBuffer();
  int bufStart = 0; // 当前缓冲内容在 body 中的起始偏移
  int cursor = 0; // 已消费到 body 的哪个位置
  int chapterStart = 0; // 当前章的起始偏移（相对 body）

  void flushPage() {
    if (buf.isEmpty) return;
    pages.add(buf.toString());
    pageStartInBody.add(bufStart);
    buf.clear();
  }

  void flushChapter() {
    flushPage();
    if (pages.isEmpty) return;
    out.add(TextChapter(
      title: out.isEmpty ? title : '$title（${out.length + 1}）',
      pages: List.of(pages),
      pageCharOffsets: List.of(pageStartInBody),
      startCharOffset: bodyStartOffset + chapterStart,
    ));
    pages.clear();
    pageStartInBody.clear();
    chapterStart = cursor;
  }

  for (final para in paragraphs) {
    // 段落本身就超长（例如整本书没有换行）→ 按字符硬切
    if (para.length > kDefaultCharsPerPage * 2) {
      flushPage();
      for (int i = 0; i < para.length; i += kDefaultCharsPerPage) {
        final end = math.min(i + kDefaultCharsPerPage, para.length);
        pages.add(para.substring(i, end));
        pageStartInBody.add(cursor + i);
      }
      cursor += para.length;
      bufStart = cursor;
      if (cursor - chapterStart > kMaxCharsPerChapter) flushChapter();
      continue;
    }

    if (buf.isEmpty) {
      bufStart = cursor;
    } else if (buf.length + para.length > kDefaultCharsPerPage) {
      flushPage();
      bufStart = cursor;
    }

    buf.write(para);
    cursor += para.length;

    // 单章超过阈值 → 断开，避免十万字一章
    if (cursor - chapterStart > kMaxCharsPerChapter) {
      flushChapter();
    }
  }

  flushChapter();

  if (out.isEmpty) {
    out.add(TextChapter(
      title: title,
      pages: [body],
      pageCharOffsets: const [0],
      startCharOffset: bodyStartOffset,
    ));
  }
  return out;
}

/// 按换行切段落，保留换行符本身（阅读时才能保持原貌）
List<String> _splitParagraphs(String body) {
  final out = <String>[];
  final buf = StringBuffer();
  for (final ch in body.codeUnits) {
    buf.writeCharCode(ch);
    if (ch == 0x0A) {
      out.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

bool _isLineStart(String text, int offset) {
  if (offset == 0) return true;
  final prev = text.codeUnitAt(offset - 1);
  return prev == 0x0A || prev == 0x0D;
}

class _ChapterHit {
  _ChapterHit(this.offset, this.title);
  final int offset;
  final String title;
}
