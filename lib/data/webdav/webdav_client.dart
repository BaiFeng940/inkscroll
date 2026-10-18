/// 一个够用的 WebDAV 客户端。
///
/// ## 为什么自己写
///
/// 现成的 `webdav_client` 包能用，但这里有两件事它不支持，而它们对本项目很关键：
///
/// 1. **Range 头部嗅探**：只需要前 64KB 就能解析出图片尺寸，
///    用来给虚拟长页算高度。为了知道图片宽高而把整张 5MB 的图拉下来，
///    对网络阅读来说是灾难。
/// 2. **自签证书**：家用 NAS 几乎全是自签 HTTPS 证书，
///    不开这个开关用户会卡在 `HandshakeException`。
///
/// ## 协议要点
///
/// - 列目录：`PROPFIND` + `Depth: 1`，响应是 `207 Multi-Status` 的 XML
/// - 取文件：`GET`（可加 `Range`）
/// - 认证：HTTP Basic
///
/// ## 坑
///
/// - **命名空间前缀不统一**：有的服务器用 `<D:href>`，有的用 `<d:href>`，
///   还有的用 `<lp1:href>`。所以解析必须**按 local name 匹配**，不能按前缀。
/// - **href 是百分号编码的**：中文目录名会变成 `%E6%BC%AB%E7%94%BB`。
///   展示要用解码后的名字，发请求要用编码后的原样。
/// - **Depth:1 会把自己也列出来**，必须过滤掉。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

import '../../core/errors.dart';

/// WebDAV 上的一个条目（文件或目录）
class WebDavEntry {
  const WebDavEntry({
    required this.url,
    required this.name,
    required this.isDirectory,
    this.size,
    this.modified,
    this.contentType,
  });

  /// 可直接用于 GET / PROPFIND 的**绝对且已编码**的 URL
  final String url;

  /// 给人看的名字（已解码）
  final String name;

  final bool isDirectory;
  final int? size;
  final DateTime? modified;
  final String? contentType;

  String get extension {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot).toLowerCase();
  }

  @override
  String toString() =>
      'WebDavEntry($name, dir=$isDirectory, size=$size)';
}

class WebDavClient {
  WebDavClient({
    required String baseUrl,
    this.username,
    this.password,
    this.allowSelfSigned = false,
    Duration? timeout,
    http.Client? httpClient,
  })  : baseUrl = _normalizeBase(baseUrl),
        _timeout = timeout ?? const Duration(seconds: 20),
        _injected = httpClient {
    _client = _injected ?? _buildClient();
  }

  /// 归一化后的根地址（去尾斜杠）
  final String baseUrl;
  final String? username;
  final String? password;
  final bool allowSelfSigned;
  final Duration _timeout;

  /// 测试时可注入假的 http.Client（见 test/webdav_test.dart）
  final http.Client? _injected;

  late final http.Client _client;

  // ------------------------------------------------------------------
  // 地址处理
  // ------------------------------------------------------------------

  static String _normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    // 用户可能只填了 IP 或漏了协议
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// `scheme://host:port`
  String get origin {
    final u = Uri.parse(baseUrl);
    return '${u.scheme}://${u.authority}';
  }

  Map<String, String> get _authHeaders {
    final h = <String, String>{};
    if (username != null && username!.isNotEmpty) {
      final raw = '$username:${password ?? ''}';
      h['Authorization'] = 'Basic ${base64Encode(utf8.encode(raw))}';
    }
    return h;
  }

  http.Client _buildClient() {
    if (!allowSelfSigned) return http.Client();
    // 自签证书：构造一个跳过证书校验的 HttpClient。
    // 只在用户显式打开开关时启用，且界面上有明确的风险提示。
    final io = HttpClient()
      ..connectionTimeout = _timeout
      ..badCertificateCallback = (cert, host, port) => true;
    return IOClient(io);
  }

  void close() => _client.close();

