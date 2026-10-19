/// WebDAV 客户端与连接存储的单元测试。
///
/// ## 为什么这些测试很重要
///
/// WebDAV 的坑几乎全在**解析**上，而不是网络：
///   · 命名空间前缀五花八门（`D:` / `d:` / `lp1:`）
///   · href 是百分号编码的（中文目录名）
///   · `Depth:1` 会把自己也列出来
///   · 有些 NAS 对错误地址返回 `200 + HTML` 而不是 404
///
/// 这些都能用假的 `http.Client` 覆盖，不需要真的 NAS。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:inkscroll/core/errors.dart';
import 'package:inkscroll/data/prefs_store.dart';
import 'package:inkscroll/data/webdav/webdav_client.dart';
import 'package:inkscroll/data/models/book_meta.dart';
import 'package:inkscroll/data/webdav/webdav_connection.dart';

/// 造一个多状态响应
String multistatus(String body) =>
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<D:multistatus xmlns:D="DAV:">$body</D:multistatus>';

String responseEntry({
  required String href,
  String? displayName,
  bool isDir = false,
  int? size,
  String prefix = 'D',
}) {
  final props = StringBuffer();
  if (displayName != null) {
    props.write('<$prefix:displayname>$displayName</$prefix:displayname>');
  }
  if (size != null) {
    props.write('<$prefix:getcontentlength>$size</$prefix:getcontentlength>');
  }
  props.write(isDir
      ? '<$prefix:resourcetype><$prefix:collection/></$prefix:resourcetype>'
      : '<$prefix:resourcetype/>');
  return '<$prefix:response>'
      '<$prefix:href>$href</$prefix:href>'
      '<$prefix:propstat>'
      '<$prefix:prop>$props</$prefix:prop>'
      '<$prefix:status>HTTP/1.1 200 OK</$prefix:status>'
      '</$prefix:propstat>'
      '</$prefix:response>';
}

/// 一个只会返回固定 XML 的假客户端
http.Client fakeClientReturning(String xml, {int status = 207}) {
  return MockClient((request) async {
    return http.Response(
      xml,
      status,
      headers: {'content-type': 'application/xml; charset=utf-8'},
    );
  });
}

