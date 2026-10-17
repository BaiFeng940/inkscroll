/// TXT 文件导入。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../data/byte_store.dart';
import '../data/importer.dart';
import '../reader/document.dart';
import 'text_parser.dart';

/// 单文件 TXT 导入允许的最大字节数（超过时提示用户，避免一次读爆内存）
const int kMaxTxtBytes = 128 << 20; // 128MB

class TxtImporter implements Importer {
  TxtImporter({required this.store});

  final ByteStore store;

  @override
  String get id => 'txt';

  @override
  bool canHandle(SourceProbe probe) => probe.formatName == 'txt';

  @override
  Future<ImportOutcome> run(ImportContext ctx) async {
    final srcPath = ctx.pick.path;
    if (srcPath == null) return const ImportFailure(GenericError('没有选择文件'));

    final file = File(srcPath);
    final stat = await file.stat();
    if (stat.size > kMaxTxtBytes) {
      return ImportFailure(GenericError(
        '文本文件过大（${ByteStore.humanSize(stat.size)}）。'
        '单文件上限 ${ByteStore.humanSize(kMaxTxtBytes)}。',
      ));
    }

    // 复制到私有目录，保证离线可用
    final bookId = ctx.pick.sourceId;
    final dstPath = p.join(store.bookDir(bookId), p.basename(srcPath));
    ctx.onProgress(0.05, '正在复制文件…');
    await ByteStore.copyFile(srcPath, dstPath,
        onProgress: (r, l) => ctx.onProgress(0.05 + r * 0.25, l));

    ctx.onProgress(0.32, '正在探测编码…');
    final bytes = await File(dstPath).readAsBytes();

    ctx.onProgress(0.45, '正在分章分页…');
    final parsed = parsePlainText(bytes, p.basename(srcPath));

    final pages = <String, PageNode>{};
    final chapters = <Chapter>[];

    for (int ci = 0; ci < parsed.chapters.length; ci++) {
      final tc = parsed.chapters[ci];
      final pageIds = <String>[];
      for (int j = 0; j < tc.pages.length; j++) {
        final id = 't:$ci#$j';
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
      chapters.add(Chapter(index: ci, title: tc.title, pageIds: pageIds));
    }

    ctx.onProgress(1.0, '完成');

    final warnings = <String>[...parsed.warnings];
    if (parsed.encoding != 'utf-8') {
      warnings.add('检测到编码：${parsed.encoding}');
    }

    return ImportedDocument(Document(
      id: 'doc_$bookId',
      bookId: bookId,
      title: ctx.pick.displayName,
      kind: DocumentKind.novel,
      chapters: chapters,
      pages: pages,
      hint: DocumentLayoutHint.pagePreferred,
      warnings: warnings.toSet().toList(),
    ));
  }
}