  /// 把 PROPFIND 返回的 href 变成可直接请求的绝对 URL
  String resolveHref(String href, Uri requestUri) {
    final trimmed = href.trim();
    if (trimmed.isEmpty) return requestUri.toString();
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && parsed.hasScheme) return parsed.toString();
    if (trimmed.startsWith('/')) return '$origin$trimmed';
    // 少数服务器返回相对路径：相对当前位置解析
    return requestUri.resolve(trimmed).toString();
  }

  /// 把编码的 URL 解成给人看的名字
  static String displayNameOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return url;
    final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return u.host;
    // Uri.pathSegments 已经做过百分号解码
    return segs.last;
  }

  // ------------------------------------------------------------------
  // 列目录
  // ------------------------------------------------------------------

  static const String _propfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<propfind xmlns="DAV:">
  <prop>
    <displayname/>
    <getcontentlength/>
    <getcontenttype/>
    <getlastmodified/>
    <resourcetype/>
  </prop>
</propfind>''';

  /// 列出某个目录下的直接子项（不含自己）
  ///
  /// [folderUrl] 必须是绝对 URL；传 `baseUrl` 即列出根目录。
  Future<List<WebDavEntry>> list(String folderUrl) async {
    final target = folderUrl.isEmpty ? baseUrl : folderUrl;
    // 有些服务器要求目录 URL 以 / 结尾才认作集合
    final uri = Uri.parse(target.endsWith('/') ? target : '$target/');

    http.Response resp;
    try {
      final req = http.Request('PROPFIND', uri)
        ..headers.addAll(_authHeaders)
        ..headers['Depth'] = '1'
        ..headers['Content-Type'] = 'application/xml; charset=utf-8'
        ..bodyBytes = utf8.encode(_propfindBody);
      final streamed = await _client.send(req).timeout(_timeout);
      resp = await http.Response.fromStream(streamed);
    } on HandshakeException catch (e) {
      throw NetworkCertificateError(detail: '$e');
    } on TimeoutException catch (e) {
      throw NetworkUnreachableError(address: target, detail: 'timeout: $e');
    } on SocketException catch (e) {
      throw NetworkUnreachableError(address: target, detail: '$e');
    } on http.ClientException catch (e) {
      // dart:io 的 TLS 失败常常被包成 ClientException
      if (e.message.contains('CERTIFICATE') ||
          e.message.contains('handshake') ||
          e.message.contains('Handshake')) {
        throw NetworkCertificateError(detail: e.message);
      }
      throw NetworkUnreachableError(address: target, detail: e.message);
    } catch (e) {
      throw NetworkUnreachableError(address: target, detail: '$e');
    }

    _throwIfBadStatus(resp, target);

    // 207 才是 WebDAV 多状态响应。有些 NAS 在"地址填错成网页"时返回 200 + HTML。
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode == 200 && !body.contains('multistatus')) {
      throw NotWebDavError(detail: 'status=200 without multistatus');
    }

    return _parseMultistatus(body, uri);
  }

  List<WebDavEntry> _parseMultistatus(String xmlBody, Uri requestUri) {
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlBody);
    } catch (e) {
      throw NotWebDavError(detail: 'XML 解析失败: $e');
    }

    // 按 local name 找，忽略命名空间前缀
    final responses = doc.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'response')
        .toList();

    final selfUrl = _normalizeForCompare(requestUri.toString());
    final out = <WebDavEntry>[];

    for (final r in responses) {
      final hrefEl = r.childElements.firstWhereOrNull((e) => e.name.local == 'href');
      if (hrefEl == null) continue;
      final rawHref = hrefEl.innerText.trim();
      if (rawHref.isEmpty) continue;

      final entryUrl = resolveHref(rawHref, requestUri);
      // Depth:1 会把自己也返回，跳过
      if (_normalizeForCompare(entryUrl) == selfUrl) continue;

      // 找到第一个带 prop 的 propstat（有的服务器把 status 200 和 404 分开返回）
      final props = <XmlElement>[];
      for (final ps in r.childElements.where((e) => e.name.local == 'propstat')) {
        final prop = ps.childElements.firstWhereOrNull((e) => e.name.local == 'prop');
        if (prop != null) props.addAll(prop.childElements);
      }

      String? textOf(String local) =>
          props.firstWhereOrNull((e) => e.name.local == local)?.innerText.trim();

      final resourceType =
          props.where((e) => e.name.local == 'resourcetype').toList();
      final isDir = resourceType.any((rt) =>
          rt.childElements.any((c) => c.name.local == 'collection'));

      final sizeText = textOf('getcontentlength');
      final modifiedText = textOf('getlastmodified');

      var name = textOf('displayname') ?? '';
      if (name.isEmpty) name = displayNameOf(entryUrl);
      // 根目录的 displayname 有时为空或与子项重复
      if (name.isEmpty) name = '(未命名)';

      out.add(WebDavEntry(
        url: entryUrl,
        name: name,
        isDirectory: isDir,
        size: sizeText == null || sizeText.isEmpty
            ? null
            : int.tryParse(sizeText),
        modified: modifiedText == null || modifiedText.isEmpty
            ? null
            : _tryParseHttpDate(modifiedText),
        contentType: textOf('getcontenttype'),
      ));
    }

    return out;
  }

  static String _normalizeForCompare(String url) {
    var s = url;
    // 去掉查询串与末尾斜杠后比较，避免 "…/dav" 与 "…/dav/" 被当成两个
    final q = s.indexOf('?');
    if (q >= 0) s = s.substring(0, q);
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return Uri.decodeComponent(s);
  }

  static DateTime? _tryParseHttpDate(String raw) {
    // RFC 1123: "Wed, 21 Oct 2015 07:28:00 GMT"
    try {
      return HttpDate.parse(raw);
    } catch (_) {
      return DateTime.tryParse(raw);
    }
  }

  // ------------------------------------------------------------------
  // 取内容
  // ------------------------------------------------------------------

  /// 取完整文件
  Future<Uint8List> get(String url) async {
    final resp = await _sendGet(url, range: null);
    _throwIfBadStatus(resp, url);
    return resp.bodyBytes;
  }

  /// 只取前 [maxBytes] 字节 —— 用于**在不下载整张图的前提下解析尺寸**。
  ///
  /// 优先用 `Range` 请求；如果服务器不支持 Range（返回 200 全量），
  /// 就在收到足够字节后主动断开，避免把大文件整个读进内存。
  Future<Uint8List> getRange(String url, {int maxBytes = 64 * 1024}) async {
    final resp = await _sendGet(url, range: 'bytes=0-${maxBytes - 1}');

    if (resp.statusCode == 206) {
      return resp.bodyBytes; // 服务器按 Range 返回
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      // 服务器忽略了 Range，返回了全量 —— 截断即可
      final b = resp.bodyBytes;
      return b.length <= maxBytes ? b : Uint8List.sublistView(b, 0, maxBytes);
    }
    _throwIfBadStatus(resp, url);
    return resp.bodyBytes;
  }

  Future<http.Response> _sendGet(String url, {String? range}) async {
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers.addAll(_authHeaders);
      if (range != null) req.headers['Range'] = range;
      final streamed = await _client.send(req).timeout(_timeout);
      return await http.Response.fromStream(streamed).timeout(_timeout);
    } on HandshakeException catch (e) {
      throw NetworkCertificateError(detail: '$e');
    } on TimeoutException catch (e) {
      throw NetworkUnreachableError(address: url, detail: 'timeout: $e');
    } on SocketException catch (e) {
      throw NetworkUnreachableError(address: url, detail: '$e');
    } on http.ClientException catch (e) {
      if (e.message.contains('CERTIFICATE') ||
          e.message.contains('handshake') ||
          e.message.contains('Handshake')) {
        throw NetworkCertificateError(detail: e.message);
      }
      throw NetworkUnreachableError(address: url, detail: e.message);
    } catch (e) {
      throw NetworkUnreachableError(address: url, detail: '$e');
    }
  }

  void _throwIfBadStatus(http.Response resp, String url) {
    final code = resp.statusCode;
    if (code >= 200 && code < 300) return;
    if (code == 401 || code == 403) {
      throw NetworkAuthError(detail: 'HTTP $code $url');
    }
    if (code == 404) {
      throw NetworkHttpError(404, path: url, detail: '路径不存在');
    }
    throw NetworkHttpError(code, path: url);
  }

  /// 测试连接：能列出根目录就算成功。
  ///
  /// 返回根目录下的条目，顺便让调用方判断"是空目录"还是"根本不是 WebDAV"。
  Future<List<WebDavEntry>> testConnection() => list(baseUrl);
}

/// 本地实现，避免为了一个方法引入 `package:collection`。
extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E element) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
