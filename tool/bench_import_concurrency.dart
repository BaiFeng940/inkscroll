/// 并发导入基准：串行 vs 4 路并发。
///
/// 每本压缩包的耗时几乎全是网络往返，所以并发应该接近线性收益。
/// 这个探针把同一批包跑两遍，直接给出墙钟时间对比。
///
/// ```bash
/// dart run tool/bench_import_concurrency.dart <根URL> <用户名> <密码> [个数]
/// ```
library;

import 'dart:io';

import 'package:inkscroll/data/webdav/webdav_client.dart';
import 'package:inkscroll/importers/webdav_archive_importer.dart';

Future<int> _run(
  WebDavClient client,
  List<WebDavEntry> zips,
  int concurrency,
) async {
  final sw = Stopwatch()..start();
  var next = 0;
  var ok = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= zips.length) return;
      final e = zips[i];
      try {
        await WebDavArchiveImporter.buildDocument(
          client: client,
          connectionId: 'bench',
          archiveUrl: e.url,
          archiveName: e.name,
          knownSize: e.size,
        );
        ok++;
      } catch (_) {
        // 失败不影响计时结论
      }
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
  sw.stop();
  stdout.writeln(
      '  并发 $concurrency：${sw.elapsedMilliseconds} ms，成功 $ok/${zips.length}');
  return sw.elapsedMilliseconds;
}

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
        '用法: dart run tool/bench_import_concurrency.dart <根URL> <用户名> <密码> [个数]');
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
        .take(limit)
        .toList();
    stdout.writeln('共 ${zips.length} 个 zip，每个包跑两遍（顺序会影响 CDN 缓存，'
        '所以先串行再并发）');
    stdout.writeln('');

    final serial = await _run(client, zips, 1);
    final parallel = await _run(client, zips, 4);

    if (serial > 0) {
      final speedup = serial / parallel;
      stdout.writeln('');
      stdout.writeln('  串行 ${serial} ms → 并发 ${parallel} ms'
          '，加速 ${speedup.toStringAsFixed(2)}x');
      stdout.writeln('  按 170 本估算：'
          '${(serial / zips.length * 170 / 1000).toStringAsFixed(0)} 秒 → '
          '${(parallel / zips.length * 170 / 1000).toStringAsFixed(0)} 秒');
    }
  } finally {
    client.close();
  }
}
