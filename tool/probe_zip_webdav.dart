/// 验证「网盘上的 ZIP 直接在线读」这条链路 —— 用的是**产品里的真实代码**。
///
/// 覆盖 `WebDavByteSource` → `ZipArchiveSource` → 读条目 → 解压 → 识别图片。
/// 跑通它就能确定 App 里不需要为网盘 zip 另写一套解析。
///
/// 之所以做成 CLI 而不是单元测试：它会真连公网网盘，不适合放进 CI。
/// 但用到的每一行都是 App 生产代码（这些文件都不依赖 Flutter，所以
/// `dart run` 能直接跑）。
///
/// ## 用法
///
/// ```bash
/// dart run tool/probe_zip_webdav.dart <zip的完整URL> <用户名> <密码>
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:inkscroll/data/archive/zip_archive_source.dart';
import 'package:inkscroll/data/webdav/webdav_byte_source.dart';
import 'package:inkscroll/data/webdav/webdav_client.dart';
import 'package:inkscroll/importers/import_utils.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      '用法: dart run tool/probe_zip_webdav.dart <zip完整URL> <用户名> <密码>',
    );
    exitCode = 64;
    return;
  }
  final zipUrl = args[0];
  final user = args[1];
  final pass = args[2];

  // 从 URL 推 origin 作为 WebDavClient 的 baseUrl
  final u = Uri.parse(zipUrl);
  final origin = '${u.scheme}://${u.authority}';

  final client = WebDavClient(
    baseUrl: origin,
    username: user,
    password: pass,
    timeout: const Duration(seconds: 40),
  );
  final sw = Stopwatch()..start();

  try {
    // ── 1. 建字节源（此时还没发任何请求）──
    final src = WebDavByteSource(url: zipUrl, client: client);
    final total = await src.length();
    stdout.writeln('压缩包大小 : $total 字节 '
        '(${(total / 1024 / 1024).toStringAsFixed(1)} MB)');
    stdout.writeln('长度查询后 : 请求 ${src.requestCount} 次，'
        '${(src.bytesFetched / 1024).toStringAsFixed(1)} KB');

    // ── 2. 打开 ZIP：只会读 EOCD + 中央目录 ──
    final zip = ZipArchiveSource(src);
    await zip.open();
    stdout.writeln('');
    stdout.writeln('=== 打开压缩包（只读目录）===');
    stdout.writeln('  条目总数 : ${zip.entries.length}');
    stdout.writeln('  耗时     : ${sw.elapsedMilliseconds} ms');
    stdout.writeln('  已拉取   : 请求 ${src.requestCount} 次，'
        '${(src.bytesFetched / 1024).toStringAsFixed(1)} KB');
    final pct = total == 0 ? 0.0 : src.bytesFetched * 100 / total;
    stdout.writeln('  占整包   : ${pct.toStringAsFixed(3)}% '
        '← 只看目录，没下载整包');

    // ── 3. 图片条目 ──
    final images =
        zip.entries.where((e) => kImageExtensions.contains(_ext(e.entryPath))).toList()
          ..sort((a, b) => compareByOriginalName(a.entryPath, b.entryPath));
    stdout.writeln('');
    stdout.writeln('  其中图片 : ${images.length} 张');
    for (final e in images.take(5)) {
      stdout.writeln('    · ${e.entryPath}  '
          '(压缩 ${e.compressedSize} → 原始 ${e.uncompressedSize}，'
          'method=${e.compressionMethod})');
    }

    if (images.isEmpty) {
      stdout.writeln('没有图片条目，结束');
      return;
    }

    // ── 4. 只读一张图：这就是 App 翻页时发生的事 ──
    final before = src.bytesFetched;
    final sw2 = Stopwatch()..start();
    final bytes = await zip.readEntry(images.first);
    sw2.stop();
    final used = src.bytesFetched - before;
    stdout.writeln('');
    stdout.writeln('=== 读取第 1 张图 ===');
    stdout.writeln('  解出字节 : ${bytes.length} 字节');
    stdout.writeln('  网络流量 : ${(used / 1024).toStringAsFixed(1)} KB');
    stdout.writeln('  耗时     : ${sw2.elapsedMilliseconds} ms');
    final head = Uint8List.fromList(
      bytes.length > 64 ? bytes.sublist(0, 64) : bytes,
    );
    stdout.writeln('  文件头   : ${_hex(head, 8)} '
        '(${_kind(head)})');

    final totalUsed = src.bytesFetched;
    final totalPct = total == 0 ? 0.0 : totalUsed * 100 / total;
    stdout.writeln('');
    stdout.writeln('=== 汇总 ===');
    stdout.writeln('  全程请求 : ${src.requestCount} 次');
    stdout.writeln('  全程流量 : ${(totalUsed / 1024).toStringAsFixed(1)} KB '
        '/ $total 字节 = ${totalPct.toStringAsFixed(2)}%');
    stdout.writeln('  结论     : ${totalPct < 60 ? "✅ 没有下载整包，在线读可行" : "⚠ 流量偏高"}');
    await zip.close();
  } finally {
    client.close();
  }
}

String _ext(String path) {
  final i = path.lastIndexOf('.');
  return i < 0 ? '' : path.substring(i).toLowerCase();
}

String _hex(Uint8List b, int n) => b
    .take(n)
    .map((x) => x.toRadixString(16).padLeft(2, '0'))
    .join(' ')
    .toUpperCase();

String _kind(Uint8List b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'PNG';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'JPEG';
  }
  if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return 'GIF';
  }
  if (b.length >= 12 &&
      String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
    return 'WEBP';
  }
  return '未知';
}
