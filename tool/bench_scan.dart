/// 导入性能 A/B 基准：**旧请求模式 vs 新请求模式**。
///
/// 不参与产品运行，只用来量化导入优化的收益。
///
/// ## 为什么测"请求模式"而不是直接调 App 代码
///
/// App 里的 WebDAV 导入链路会间接 import `package:flutter`，
/// 而 `dart run` 的 VM 没有 Flutter 引擎，编不过。
/// 所以这里用纯 `http` 复现**完全相同的请求序列**：
///
///   旧: 串行 PROPFIND × N；每本 16 次 Range 嗅探（并发 4，分 4 轮）；
///       每本新建一次连接（= 一次 TCP+TLS 握手）
///   新: 并行 5 路 PROPFIND；每本 4 次 Range 嗅探（一轮发完）；
///       全程复用同一条连接
///
/// 这正是优化的两个大头，差距可以直接对应到用户体感。
///
/// ## 用法
///
/// ```bash
/// # 1) 起一个带 60ms 延迟的模拟服务器（模拟公网 / 隧道往返）
/// dart run tool/webdav_test_server.dart <库目录> 8100 reader reader --delay-ms=60
///
/// # 2) 跑基准
/// dart run tool/bench_scan.dart http://127.0.0.1:8100/dav reader reader
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// 旧实现参数（优化前）
const int oldSniffSamples = 16;
const int oldSniffConcurrency = 4;

/// 新实现参数（与 WebDavFolderImporter 保持一致）
const int newSniffSamples = 4;
const int newSniffConcurrency = 6;
const int newScanConcurrency = 5;

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      '用法: dart run tool/bench_scan.dart <WebDAV根URL> <用户名> <密码>',
    );
    exitCode = 64;
    return;
  }
  final baseUrl = args[0].replaceAll(RegExp(r'/+$'), '');
  final auth = 'Basic ${base64Encode(utf8.encode('${args[1]}:${args[2]}'))}';

  stdout.writeln('基准目标: $baseUrl');
  stdout.writeln('');

  final rootEntries = await _list(baseUrl, auth, client: null);
  final subdirs = rootEntries.where((e) => e.isDirectory).toList();
  stdout.writeln('子目录数量: ${subdirs.length}');
  if (subdirs.isEmpty) {
    stderr.writeln('没有子目录，无法基准');
    exitCode = 65;
    return;
  }

  // ── A. 扫描：旧 = 串行 + 每本新建连接 ──
  var sw = Stopwatch()..start();
  final oldBooks = <String, List<String>>{};
  for (final d in subdirs) {
    final entries = await _list(d.url, auth, client: null);
    final images = _imagesOf(entries);
    if (images.isNotEmpty) oldBooks[d.url] = images;
  }
  sw.stop();
  final oldScanMs = sw.elapsedMilliseconds;

  // ── B. 扫描：新 = 并行 5 路 + 复用连接 ──
  sw = Stopwatch()..start();
  final shared = http.Client();
  final newBooks = <String, List<String>>{};
  {
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= subdirs.length) return;
        final d = subdirs[i];
        try {
          final entries = await _list(d.url, auth, client: shared);
          final images = _imagesOf(entries);
          if (images.isNotEmpty) newBooks[d.url] = images;
        } catch (_) {
          // 单个失败不影响其他
        }
      }
    }

    await Future.wait(List.generate(
      math.min(newScanConcurrency, subdirs.length),
      (_) => worker(),
    ));
  }
  sw.stop();
  final newScanMs = sw.elapsedMilliseconds;

  stdout.writeln('');
  stdout.writeln('=== 扫描阶段（${subdirs.length} 个子目录）===');
  stdout.writeln('  旧（串行，每本新建连接） : ${oldScanMs} ms  发现 ${oldBooks.length} 本');
  stdout.writeln('  新（并行 5 路，复用连接） : ${newScanMs} ms  发现 ${newBooks.length} 本');
  if (newScanMs > 0) {
    stdout.writeln('  加速: ${(oldScanMs / newScanMs).toStringAsFixed(2)}x');
  }

  // 挑**图片最多**的那本来测嗅探 —— 只有图片数 >= 16 才能体现
  // "16 样本分 4 轮" 和 "4 样本发 1 轮" 的差距。
  var sampleImages = <String>[];
  for (final list in newBooks.values) {
    if (list.length > sampleImages.length) sampleImages = list;
  }
  stdout.writeln('');
  stdout.writeln('（嗅探样本取自最大的一个文件夹：${sampleImages.length} 张图）');

  // ── C. 嗅探：旧 = 16 样本 / 并发 4 / 新建连接 ──
  sw = Stopwatch()..start();
  {
    final c = http.Client();
    try {
      final take = sampleImages.take(oldSniffSamples).toList();
      for (var i = 0; i < take.length; i += oldSniffConcurrency) {
        final end = math.min(i + oldSniffConcurrency, take.length);
        await Future.wait([
          for (var j = i; j < end; j++) _rangeGet(take[j], auth, c),
        ]);
      }
    } finally {
      c.close();
    }
  }
  sw.stop();
  final oldSniffMs = sw.elapsedMilliseconds;

  // ── D. 嗅探：新 = 4 样本 / 并发 6 / 复用连接 ──
  sw = Stopwatch()..start();
  {
    final take = sampleImages.take(newSniffSamples).toList();
    await Future.wait([
      for (final url in take) _rangeGet(url, auth, shared),
    ]);
  }
  sw.stop();
  final newSniffMs = sw.elapsedMilliseconds;
  shared.close();

  stdout.writeln('');
  stdout.writeln('=== 单本尺寸嗅探 ===');
  stdout.writeln('  旧（16 样本 / 并发 4） : ${oldSniffMs} ms');
  stdout.writeln('  新（4 样本 / 并发 6）  : ${newSniffMs} ms');
  if (newSniffMs > 0) {
    stdout.writeln('  加速: ${(oldSniffMs / newSniffMs).toStringAsFixed(2)}x');
  }

  final books = newBooks.length;
  final oldTotal = oldScanMs + oldSniffMs * books;
  final newTotal = newScanMs + newSniffMs * books;
  stdout.writeln('');
  stdout.writeln('=== 整库估算（$books 本）===');
  stdout.writeln('  旧: $oldTotal ms (${(oldTotal / 1000).toStringAsFixed(1)} 秒)');
  stdout.writeln('  新: $newTotal ms (${(newTotal / 1000).toStringAsFixed(1)} 秒)');
  if (newTotal > 0) {
    stdout.writeln('  总加速: ${(oldTotal / newTotal).toStringAsFixed(2)}x');
  }
  stdout.writeln('');
  stdout.writeln('注: 这是"每本书都完整嗅探一次"的模型。实际导入时');
  stdout.writeln('    新实现在整批导入中复用同一条连接，收益通常还更大。');
}

