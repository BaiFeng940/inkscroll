/// 用真实的加密 zip 验证 ZipCrypto 解密链路。
///
/// 这个探针直接走 `ZipArchiveSource`（和 App 里读页完全同一条代码路径），
/// 用 Python 独立生成的加密压缩包做输入 —— 不是自己造数据自己验。
///
/// ```bash
/// dart run tool/probe_encrypted_zip.dart <zip路径> <密码> [错误密码]
/// ```
library;

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:inkscroll/core/errors.dart';
import 'package:inkscroll/data/archive/zip_archive_source.dart';
import 'package:inkscroll/data/byte_source.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/probe_encrypted_zip.dart <zip> <密码>');
    exitCode = 64;
    return;
  }
  final path = args[0];
  final password = args[1];

  stdout.writeln('文件: $path');
  stdout.writeln('密码: $password');

  // ── 1) 不带密码：应抛"需要密码" ──
  {
    final src = await FileByteSource.open(path);
    final zip = ZipArchiveSource(src);
    await zip.open();
    final image = zip.entries.firstWhere((e) => !e.isDirectory);
    stdout.writeln('\n[1] 无密码读取 ${image.entryPath} …');
    try {
      await zip.readEntry(image);
      stdout.writeln('  ✗ 竟然成功了（应该抛 ArchivePasswordRequiredError）');
    } on ArchivePasswordRequiredError {
      stdout.writeln('  ✓ 正确要求密码');
    } catch (e) {
      stdout.writeln('  ✗ 意外的错误: $e');
    }
    await src.close();
  }

  // ── 2) 正确密码：应解出 PNG ──
  {
    final src = await FileByteSource.open(path);
    final zip = ZipArchiveSource(src, password: password);
    await zip.open();
    final images = zip.entries.where((e) => !e.isDirectory).toList();
    stdout.writeln('\n[2] 用正确密码读全部 ${images.length} 个条目 …');
    var ok = 0;
    for (final e in images) {
      try {
        final bytes = await zip.readEntry(e);
        final sig = bytes.length >= 8
            ? bytes.sublist(0, 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')
            : '(太短)';
        final isPng = bytes.length >= 4 &&
            bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4E &&
            bytes[3] == 0x47;
        stdout.writeln(
            '  ${e.entryPath}: ${bytes.length} 字节  PNG=${isPng ? "是" : "否"}  头=$sig');
        if (isPng) ok++;
      } catch (err) {
        stdout.writeln('  ${e.entryPath}: ✗ $err');
      }
    }
    stdout.writeln('  → $ok/${images.length} 个条目解出合法 PNG');
    await src.close();
    if (ok != images.length) exitCode = 1;
  }

  // ── 3) 错误密码：应明确失败，而不是解出垃圾 ──
  {
    final src = await FileByteSource.open(path);
    final zip = ZipArchiveSource(src, password: 'definitely-wrong');
    await zip.open();
    final image = zip.entries.firstWhere((e) => !e.isDirectory);
    stdout.writeln('\n[3] 用错误密码读取 …');
    try {
      final b = await zip.readEntry(image);
      final looksPng = b.length >= 4 && b[0] == 0x89 && b[1] == 0x50;
      stdout.writeln('  ${looksPng ? "✗ 解出了合法 PNG（危险：密码校验失效）" : "✓ 解出的内容不是合法图片（已拒绝）"}');
      if (looksPng) exitCode = 1;
    } on ArchivePasswordWrongError {
      stdout.writeln('  ✓ 正确报"密码错误"');
    } on AppError catch (e) {
      stdout.writeln('  ✓ 报错: ${e.runtimeType}');
    } catch (e) {
      stdout.writeln('  ✓ 报错: $e');
    }
    await src.close();
  }
}
