/// 验证 `scanLibrary` 对真实网盘的扫描结果（文件夹 vs 压缩包）。
///
/// 用它就能区分"扫描没找到"和"导入失败"——真机上没有日志很难判断。
///
/// ```bash
/// dart run tool/probe_scan.dart <根URL> <用户名> <密码>
/// ```
library;

import 'dart:io';

import 'package:inkscroll/data/webdav/webdav_client.dart';
import 'package:inkscroll/importers/webdav_folder_importer.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('用法: dart run tool/probe_scan.dart <根URL> <用户名> <密码>');
    exitCode = 64;
    return;
  }
  final url = args[0];
  final u = Uri.parse(url);
  final client = WebDavClient(
    baseUrl: '${u.scheme}://${u.authority}',
    username: args[1],
    password: args[2],
    timeout: const Duration(seconds: 60),
  );

  final sw = Stopwatch()..start();
  try {
    final entries = await client.list(url);
    stdout.writeln('根目录条目: ${entries.length}');
    final dirs = entries.where((e) => e.isDirectory).length;
    final files = entries.where((e) => !e.isDirectory).length;
    final zips = entries
        .where((e) => !e.isDirectory && e.name.toLowerCase().endsWith('.zip'))
        .length;
    final cbz = entries
        .where((e) => !e.isDirectory && e.name.toLowerCase().endsWith('.cbz'))
        .length;
    stdout.writeln('  目录 $dirs / 文件 $files（其中 .zip $zips，.cbz $cbz）');

    sw.reset();
    final candidates = await WebDavFolderImporter.scanLibrary(client, url);
    sw.stop();
    final archiveCandidates = candidates.where((c) => c.isArchive).length;
    stdout.writeln('');
    stdout.writeln('scanLibrary 结果（${sw.elapsedMilliseconds} ms）');
    stdout.writeln('  总候选   : ${candidates.length}');
    stdout.writeln('  压缩包   : $archiveCandidates');
    stdout.writeln('  图片文件夹: ${candidates.length - archiveCandidates}');
    stdout.writeln('');
    stdout.writeln('前 5 个压缩包候选:');
    for (final c in candidates.where((c) => c.isArchive).take(5)) {
      stdout.writeln('  · ${c.name}  (${c.archiveSize ?? "?"} 字节)');
    }
    stdout.writeln('');
    stdout.writeln('前 5 个图片文件夹候选:');
    for (final c in candidates.where((c) => !c.isArchive).take(5)) {
      stdout.writeln('  · ${c.name}  (${c.images.length} 张)');
    }
  } finally {
    client.close();
  }
}