class _Entry {
  _Entry(this.url, this.name, this.isDirectory);
  final String url;
  final String name;
  final bool isDirectory;
}

List<String> _imagesOf(List<_Entry> entries) => entries
    .where((e) => !e.isDirectory)
    .map((e) => e.url)
    .where(_isImage)
    .toList();

bool _isImage(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  const exts = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.avif'};
  return exts.contains(path.substring(dot).toLowerCase());
}

/// PROPFIND Depth:1 —— **不发请求体**（飞牛 fnOS 拒绝带体，见 0.3.4 注释）
Future<List<_Entry>> _list(
  String url,
  String auth, {
  required http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final uri = Uri.parse(url.endsWith('/') ? url : '$url/');
    final req = http.Request('PROPFIND', uri)
      ..headers['Authorization'] = auth
      ..headers['Depth'] = '1';
    final streamed = await c.send(req);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode != 207) {
      throw http.ClientException('HTTP ${resp.statusCode}', uri);
    }
    final doc =
        XmlDocument.parse(utf8.decode(resp.bodyBytes, allowMalformed: true));
    final self = uri.toString();
    final out = <_Entry>[];
    for (final r in doc.descendants.whereType<XmlElement>()) {
      if (r.name.local != 'response') continue;
      XmlElement? hrefEl;
      for (final e in r.childElements) {
        if (e.name.local == 'href') {
          hrefEl = e;
          break;
        }
      }
      if (hrefEl == null) continue;
      final href = hrefEl.innerText.trim();
      if (href.isEmpty) continue;
      final abs = _resolve(uri, href);
      if (abs == self) continue;
      var isDir = false;
      for (final el in r.descendants.whereType<XmlElement>()) {
        if (el.name.local == 'collection') {
          isDir = true;
          break;
        }
      }
      final segs =
          Uri.parse(abs).pathSegments.where((s) => s.isNotEmpty).toList();
      out.add(_Entry(abs, segs.isEmpty ? abs : segs.last, isDir));
    }
    return out;
  } finally {
    if (client == null) c.close();
  }
}

String _resolve(Uri requestUri, String href) {
  final p = Uri.tryParse(href);
  if (p != null && p.hasScheme) return href;
  if (href.startsWith('/')) {
    return '${requestUri.scheme}://${requestUri.authority}$href';
  }
  return requestUri.resolve(href).toString();
}

Future<void> _rangeGet(String url, String auth, http.Client c) async {
  final req = http.Request('GET', Uri.parse(url))
    ..headers['Authorization'] = auth
    ..headers['Range'] = 'bytes=0-65535';
  final streamed = await c.send(req);
  await http.Response.fromStream(streamed);
}
