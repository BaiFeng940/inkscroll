/// **NAS 连接诊断工具**（命令行）。
///
/// 当 App 里连不上 NAS 时，用这个工具能快速定位是"地址不对"、
/// "账号不对"、还是"根本不是 WebDAV 服务"。
///
/// ## 用法
///
/// ```bash
/// # 无认证
/// dart run tool/webdav_probe.dart http://192.168.1.10:5005/dav
///
/// # 带账号
/// dart run tool/webdav_probe.dart http://192.168.1.10:5005/dav reader mypassword
///
/// # 自签 HTTPS 证书
/// dart run tool/webdav_probe.dart https://192.168.1.10:5006/dav reader pw --insecure
///
/// # 深入某个子目录
/// dart run tool/webdav_probe.dart http://192.168.1.10:5005/dav reader pw --path=漫画
/// ```
///
/// 输出会依次告诉你：
///   1. 能不能连上；
///   2. 认证过不过；
///   3. 是不是 WebDAV（有的地址返回 200 但其实是网页）；
///   4. 目录里有什么，图片几张、尺寸嗅探是否成功。
library;

import 'dart:io';

import 'package:inkscroll/core/errors.dart';
import 'package:inkscroll/core/image_header.dart';
import 'package:inkscroll/data/webdav/webdav_client.dart';
import 'package:inkscroll/importers/import_utils.dart';

Future<void> main(List<String> argv) async {
  final args = <String>[];
  var insecure = false;
  String? subPath;
  for (final a in argv) {
    if (a == '--insecure') {
      insecure = true;
    } else if (a.startsWith('--path=')) {
      subPath = a.substring('--path='.length);
    } else {
      args.add(a);
    }
  }

  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/webdav_probe.dart <URL> [用户名] [密码] '
        '[--insecure] [--path=子目录]');
    exitCode = 64;
    return;
  }

  final url = args[0];
  final user = args.length > 1 ? args[1] : null;
  final pass = args.length > 2 ? args[2] : null;

  final client = WebDavClient(
    baseUrl: url,
    username: user,
    password: pass,
    allowSelfSigned: insecure,
  );

  stdout.writeln('▸ 目标: ${client.baseUrl}');
  if (user != null) stdout.writeln('▸ 账号: $user');
  if (insecure) stdout.writeln('▸ 已允许自签证书');

  try {
    var target = client.baseUrl;
    if (subPath != null && subPath.isNotEmpty) {
      target = '$target/${Uri.encodeComponent(subPath)}';
      stdout.writeln('▸ 子目录: $subPath');
    }

    stdout.writeln('\n① 读取目录…');
    final entries = await client.list(target);
    stdout.writeln('   ✓ 成功，共 ${entries.length} 项');

    final dirs = entries.where((e) => e.isDirectory).toList();
    final files = entries.where((e) => !e.isDirectory).toList();
    final images = files.where((e) => _isImage(e.name)).toList();

    stdout.writeln('   · 目录 ${dirs.length} 个');
    stdout.writeln('   · 文件 ${files.length} 个（其中图片 ${images.length} 张）');

    if (dirs.isNotEmpty) {
      stdout.writeln('\n   子目录:');
      for (final d in dirs.take(10)) {
        stdout.writeln('     📁 ${d.name}');
      }
      if (dirs.length > 10) stdout.writeln('     …还有 ${dirs.length - 10} 个');
    }

    if (images.isNotEmpty) {
      stdout.writeln('\n   前几张图片:');
      for (final img in images.take(5)) {
        final size = img.size == null
            ? ''
            : '  ${(img.size! / 1024).toStringAsFixed(0)}KB';
        stdout.writeln('     🖼 ${img.name}$size');
      }
    }

    // ── 需要能识别出图片才继续 ──
    if (images.isEmpty) {
      stdout.writeln('\n⚠ 这个目录里没有图片。');
      if (dirs.isNotEmpty) {
        stdout.writeln('  试试进入子目录：--path=${dirs.first.name}');
      }
      return;
    }

    // ── 尺寸嗅探 ──
    stdout.writeln('\n② 嗅探图片尺寸（只取前 64KB，验证 Range 是否可用）…');
    final sample = images.take(3).toList();
    for (final img in sample) {
      try {
        final head = await client.getRange(img.url, maxBytes: 64 * 1024);
        final dim = ImageHeaderParser.tryParse(head);
        if (dim == null) {
          stdout.writeln('   ⚠ ${img.name}: 拿到 ${head.length}B，但解析不出尺寸');
        } else {
          stdout.writeln('   ✓ ${img.name}: '
              '${dim.width}×${dim.height} '
              '(比例 ${dim.aspectRatio.toStringAsFixed(3)})');
        }
      } catch (e) {
        stdout.writeln('   ✗ ${img.name}: $e');
      }
    }

    // ── 取一整张图 ──
    stdout.writeln('\n③ 下载一张完整图片…');
    final sw = Stopwatch()..start();
    final full = await client.get(images.first.url);
    sw.stop();
    final speed = sw.elapsedMilliseconds == 0
        ? '很快'
        : '${(full.length / 1024 / sw.elapsedMilliseconds * 1000).toStringAsFixed(0)} KB/s';
    stdout.writeln('   ✓ ${images.first.name}: ${full.length} 字节，'
        '用时 ${sw.elapsedMilliseconds}ms（约 $speed）');

    stdout.writeln('\n══════════════════════════════');
    stdout.writeln('全部检查通过 ✅');
    stdout.writeln('在 App 里用这个地址即可：${client.baseUrl}');
    if (subPath != null) stdout.writeln('并进入子目录：$subPath');
    stdout.writeln('══════════════════════════════');
  } on AppError catch (e) {
    stdout.writeln('\n✗ 失败：${e.message}');
    if (e.technicalDetail != null) {
      stdout.writeln('\n技术细节: ${e.technicalDetail}');
    }
    exitCode = 1;
  } catch (e) {
    stdout.writeln('\n✗ 未预期的错误：$e');
    exitCode = 1;
  } finally {
    client.close();
  }
}

bool _isImage(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  final ext = name.substring(dot).toLowerCase();
  return kImageExtensions.contains(ext) ||
      kUnsupportedImageExtensions.contains(ext);
}
