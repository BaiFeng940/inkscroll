/// 网盘 Range/重定向行为探测工具。
///
/// ## 为什么需要它
///
/// 商用网盘的 WebDAV 经常不是"直接返回文件内容"，而是：
///   `GET` → `302` 跳到 CDN 签名地址 → CDN 返回内容
///
/// 我们要靠 Range 只读压缩包的目录和单个条目（不解压整包），所以必须确认：
///   1. Dart 的 http 客户端会不会**自动跟随**这个 302
///   2. 跟随之后 **Range 头还在不在**（不在的话每次都会拉到整个文件）
///   3. 返回的是不是 `206` 且字节数正确
///
/// 这三点任何一条不成立，"网盘压缩包在线读"就做不成。所以先用真机数据验。
///
/// ## 用法
///
/// ```bash
/// dart run tool/probe_range_redirect.dart <文件完整URL> <用户名> <密码> [探测字节数]
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      '用法: dart run tool/probe_range_redirect.dart <文件URL> <用户名> <密码> [字节数]',
    );
    exitCode = 64;
    return;
  }
  final fileUrl = args[0];
  final auth = 'Basic ${base64Encode(utf8.encode('${args[1]}:${args[2]}'))}';
  final n = args.length > 3 ? int.tryParse(args[3]) ?? 1024 : 1024;

  final parent = fileUrl.substring(0, fileUrl.lastIndexOf('/'));
  final client = http.Client();
  try {
    // ── 1. 用 PROPFIND 拿文件大小 ──
    final propReq = http.Request('PROPFIND', Uri.parse('$parent/'))
      ..headers['Authorization'] = auth
      ..headers['Depth'] = '0';
    final propResp = await http.Response.fromStream(await client.send(propReq));
    stdout.writeln('PROPFIND 父目录: HTTP ${propResp.statusCode}');

    // 直接对文件本身 PROPFIND（Depth 0）
    final fileReq = http.Request('PROPFIND', Uri.parse(fileUrl))
      ..headers['Authorization'] = auth
      ..headers['Depth'] = '0';
    final fileResp = await http.Response.fromStream(await client.send(fileReq));
    stdout.writeln('PROPFIND 文件  : HTTP ${fileResp.statusCode}');
    final lenMatch =
        RegExp(r'<[^>]*getcontentlength[^>]*>(\d+)<').firstMatch(
      utf8.decode(fileResp.bodyBytes, allowMalformed: true),
    );
    final size = lenMatch == null ? null : int.tryParse(lenMatch.group(1)!);
    stdout.writeln('文件大小       : ${size ?? "未知"}');
    if (size == null || size < n) {
      stderr.writeln('文件太小或拿不到大小，无法探测');
      exitCode = 65;
      return;
    }

    // ── 2. 跟随重定向 + Range（取文件尾部 n 字节）──
    final start = size - n;
    final resp = await _get(client, fileUrl, auth, 'bytes=$start-${size - 1}');
    stdout.writeln('');
    stdout.writeln('=== Range 请求（尾部 $n 字节）===');
    stdout.writeln('  HTTP        : ${resp.statusCode}');
    stdout.writeln('  实际字节数  : ${resp.bodyBytes.length}');
    stdout.writeln('  命中 206    : ${resp.statusCode == 206}');
    stdout.writeln('  字节数正确  : ${resp.bodyBytes.length == n}');

    // ── 3. ZIP EOCD 检查 ──
    final tail = resp.bodyBytes;
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4B &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    stdout.writeln('');
    stdout.writeln('=== ZIP 结构 ===');
    if (eocd < 0) {
      stdout.writeln('  未找到 EOCD（可能不是 zip，或需要更大的尾部窗口）');
    } else {
      stdout.writeln('  EOCD 偏移   : 距文件尾 ${tail.length - eocd} 字节');
      final entries = _u16(tail, eocd + 10);
      final cdSize = _u32(tail, eocd + 12);
      final cdOffset = _u32(tail, eocd + 16);
      stdout.writeln('  条目数      : $entries');
      stdout.writeln('  中央目录    : offset=$cdOffset size=$cdSize');

      // ── 4. Range 读中央目录，列出条目 ──
      final cdResp =
          await _get(client, fileUrl, auth, 'bytes=$cdOffset-${cdOffset + cdSize - 1}');
      stdout.writeln('');
      stdout.writeln('=== 读中央目录：HTTP ${cdResp.statusCode}，'
          '${cdResp.bodyBytes.length}/$cdSize 字节 ===');
      String? firstName;
      var firstCompSize = 0;
      var firstCompMethod = 0;
      var firstLocalOffset = 0;
      var firstUncompSize = 0;
      final cd = cdResp.bodyBytes;
      var p = 0;
      var shown = 0;
      while (p + 46 <= cd.length) {
        if (_u32(cd, p) != 0x02014b50) break;
        final method = _u16(cd, p + 10);
        final compSize = _u32(cd, p + 20);
        final uncompSize = _u32(cd, p + 24);
        final nameLen = _u16(cd, p + 28);
        final extraLen = _u16(cd, p + 30);
        final commentLen = _u16(cd, p + 32);
        final localOff = _u32(cd, p + 42);
        final name = utf8.decode(
          Uint8List.sublistView(cd, p + 46, p + 46 + nameLen),
          allowMalformed: true,
        );
        if (shown < 8) {
          stdout.writeln('  · $name  (method=$method, '
              'comp=$compSize, uncomp=$uncompSize, localOffset=$localOff)');
          shown++;
        }
        if (firstName == null) {
          firstName = name;
          firstCompSize = compSize;
          firstCompMethod = method;
          firstLocalOffset = localOff;
          firstUncompSize = uncompSize;
        }
        p += 46 + nameLen + extraLen + commentLen;
      }

      // ── 5. Range 读单个条目的数据，验证真实可读 ──
      if (firstName != null) {
        stdout.writeln('');
        stdout.writeln('=== 读第一个条目数据 ===');
        stdout.writeln('  条目: $firstName');
        final headResp = await _get(
          client, fileUrl, auth,
          'bytes=$firstLocalOffset-${firstLocalOffset + 29}',
        );
        if (headResp.statusCode == 206 && headResp.bodyBytes.length >= 30) {
          final lh = headResp.bodyBytes;
          final nameLen = _u16(lh, 26);
          final extraLen = _u16(lh, 28);
          final dataStart = firstLocalOffset + 30 + nameLen + extraLen;
          stdout.writeln('  本地头: nameLen=$nameLen extraLen=$extraLen '
              '数据起点=$dataStart');
          final dataResp = await _get(
            client, fileUrl, auth,
            'bytes=$dataStart-${dataStart + firstCompSize - 1}',
          );
          stdout.writeln('  拉取压缩数据: HTTP ${dataResp.statusCode}，'
              '${dataResp.bodyBytes.length}/$firstCompSize 字节');
          if (dataResp.statusCode == 206) {
            stdout.writeln('  ✅ 可以用 Range 拿到单个条目的压缩数据');
            stdout.writeln('     method=$firstCompMethod '
                '(0=STORED 可直接用, 8=DEFLATE 需解压)，'
                '解压后 $firstUncompSize 字节');
          }
        }
      }
    }
  } finally {
    client.close();
  }
}

/// 发 GET；`http.Client` 默认跟随重定向，但要确认 Range 头还在
Future<http.Response> _get(
  http.Client client,
  String url,
  String auth,
  String range,
) async {
  final req = http.Request('GET', Uri.parse(url))
    ..headers['Authorization'] = auth
    ..headers['Range'] = range;
  final resp = await http.Response.fromStream(await client.send(req));
  return resp;
}

int _u16(List<int> b, int i) => b[i] | (b[i + 1] << 8);
int _u32(List<int> b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
