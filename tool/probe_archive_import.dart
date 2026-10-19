/// 用**产品里的真实导入器**验证"网盘压缩包建书"这条链路。
///
/// 覆盖：`WebDavArchiveImporter.buildDocument` → 得到 Document（页数/标题/警告）。
/// 它不依赖 Flutter，所以能 `dart run` 直接跑，把真实网盘当测试台。
///
/// ## 用法
///
/// ```bash
/// dart run tool/probe_archive_import.dart <zip完整URL> <用户名> <密码> [已知字节数]
/// ```
library;

import 'dart:io';

import 'package:inkscroll/data/webdav/webdav_client.dart';
import 'package:inkscroll/importers/webdav_archive_importer.dart';
import 'package:inkscroll/reader/document.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      '用法: dart run tool/probe_archive_import.dart <zipURL> <用户名> <密码> [字节数]',
    );
    exitCode = 64;
    return;
  }
  final url = args[0];
  final user = args[1];
  final pass = args[2];
  final knownSize = args.length > 3 ? int.tryParse(args[3]) : null;

  final u = Uri.parse(url);
  final client = WebDavClient(
    baseUrl: '${u.scheme}://${u.authority}',
    username: user,
    password: pass,
    timeout: const Duration(seconds: 60),
  );

  // pathSegments 已经是解码后的，不要再 decodeComponent
  final name = u.pathSegments.isEmpty ? 'archive' : u.pathSegments.last;
  final sw = Stopwatch()..start();
  try {
    final doc = await WebDavArchiveImporter.buildDocument(
      client: client,
      connectionId: 'probe',
      archiveUrl: url,
      archiveName: name,
      knownSize: knownSize,
      onProgress: (p, label) {
        stdout.writeln('  [${(p * 100).toStringAsFixed(0)}%] $label');
      },
    );
    sw.stop();

    stdout.writeln('');
    stdout.writeln('=== 建书结果 ===');
    stdout.writeln('  标题     : ${doc.title}');
    stdout.writeln('  页数     : ${doc.pageCount}');
    stdout.writeln('  章节数   : ${doc.chapterCount}');
    stdout.writeln('  布局提示 : ${doc.hint.name}');
    stdout.writeln('  耗时     : ${sw.elapsedMilliseconds} ms');
    for (final w in doc.warnings) {
      stdout.writeln('  ⚠ $w');
    }

    // 抽查首页的 ref 与尺寸估算
    final first = doc.pagesInOrder.first;
    final content = first.content;
    if (content is ImageContent && content.ref is WebDavArchiveRef) {
      final r = content.ref as WebDavArchiveRef;
      stdout.writeln('');
      stdout.writeln('=== 首页 ===');
      stdout.writeln('  条目     : ${r.entryPath}');
      stdout.writeln('  比例     : ${first.aspectRatio?.toStringAsFixed(4) ?? "未知"}');
    }
    stdout.writeln('');
    stdout.writeln('✅ 导入器可用');
  } catch (e) {
    sw.stop();
    stderr.writeln('❌ 失败（${sw.elapsedMilliseconds} ms）: $e');
    exitCode = 1;
  } finally {
    client.close();
  }
}
