/// 一次性排查脚本：探测 NAS 上 WebDAV 的真实入口。
///
/// 用 `dart run tool/dav_scan.dart <host:port> [用户名] [密码]`。
/// 会依次尝试常见 WebDAV 路径，打印状态码与 WWW-Authenticate 头，
/// 用来区分「路径不对」和「账号不对」。
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/dav_scan.dart <host:port> [用户] [密码]');
    exitCode = 64;
    return;
  }
  final hostPort = args[0];
  final user = args.length > 1 ? args[1] : null;
  final pass = args.length > 2 ? args[2] : null;

  final paths = [
    '/',
    '/dav',
    '/dav/',
    '/webdav',
    '/webdav/',
    '/remote.php/webdav',
    '/dav/files',
  ];

  const body =
      '<?xml version="1.0" encoding="utf-8"?><propfind xmlns="DAV:"><prop><displayname/><resourcetype/></prop></propfind>';

  for (final scheme in ['https', 'http']) {
    stdout.writeln('\n════ $scheme://$hostPort ════');
    for (final p in paths) {
      final uri = Uri.parse('$scheme://$hostPort$p');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8)
        ..badCertificateCallback = (cert, host, port) => true;

      try {
        final req = await client.openUrl('PROPFIND', uri);
        req.headers.set('Depth', '0');
        req.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
        if (user != null) {
          final raw = '$user:${pass ?? ''}';
          req.headers.set('Authorization',
              'Basic ${base64Encode(utf8.encode(raw))}');
        }
        req.add(utf8.encode(body));
        final resp = await req.close().timeout(const Duration(seconds: 10));
        final text = await resp.transform(utf8.decoder).join();
        final auth = resp.headers.value('www-authenticate') ?? '';
        final dav = resp.headers.value('dav') ?? '';
        stdout.writeln('  PROPFIND $p → ${resp.statusCode}'
            '${dav.isNotEmpty ? '  DAV:$dav' : ''}'
            '${auth.isNotEmpty ? '  auth:$auth' : ''}');
        if (text.contains('multistatus')) {
          stdout.writeln('     ✓ 是 WebDAV（返回 multistatus）');
        } else if (text.isNotEmpty) {
          final t = text.replaceAll(RegExp(r'\s+'), ' ');
          stdout.writeln('     body: ${t.length > 120 ? t.substring(0, 120) : t}');
        }
      } catch (e) {
        var msg = e.toString().split('\n').first;
        if (msg.length > 100) msg = msg.substring(0, 100);
        stdout.writeln('  PROPFIND $p → 异常: $msg');
      } finally {
        client.close(force: true);
      }
    }
  }
}