void main() {
  group('WebDavClient · 地址归一化', () {
    test('缺协议时默认补 https://（NAS 普遍开 HTTPS）', () {
      // 以前的默认是 http://，碰到只开 HTTPS 的 NAS（飞牛 5006）
      // 会被服务器直接掐断，用户看到"连接不上服务器"——完全误导。
      final c = WebDavClient(baseUrl: '192.168.1.10:5006');
      expect(c.baseUrl, 'https://192.168.1.10:5006');
    });

    test('显式 http:// 保持不变（不会被强行改成 https）', () {
      final c = WebDavClient(baseUrl: 'http://192.168.1.10:5005/dav');
      expect(c.baseUrl, 'http://192.168.1.10:5005/dav');
    });

    test('resolveBaseUrl 对只开 HTTPS 的服务器会探测到 https', () async {
      // 模拟：https 能拿到 401（服务器有响应），http 直接断开
      final probe = await WebDavClient.resolveBaseUrl(
        input: 'nas.local:5006',
        httpClient: MockClient((req) async {
          if (req.url.scheme == 'https') {
            return http.Response('denied', 401);
          }
          throw http.ClientException('Connection closed before full header');
        }),
      );
      expect(probe.baseUrl, 'https://nas.local:5006');
      expect(probe.switched, isFalse); // https 就是首选，不算"切换"
    });

    test('https 不通时会退到 http', () async {
      final probe = await WebDavClient.resolveBaseUrl(
        input: 'https://nas.local:5005/dav',
        httpClient: MockClient((req) async {
          if (req.url.scheme == 'http') {
            return http.Response(
              '<?xml version="1.0"?><multistatus xmlns="DAV:"/>',
              207,
            );
          }
          throw http.ClientException('Connection closed');
        }),
      );
      expect(probe.baseUrl, 'http://nas.local:5005/dav');
      expect(probe.switched, isTrue);
    });

    test('去掉末尾斜杠', () {
      final c = WebDavClient(baseUrl: 'http://nas.local:5005/dav///');
      expect(c.baseUrl, 'http://nas.local:5005/dav');
    });

    test('保留 https', () {
      final c = WebDavClient(baseUrl: 'https://nas.local/dav/');
      expect(c.baseUrl, 'https://nas.local/dav');
    });

    test('origin 只保留 scheme+authority', () {
      final c = WebDavClient(baseUrl: 'http://192.168.1.10:5005/dav/sub');
      expect(c.origin, 'http://192.168.1.10:5005');
    });
  });

  group('WebDavClient · href 解析', () {
    test('绝对路径拼上 origin', () {
      final c = WebDavClient(baseUrl: 'http://nas:5005/dav');
      expect(
        c.resolveHref('/dav/comic/001.jpg', Uri.parse('http://nas:5005/dav/')),
        'http://nas:5005/dav/comic/001.jpg',
      );
    });

    test('已经是绝对 URL 时原样返回', () {
      final c = WebDavClient(baseUrl: 'http://nas:5005/dav');
      expect(
        c.resolveHref('https://other/dav/x.jpg', Uri.parse('http://nas:5005/dav/')),
        'https://other/dav/x.jpg',
      );
    });

    test('中文目录名解码正确', () {
      const url = 'http://nas:5005/dav/%E6%BC%AB%E7%94%BB/001.jpg';
      expect(WebDavClient.displayNameOf(url), '001.jpg');
    });

    test('未编码的中文 href 会被归一化成合法 URL', () {
      // 现实里有些简易 WebDAV 服务器直接回未编码的路径。
      // 以前这里会拼出含空格的非法 URL，导致子目录内容全读不到（且无提示）。
      final c = WebDavClient(baseUrl: 'http://nas:5005/dav');
      final got = c.resolveHref(
        '/dav/第01话 火影/001.jpg',
        Uri.parse('http://nas:5005/dav/'),
      );
      expect(got, contains('%E7%AC%AC01%E8%AF%9D'));
      expect(got, contains('%20')); // 空格必须被编码
      expect(got, isNot(contains(' ')));
      expect(Uri.parse(got).pathSegments.last, '001.jpg');
    });

    test('已编码的 href 不会被二次编码', () {
      final c = WebDavClient(baseUrl: 'http://nas:5005/dav');
      final got = c.resolveHref(
        '/dav/%E6%BC%AB%E7%94%BB/001.jpg',
        Uri.parse('http://nas:5005/dav/'),
      );
      expect(got, 'http://nas:5005/dav/%E6%BC%AB%E7%94%BB/001.jpg');
      expect(got, isNot(contains('%25'))); // 二次编码的标志
    });
  });

  group('WebDavClient · 多状态解析', () {
    test('解析出目录与文件，并过滤掉自己', () async {
      final xml = multistatus(
        responseEntry(href: '/dav/', isDir: true, displayName: 'dav') +
            responseEntry(href: '/dav/%E6%BC%AB%E7%94%BB/', isDir: true, displayName: '漫画') +
            responseEntry(href: '/dav/%E6%BC%AB%E7%94%BB/001.jpg', displayName: '001.jpg', size: 60047) +
            responseEntry(href: '/dav/%E6%BC%AB%E7%94%BB/002.jpg', displayName: '002.jpg', size: 58590),
      );

      final client = WebDavClient(
        baseUrl: 'http://nas:5005/dav',
        httpClient: fakeClientReturning(xml),
      );
      final entries = await client.list('http://nas:5005/dav');

      // 自己（/dav/）被过滤，剩 3 项
      expect(entries.length, 3);

      final dir = entries.firstWhere((e) => e.name == '漫画');
      expect(dir.isDirectory, isTrue);
      expect(dir.url, 'http://nas:5005/dav/%E6%BC%AB%E7%94%BB/');

      final f1 = entries.firstWhere((e) => e.name == '001.jpg');
      expect(f1.isDirectory, isFalse);
      expect(f1.size, 60047);
      expect(f1.extension, '.jpg');
    });

    test('支持小写 d: 前缀', () async {
      final xml = '<?xml version="1.0"?>'
          '<d:multistatus xmlns:d="DAV:">'
          '${responseEntry(href: '/dav/a.jpg', displayName: 'a.jpg', size: 10, prefix: 'd')}'
          '</d:multistatus>';
      final client = WebDavClient(
        baseUrl: 'http://nas/dav',
        httpClient: fakeClientReturning(xml),
      );
      final entries = await client.list('http://nas/dav');
      expect(entries.single.name, 'a.jpg');
    });

    test('支持 lp1: 这类自定义前缀', () async {
      final xml = '<?xml version="1.0"?>'
          '<lp1:multistatus xmlns:lp1="DAV:">'
          '${responseEntry(href: '/dav/b.jpg', displayName: 'b.jpg', prefix: 'lp1')}'
          '</lp1:multistatus>';
      final client = WebDavClient(
        baseUrl: 'http://nas/dav',
        httpClient: fakeClientReturning(xml),
      );
      final entries = await client.list('http://nas/dav');
      expect(entries.single.name, 'b.jpg');
    });

    test('没有 displayname 时从 href 取名字', () async {
      final xml = multistatus(
        responseEntry(href: '/dav/%E7%AC%AC01%E8%AF%9D.jpg', size: 1),
      );
      final client = WebDavClient(
        baseUrl: 'http://nas/dav',
        httpClient: fakeClientReturning(xml),
      );
      final entries = await client.list('http://nas/dav');
      expect(entries.single.name, '第01话.jpg');
    });
  });

  group('WebDavClient · 错误映射', () {
    test('401 → NetworkAuthError', () async {
      final client = WebDavClient(
        baseUrl: 'http://nas/dav',
        httpClient: MockClient((_) async => http.Response('denied', 401)),
      );
      expect(
        () => client.list('http://nas/dav'),
        throwsA(isA<NetworkAuthError>()),
      );
    });

    test('404 → NetworkHttpError(404)', () async {
      final client = WebDavClient(
        baseUrl: 'http://nas/dav',
        httpClient: MockClient((_) async => http.Response('nope', 404)),
      );
      expect(
        () => client.list('http://nas/dav'),
        throwsA(isA<NetworkHttpError>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('200 + HTML（地址填成了网页）→ NotWebDavError', () async {
      final client = WebDavClient(
        baseUrl: 'http://nas',
        // 注意：http.Response(String) 在没有 charset 时按 Latin-1 编码，
        // 中文会直接抛 "Contains invalid characters"。用字节构造才正确。
        httpClient: MockClient((_) async => http.Response.bytes(
              utf8.encode('<html><body>飞牛 NAS 管理页面</body></html>'),
              200,
            )),
      );
      expect(
        () => client.list('http://nas'),
        throwsA(isA<NotWebDavError>()),
      );
    });
  });

  group('WebDavClient · PROPFIND 请求体兼容性', () {
    // 飞牛 fnOS 的 WebDAV **拒绝任何带 XML 体的 PROPFIND**，一律 400。
    // 而 RFC 4918 §9.1 规定空体等价于 allprop —— 所以空体才是最大兼容写法。
    // 这个坑很隐蔽：400 看起来像"请求格式错"，极易被误判成地址/权限问题。
    const multi = '<?xml version="1.0" encoding="UTF-8"?>'
        '<D:multistatus xmlns:D="DAV:">'
        '<D:response><D:href>/dav/</D:href><D:propstat><D:prop>'
        '<D:resourcetype><D:collection/></D:resourcetype>'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
        '<D:response><D:href>/dav/a.jpg</D:href><D:propstat><D:prop>'
        '<D:getcontentlength>123</D:getcontentlength>'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
        '</D:multistatus>';

    test('默认发空体 PROPFIND（不发 XML）', () async {
      final bodies = <String>[];
      final client = WebDavClient(
        baseUrl: 'http://nas/dav',
        httpClient: MockClient((req) async {
          expect(req.method, 'PROPFIND');
          expect(req.headers['Depth'], '1');
          bodies.add(req.body);
          return http.Response(multi, 207);
        }),
      );
      final items = await client.list('http://nas/dav/');
      expect(bodies.single, isEmpty, reason: '飞牛只接受空体 PROPFIND');
      expect(items.length, 1);
      expect(items.first.name, 'a.jpg');
    });

    test('服务器对空体回 400 时才回退到带体写法', () async {
      final bodies = <String>[];
      final client = WebDavClient(
        baseUrl: 'http://nas/dav',
        httpClient: MockClient((req) async {
          bodies.add(req.body);
          // 模拟"必须要请求体"的严格服务器
          if (req.body.isEmpty) return http.Response('Bad Request', 400);
          return http.Response(multi, 207);
        }),
      );
      final items = await client.list('http://nas/dav/');
      expect(bodies.length, 2, reason: '应该重试一次');
      expect(bodies[0], isEmpty);
      expect(bodies[1], contains('propfind'));
      expect(items.length, 1);
    });
  });

  group('WebDavClient · Range 取头部', () {
    test('服务器返回 206 时原样返回', () async {
      final bytes = Uint8List.fromList(List.filled(32, 0xFF));
      final client = WebDavClient(
        baseUrl: 'http://nas/dav',
        httpClient: MockClient((req) async {
          expect(req.headers['Range'], 'bytes=0-31');
          return http.Response.bytes(bytes, 206);
        }),
      );
      final got = await client.getRange('http://nas/dav/x.jpg', maxBytes: 32);
      expect(got.length, 32);
    });

    test('服务器忽略 Range 返回全量时被截断', () async {
      final big = Uint8List.fromList(List.filled(1000, 0x01));
      final client = WebDavClient(
        baseUrl: 'http://nas/dav',
        httpClient: MockClient((_) async => http.Response.bytes(big, 200)),
      );
      final got = await client.getRange('http://nas/dav/x.jpg', maxBytes: 64);
      expect(got.length, 64);
    });
  });

  group('WebDavConnection · 密码混淆存取', () {
    test('存进去的是密文，读出来是原文', () {
      const conn = WebDavConnection(
        id: 'c1',
        label: '家里的飞牛',
        baseUrl: 'http://192.168.1.10:5005/dav',
        username: 'reader',
        password: 'my-secret-pw',
      );
      final json = conn.toJson();

      // 序列化结果里不应出现明文
      final encoded = jsonEncode(json);
      expect(encoded.contains('my-secret-pw'), isFalse);
      expect(json['password'], isNot(equals('my-secret-pw')));

      // 反序列化能还原
      final back = WebDavConnection.fromJson(json);
      expect(back.password, 'my-secret-pw');
      expect(back.username, 'reader');
      expect(back.baseUrl, conn.baseUrl);
    });

    test('空密码不会炸', () {
      const conn = WebDavConnection(
        id: 'c2',
        label: '',
        baseUrl: 'http://nas/dav',
      );
      final back = WebDavConnection.fromJson(conn.toJson());
      expect(back.password, '');
      expect(back.displayLabel, 'http://nas/dav');
    });

    test('密文损坏时退回空密码而不是崩溃', () {
      final back = WebDavConnection.fromJson({
        'id': 'c3',
        'label': 'x',
        'baseUrl': 'http://nas/dav',
        'password': '!!!not-base64!!!',
      });
      expect(back.password, '');
    });
  });

  group('WebDavConnectionStore · 空存储', () {
    // 这一组是为了一个真机上抓到的崩溃补的：
    // `_loadRaw()` 曾经在没数据时返回 `const []`，而 `all()` 会 sort 它，
    // 于是「点开 NAS 导入」直接红屏：
    //   Unsupported operation: Cannot modify an unmodifiable list
    late WebDavConnectionStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      store = WebDavConnectionStore(prefs);
    });

    test('空存储时 all() 不抛异常，返回空列表', () {
      expect(store.all(), isEmpty);
    });

    test('空存储时 upsert 可以追加，并且能被读回', () async {
      await store.upsert(const WebDavConnection(
        id: 'c1',
        label: '家里的飞牛',
        baseUrl: 'http://192.168.1.10:5005/dav',
        username: 'reader',
        password: 'pw',
      ));

      final all = store.all();
      expect(all.length, 1);
      expect(all.first.label, '家里的飞牛');
      expect(all.first.password, 'pw');
    });

    test('空存储时 remove / touch 不抛异常', () async {
      await store.remove('nope');
      await store.touch('nope');
      expect(store.all(), isEmpty);
    });

    test('按 id 查找', () async {
      await store.upsert(const WebDavConnection(
        id: 'c9',
        label: 'x',
        baseUrl: 'http://nas/dav',
      ));
      expect(store.byId('c9')?.baseUrl, 'http://nas/dav');
      expect(store.byId('missing'), isNull);
    });

    test('最近用过的排在前面', () async {
      await store.upsert(WebDavConnection(
        id: 'old',
        label: 'old',
        baseUrl: 'http://a/dav',
        lastUsedAt: DateTime(2024, 1, 1),
      ));
      await store.upsert(WebDavConnection(
        id: 'new',
        label: 'new',
        baseUrl: 'http://b/dav',
        lastUsedAt: DateTime(2024, 6, 1),
      ));
      expect(store.all().first.id, 'new');
    });

    test('损坏的 JSON 不会导致崩溃', () async {
      SharedPreferences.setMockInitialValues({
        'inkscroll.webdav.connections': 'not json at all',
      });
      final prefs = await SharedPreferences.getInstance();
      final s = WebDavConnectionStore(prefs);
      expect(s.all(), isEmpty);
    });
  });

  group('PrefsStore · 批量写入书架', () {
    test('upsertBooks 一次写入多本，且不重复', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = await PrefsStore.open();

      BookMeta makeBook(String id) => BookMeta(
            id: id,
            title: '书 $id',
            kind: BookKind.comic,
            source: WebDavSource(
              connectionId: 'c1',
              folderUrl: 'http://nas/dav/$id/',
              folderName: 'x',
            ),
            pageCount: 3,
            chapterCount: 1,
            importedAt: DateTime(2026, 1, 1),
          );
      // 避免 analyzer 报未使用
      expect(prefs, isNotNull);

      await store.upsertBooks([makeBook('a'), makeBook('b')]);
      expect(store.loadBooks().length, 2);

      // 再写一次同样的 id（模拟重复导入）不应变成 4 本
      await store.upsertBooks([makeBook('a'), makeBook('b')]);
      expect(store.loadBooks().length, 2);

      // 新增 + 更新混合
      await store.upsertBooks([makeBook('c'), makeBook('a')]);
      final books = store.loadBooks();
      expect(books.length, 3);
      expect(books.where((b) => b.id == 'a').length, 1);
    });
  });

  group('BookSource · 网盘压缩包', () {
    test('WebDavArchiveSource 序列化往返一致', () {
      const src = WebDavArchiveSource(
        connectionId: 'c1',
        archiveUrl: 'http://pan/webdav/%E5%9D%8F%E7%8B%BC.zip',
        archiveName: '坏狼.zip',
        archiveSize: 638427,
      );
      final back = BookSource.fromJson(src.toJson());
      expect(back, isA<WebDavArchiveSource>());
      final a = back as WebDavArchiveSource;
      expect(a.connectionId, 'c1');
      expect(a.archiveUrl, src.archiveUrl);
      expect(a.archiveName, '坏狼.zip');
      expect(a.archiveSize, 638427);
    });

    test('archiveSize 缺省时也能往返（老数据/拿不到大小）', () {
      const src = WebDavArchiveSource(
        connectionId: 'c2',
        archiveUrl: 'http://pan/a.cbz',
        archiveName: 'a.cbz',
      );
      final back = BookSource.fromJson(src.toJson()) as WebDavArchiveSource;
      expect(back.archiveSize, isNull);
    });
  });

  group('BookSource · WebDavSource 序列化', () {
    test('往返一致', () {
      const src = WebDavSource(
        connectionId: 'dav_abc',
        folderUrl: 'http://nas:5005/dav/%E6%BC%AB%E7%94%BB/',
        folderName: '漫画',
      );
      final json = src.toJson();
      expect(json['type'], 'webdav');

      final back = BookSource.fromJson(json);
      expect(back, isA<WebDavSource>());
      final w = back as WebDavSource;
      expect(w.connectionId, 'dav_abc');
      expect(w.folderUrl, src.folderUrl);
      expect(w.folderName, '漫画');
    });
  });
}
