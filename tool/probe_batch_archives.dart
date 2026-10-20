/// 连续导入多个网盘压缩包，看第几个开始失败、失败的真实原因。
///
/// 真机上连续导入 6 本后就再没有新书，但 release 包看不到日志。
/// 用这个工具在 CLI 里复现同一串请求，把每个包的成败和错误打出来。
///
/// ```bash
/// dart run tool/probe_batch_archives.dart <根URL> <用户名> <密码> [个数]
/// ```
library;

import 'dart:io';

import 'package:inkscroll/data/webdav/webdav_client.dart';
import 'package:inkscroll/importers/webdav_archive_importer.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      '用法: dart run tool/probe_batch_archives.dart <根URL> <用户名> <密码> [个数]',
    );
    exitCode = 64;
    return;
  }
  final root = args[0];
  final u = Uri.parse(root);
  final limit = args.length > 3 ? int.tryParse(args[3]) ?? 12 : 12;

  final client = WebDavClient(
    baseUrl: '${u.scheme}://${u.authority}',
    username: args[1],
    password: args[2],
    timeout: const Duration(seconds: 60),
  );

  try {
    final entries = await client.list(root);
    final zips = entries
        .where((e) => !e.isDirectory && e.name.toLowerCase().endsWith('.zip'))
        .toList();
    stdout.writeln('共 ${zips.length} 个 zip，本次试前 $limit 个');
    stdout.writeln('');

    var ok = 0;
    var fail = 0;
    for (var i = 0; i < limit && i < zips.length; i++) {
      final e = zips[i];
      final sw = Stopwatch()..start();
      try {
        final doc = await WebDavArchiveImporter.buildDocument(
          client: client,
          connectionId: 'probe',
          archiveUrl: e.url,
          archiveName: e.name,
          knownSize: e.size,
        );
        sw.stop();
        ok++;
        stdout.writeln(
          '  [$i] ✅ ${e.name}  ${doc.pageCount} 页  ${sw.elapsedMilliseconds} ms',
        );
      } catch (err) {
        sw.stop();
        fail++;
        stdout.writeln(
          '  [$i] ❌ ${e.name}  ${sw.elapsedMilliseconds} ms  -> $err',
        );
      }
    }
    stdout.writeln('');
    stdout.writeln('成功 $ok / 失败 $fail');
  } finally {
    client.close();
  }
}
