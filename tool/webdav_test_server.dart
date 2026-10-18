/// 一个**极简的 WebDAV 测试服务器**，用来在没有真 NAS 的情况下验证客户端。
///
/// 只实现本项目用到的两个方法：
///   · `PROPFIND`（Depth: 1）→ 207 Multi-Status + 目录列表
///   · `GET`（支持 Range）→ 文件内容
///
/// ## 用法
///
/// ```bash
/// dart run tool/webdav_test_server.dart <要共享的目录> [端口] [用户名] [密码]
///
/// # 例：把测试图片目录挂到 8099 端口，账号 reader / reader
/// dart run tool/webdav_test_server.dart C:\temp\comic 8099 reader reader
/// ```
///
/// 启动后：
///   · 宿主机访问 http://127.0.0.1:8099/dav
///   · Android **模拟器**里访问 http://10.0.2.2:8099/dav
///     （10.0.2.2 是模拟器指向宿主机的固定地址）
///   · 真机：把地址换成电脑在局域网里的 IP，并确认防火墙放行
///
/// 注意：这只是测试夹具，**没有做任何安全加固**，别拿去暴露在公网。
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      '用法: dart run tool/webdav_test_server.dart <目录> [端口] [用户名] [密码]',
    );
    exitCode = 64;
    return;
  }

  final root = Directory(args[0]).absolute;
  if (!root.existsSync()) {
    stderr.writeln('目录不存在: ${root.path}');
    exitCode = 66;
    return;
  }

  final port = args.length > 1 ? int.tryParse(args[1]) ?? 8099 : 8099;
  final user = args.length > 2 ? args[2] : null;
  final pass = args.length > 3 ? args[3] : null;

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('WebDAV 测试服务器已启动');
  stdout.writeln('  根目录 : ${root.path}');
  stdout.writeln('  地址   : http://127.0.0.1:$port/dav');
  stdout.writeln('  模拟器 : http://10.0.2.2:$port/dav');
  if (user != null) {
    stdout.writeln('  认证   : $user / ${'*' * (pass?.length ?? 0)}');
  } else {
    stdout.writeln('  认证   : 无（不需要账号）');
  }
  stdout.writeln('Ctrl+C 停止');

  await for (final req in server) {
    try {
      await _handle(req, root, user, pass);
    } catch (e) {
      stderr.writeln('处理 ${req.method} ${req.uri} 失败: $e');
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }
}

Future<void> _handle(
  HttpRequest req,
  Directory root,
  String? user,
  String? pass,
) async {
  // ── 认证 ──
  if (user != null) {
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    final expected = 'Basic ${base64Encode(utf8.encode('$user:${pass ?? ''}'))}';
    if (auth != expected) {
      req.response.statusCode = 401;
      req.response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Basic realm="inkscroll-test"',
      );
      await req.response.close();
      return;
    }
  }

  // ── 把 URL 路径映射到磁盘路径 ──
  final segments = req.uri.pathSegments.where((s) => s.isNotEmpty).toList();
  // 忽略最前面的 /dav 前缀
  final rel = segments.isNotEmpty && segments.first == 'dav'
      ? segments.sublist(1)
      : segments;

  final target = File('${root.path}${Platform.pathSeparator}${rel.join(Platform.pathSeparator)}');
  final targetDir = Directory(target.path);

  switch (req.method) {
    case 'PROPFIND':
      await _propfind(req, root, rel, target, targetDir);
      return;

    case 'GET':
      await _get(req, target);
      return;

    case 'HEAD':
      if (!target.existsSync()) {
        req.response.statusCode = 404;
      } else {
        req.response.contentLength = target.lengthSync();
      }
      await req.response.close();
      return;

    case 'OPTIONS':
      req.response.headers.set('DAV', '1, 2');
      req.response.headers.set(
        'Allow',
        'OPTIONS, GET, HEAD, PROPFIND',
      );
      await req.response.close();
      return;

    default:
      req.response.statusCode = 405;
      await req.response.close();
  }
}

// ---------------------------------------------------------------------------
// PROPFIND
// ---------------------------------------------------------------------------

