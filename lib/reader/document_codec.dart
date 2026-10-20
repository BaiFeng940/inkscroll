/// Document 的 JSON 序列化。
///
/// 为什么要序列化而不是每次重新解析：
///   重新解析一个 5000 页的 zip 需要读中央目录 + 数千次尺寸嗅探
///   （约 1~3 秒），而用户点开一本书期望是"秒开"。
///   导入时把已经算好的 Document 落盘，之后打开就是一次 JSON 解析。
///
/// 为什么可以安全序列化：
///   Document 里**没有任何字节**（只有 ContentRef），
///   所以 JSON 很小 —— 5000 页大约 1~2 MB。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'document.dart';

class DocumentCodec {
  static const _version = 1;

  static String pathFor(String bookDir) => p.join(bookDir, 'document.json');

  static Future<void> save(String bookDir, Document doc) async {
    // ★ 必须先确保目录存在。
    //   本地导入的书目录是"复制文件时顺带建好"的，所以以前没暴露问题；
    //   但 WebDAV 导入**不往书目录里复制任何文件**，目录也就不存在，
    //   于是写 document.json.tmp 直接抛 PathNotFoundException。
    //   在这里兜底比在每个调用方各建一次可靠得多。
    final dir = Directory(bookDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final file = File(pathFor(bookDir));
    final tmp = File('${file.path}.tmp');
    // 先写临时文件再改名：避免写入过程中被杀导致文件损坏
    await tmp.writeAsString(jsonEncode(toJson(doc)), flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }

  static Future<Document?> load(String bookDir) async {
    final file = File(pathFor(bookDir));
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      if (map['version'] != _version) return null;
      return fromJson(map);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------
  static Map<String, dynamic> toJson(Document d) => {
        'version': _version,
        'id': d.id,
        'bookId': d.bookId,
        'title': d.title,
        'kind': d.kind.name,
        'unit': d.unit.name,
        'hint': d.hint.name,
        'warnings': d.warnings,
        'chapters': d.chapters
            .map((c) => {
                  'index': c.index,
                  'title': c.title,
                  'pageIds': c.pageIds,
                })
            .toList(),
        'pages': d.pages.map((k, v) => MapEntry(k, _pageToJson(v))),
      };

  static Document fromJson(Map<String, dynamic> m) {
    final pages = <String, PageNode>{};
    final rawPages = (m['pages'] as Map).cast<String, dynamic>();
    for (final entry in rawPages.entries) {
      pages[entry.key] =
          _pageFromJson((entry.value as Map).cast<String, dynamic>());
    }

    final chapters = (m['chapters'] as List)
        .map((e) => (e as Map).cast<String, dynamic>())
        .map((c) => Chapter(
              index: c['index'] as int? ?? 0,
              title: c['title'] as String? ?? '',
              pageIds: (c['pageIds'] as List).cast<String>(),
            ))
        .toList();

    return Document(
      id: m['id'] as String,
      bookId: m['bookId'] as String,
      title: m['title'] as String,
      kind: _enumByName(DocumentKind.values, m['kind'], DocumentKind.comic),
      chapters: chapters,
      pages: pages,
      unit: _enumByName(ReadingUnit.values, m['unit'], ReadingUnit.page),
      hint: _enumByName(
          DocumentLayoutHint.values, m['hint'], DocumentLayoutHint.webtoonPreferred),
      warnings: (m['warnings'] as List?)?.cast<String>() ?? const [],
    );
  }

  // ------------------------------------------------------------------
  static Map<String, dynamic> _pageToJson(PageNode page) => {
        'id': page.id,
        'kind': page.kind.name,
        'aspect': page.aspectRatio,
        'title': page.title,
        'content': _contentToJson(page.content),
      };

  static PageNode _pageFromJson(Map<String, dynamic> m) => PageNode(
        id: m['id'] as String,
        kind: _enumByName(PageKind.values, m['kind'], PageKind.image),
        aspectRatio: (m['aspect'] as num?)?.toDouble(),
        title: m['title'] as String?,
        content: _contentFromJson((m['content'] as Map).cast<String, dynamic>()),
      );

  static Map<String, dynamic> _contentToJson(PageContent c) {
    switch (c) {
      case ImageContent():
        return {
          't': 'image',
          'ref': _refToJson(c.ref),
          'w': c.intrinsicWidth,
          'h': c.intrinsicHeight,
          'mime': c.mimeType,
        };
      case TextPageContent():
        return {
          't': 'text',
          'text': c.text,
          'heading': c.headingLevel,
          'charOffset': c.pageStartCharOffset,
        };
      case PdfPageContent():
        return {
          't': 'pdf',
          'ref': _refToJson(c.ref),
          'page': c.pageIndex,
          'wpt': c.widthPt,
          'hpt': c.heightPt,
        };
    }
  }

  static PageContent _contentFromJson(Map<String, dynamic> m) {
    switch (m['t'] as String?) {
      case 'text':
        return TextPageContent(
          text: m['text'] as String? ?? '',
          headingLevel: m['heading'] as int?,
          pageStartCharOffset: m['charOffset'] as int? ?? 0,
        );
      case 'pdf':
        return PdfPageContent(
          ref: _refFromJson((m['ref'] as Map).cast<String, dynamic>()),
          pageIndex: m['page'] as int? ?? 0,
          widthPt: (m['wpt'] as num?)?.toDouble() ?? 0,
          heightPt: (m['hpt'] as num?)?.toDouble() ?? 0,
        );
      case 'image':
      default:
        return ImageContent(
          ref: _refFromJson((m['ref'] as Map).cast<String, dynamic>()),
          intrinsicWidth: m['w'] as int?,
          intrinsicHeight: m['h'] as int?,
          mimeType: m['mime'] as String?,
        );
    }
  }

  static Map<String, dynamic> _refToJson(ContentRef ref) {
    switch (ref) {
      case LooseFileRef():
        return {'t': 'file', 'path': ref.path};
      case ArchiveEntryRef():
        return {
          't': 'archive',
          'archive': ref.archivePath,
          'entry': ref.entryPath,
          'size': ref.uncompressedSize,
        };
      case InlineRef():
        // InlineRef 只用于极小内容，序列化成 base64
        return {'t': 'inline', 'b64': base64Encode(ref.bytes)};
      case WebDavRef():
        return {'t': 'webdav', 'url': ref.url, 'conn': ref.connectionId};
      case WebDavArchiveRef():
        return {
          't': 'webdavArchive',
          'archiveUrl': ref.archiveUrl,
          'entry': ref.entryPath,
          'conn': ref.connectionId,
        };
      case PdfPageRef():
        return {'t': 'pdf', 'path': ref.path, 'page': ref.pageIndex};
    }
  }

  static ContentRef _refFromJson(Map<String, dynamic> m) {
    switch (m['t'] as String?) {
      case 'archive':
        return ArchiveEntryRef(
          archivePath: m['archive'] as String,
          entryPath: m['entry'] as String,
          uncompressedSize: m['size'] as int? ?? 0,
        );
      case 'inline':
        return InlineRef(base64Decode(m['b64'] as String));
      case 'webdav':
        return WebDavRef(
          url: m['url'] as String,
          connectionId: m['conn'] as String? ?? '',
        );
      case 'webdavArchive':
        return WebDavArchiveRef(
          connectionId: m['conn'] as String? ?? '',
          archiveUrl: m['archiveUrl'] as String,
          entryPath: m['entry'] as String,
        );
      case 'pdf':
        return PdfPageRef(
          path: m['path'] as String,
          pageIndex: m['page'] as int? ?? 0,
        );
      case 'file':
      default:
        return LooseFileRef(m['path'] as String);
    }
  }

  static T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
    if (name is! String) return fallback;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }
}

/// 未使用但保留：给未来的"内联小图"用
Uint8List emptyBytes() => Uint8List(0);
