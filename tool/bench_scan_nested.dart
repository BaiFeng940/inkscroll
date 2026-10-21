/// 实测「合集嵌套扫描」串行 vs 并发的差距。
///
/// 只测**列目录**这一件事（不下载图片），因为它正是网盘库扫描慢的瓶颈：
/// 每个子目录一次 PROPFIND，串行等于把 RTT 首尾相接累加。
///
/// ```bash
/// dart run tool/bench_scan_nested.dart <根URL> <用户名> <密码> [合集数] [每合集子目录数]
/// ```
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:inkscroll/data/webdav/webdav_client.dart';

Future<int> _run(
  WebDavClient client,
  List<WebDavEntry> dirs,
  int concurrency,
  int perDir,
) async {
  final sw = Stopwatch()..start();
  var next = 0;
  var requests = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= dirs.length) return;
      try {
        final entries = await client.list(dirs[i].url);
        requests++;
        final subs = entries.where((e) => e.isDirectory).take(perDir).toList();
        for (final s in subs) {
          await client.list(s.url);
          requests++;
        }
      } catch (_) {
        // 单个失败不影响计时
      }
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
  sw.stop();
  print('  并发 $concurrency：${sw.elapsedMilliseconds} ms，$requests 次 PROPFIND');
  return sw.elapsedMilliseconds;
}

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('用法: dart run tool/bench_scan_nested.dart <根URL> <用户> <密码>');
    exitCode = 64;
    return;
  }
  final root = args[0];
  final u = Uri.parse(root);
  final collections = args.length > 3 ? int.tryParse(args[3]) ?? 8 : 8;
  final perDir = args.length > 4 ? int.tryParse(args[4]) ?? 8 : 8;

  final client = WebDavClient(
    baseUrl: '${u.scheme}://${u.authority}',
    username: args[1],
    password: args[2],
    timeout: const Duration(seconds: 60),
  );

  try {
    final entries = await client.list(root);
    final dirs = entries
        .where((e) => e.isDirectory)
        .take(collections)
        .toList();
    print('根目录下取 $collections 个合集目录，每个再列 $perDir 个子目录');
    print('合计约 ${dirs.length * (1 + perDir)} 次 PROPFIND\n');

    final serial = await _run(client, dirs, 1, perDir);
    final parallel = await _run(client, dirs, 4, perDir);

    if (serial > 0) {
      print('\n  串行 $serial ms → 并发 $parallel ms'
          '，加速 ${(serial / parallel).toStringAsFixed(2)}x');
      print('  按 38 个合集 × 8 个子目录估算：'
          '${(serial / dirs.length * 38 / 1000).toStringAsFixed(1)} s → '
          '${(parallel / dirs.length * 38 / 1000).toStringAsFixed(1)} s');
    }
  } finally {
    client.close();
  }
}