Future<void> _propfind(
  HttpRequest req,
  Directory root,
  List<String> rel,
  File target,
  Directory targetDir,
) async {
  final depth = req.headers.value('Depth') ?? '1';
  final isDir = targetDir.existsSync();
  final isFile = target.existsSync();

  if (!isDir && !isFile) {
    req.response.statusCode = 404;
    await req.response.close();
    return;
  }

  final xml = StringBuffer()
    ..write('<?xml version="1.0" encoding="utf-8"?>\n')
    ..write('<D:multistatus xmlns:D="DAV:">');

  final selfPath = '/dav/${rel.join('/')}${rel.isEmpty ? '' : '/'}';
  if (isFile) {
    _writeResponse(
      xml,
      href: '/dav/${rel.join('/')}',
      name: rel.isEmpty ? 'dav' : rel.last,
      isDir: false,
      size: target.lengthSync(),
      modified: target.lastModifiedSync(),
    );
  } else {
    _writeResponse(
      xml,
      href: selfPath,
      name: rel.isEmpty ? 'dav' : rel.last,
      isDir: true,
      modified: targetDir.statSync().modified,
    );

    if (depth != '0') {
      final children = targetDir.listSync()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        final name = child.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        if (name.startsWith('.')) continue; // 跳过隐藏文件
        final childRel = [...rel, name];
        final stat = child.statSync();
        _writeResponse(
          xml,
          href: '/dav/${childRel.map(Uri.encodeComponent).join('/')}'
              '${stat.type == FileSystemEntityType.directory ? '/' : ''}',
          name: name,
          isDir: stat.type == FileSystemEntityType.directory,
          size: stat.type == FileSystemEntityType.file ? stat.size : null,
          modified: stat.modified,
        );
      }
    }
  }

  xml.write('</D:multistatus>');

  req.response.statusCode = 207;
  req.response.headers.contentType =
      ContentType('application', 'xml', charset: 'utf-8');
  req.response.add(utf8.encode(xml.toString()));
  await req.response.close();
}

void _writeResponse(
  StringBuffer xml, {
  required String href,
  required String name,
  required bool isDir,
  int? size,
  DateTime? modified,
}) {
  xml
    ..write('<D:response>')
    ..write('<D:href>${_xmlEscape(href)}</D:href>')
    ..write('<D:propstat><D:prop>')
    ..write('<D:displayname>${_xmlEscape(name)}</D:displayname>')
    ..write('<D:resourcetype>${isDir ? '<D:collection/>' : ''}</D:resourcetype>');
  if (size != null) {
    xml.write('<D:getcontentlength>$size</D:getcontentlength>');
  }
  if (modified != null) {
    xml.write('<D:getlastmodified>'
        '${HttpDate.format(modified.toUtc())}'
        '</D:getlastmodified>');
  }
  xml
    ..write('</D:prop>')
    ..write('<D:status>HTTP/1.1 200 OK</D:status>')
    ..write('</D:propstat>')
    ..write('</D:response>');
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

// ---------------------------------------------------------------------------
// GET（支持 Range）
// ---------------------------------------------------------------------------

Future<void> _get(HttpRequest req, File target) async {
  if (!target.existsSync()) {
    req.response.statusCode = 404;
    await req.response.close();
    return;
  }

  final total = target.lengthSync();
  final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);

  if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
    final spec = rangeHeader.substring('bytes='.length);
    final parts = spec.split('-');
    final start = int.tryParse(parts[0]) ?? 0;
    final end = parts.length > 1 && parts[1].isNotEmpty
        ? int.tryParse(parts[1]) ?? (total - 1)
        : total - 1;
    final safeEnd = end.clamp(start, total - 1);

    if (start > safeEnd || start >= total) {
      req.response.statusCode = 416;
      req.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$total',
      );
      await req.response.close();
      return;
    }

    req.response.statusCode = 206;
    req.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$safeEnd/$total',
    );
    req.response.contentLength = safeEnd - start + 1;
    await req.response.addStream(
      target.openRead(start, safeEnd + 1),
    );
    await req.response.close();
    return;
  }

  req.response.statusCode = 200;
  req.response.contentLength = total;
  req.response.headers.contentType =
      ContentType('application', 'octet-stream');
  await req.response.addStream(target.openRead());
  await req.response.close();
}
