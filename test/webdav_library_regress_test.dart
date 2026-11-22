/// WebDAV 批量导入（importWebDavLibrary）的回归测试。
///
/// 锁住两个真机上可感的缺陷，都是"一轮批量导入结束后的残留状态"：
///
/// 1. 防重入标志复位 —— 旧实现在 finally 里漏了 `_importing = false`，
///    第一轮批量导入结束后，同一会话里再次「添加为库」永远抛
///    "已有一批导入正在进行，请等它跑完再试"。
/// 2. 进度横幅清零 —— 旧实现 finally 里漏了 `_setProgress(null, '')`，
///    导入结束后横幅永远停在 100% 不消失。
///
/// 这些缺陷无法用 MockClient 覆盖（它们不在 WebDavClient 里），
/// 必须把 AppState 拉起来跑完整批量导入。AppState 内部用
/// `connection.createClient()` 造真实 WebDavClient，注入不了假 http.Client，
/// 所以这里起一个**本地 HTTP 服务器**模拟 WebDAV（PROPFIND + GET）。
///
/// 顺带锁住同一批修的书名行为：本地文件夹导入时「XX合集」→「XX」。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkscroll/data/byte_store.dart';
import 'package:inkscroll/data/importer.dart';
import 'package:inkscroll/data/models/book_meta.dart';
import 'package:inkscroll/data/prefs_store.dart';
import 'package:inkscroll/data/webdav/webdav_connection.dart';
import 'package:inkscroll/state/app_state.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 合法的 1×1 PNG（有真实 IHDR/IDAT/IEND，头部嗅探与封面解码都能吃）
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// ─── 本地假 WebDAV 服务器 ───────────────────────────────────────
///
/// 目录树：`tree['']` 是根目录的孩子名列表。
/// 任何 PROPFIND 都按目标路径返回孩子的多状态响应；
/// GET 返回 PNG 头（支持 Range，与真 NAS 的 206 口径一致）。
class _FakeDav {
  _FakeDav(this.tree);

  /// key = 相对路径（'' 为根，'tallimg' 为子目录），value = 孩子名
  final Map<String, List<String>> tree;

  HttpServer? _server;
  int get port => _server!.port;
  String get base => 'http://127.0.0.1:$port';

  bool _isDir(String rel) => tree.containsKey(rel);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      try {
        if (req.method == 'PROPFIND') {
          await _propfind(req);
        } else if (req.method == 'GET') {
          await _get(req);
        } else {
          req.response.statusCode = HttpStatus.methodNotAllowed;
          await req.response.close();
        }
      } catch (_) {
        if (!req.response.headers.persistentConnection) {
          return; // 客户端已断开，写不了了
        }
        req.response.statusCode = 500;
        await req.response.close();
      }
    });
  }

  Future<void> stop() async => _server?.close(force: true);

  String _rel(Uri uri) =>
      uri.pathSegments.where((s) => s.isNotEmpty).join('/');

  Future<void> _propfind(HttpRequest req) async {
    final rel = _rel(req.uri);
    final children = tree[rel] ?? const <String>[];
    final buf = StringBuffer(
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<D:multistatus xmlns:D="DAV:">',
    );
    for (final name in children) {
      final childRel = rel.isEmpty ? name : '$rel/$name';
      final isDir = _isDir(childRel);
      final hrefParts = <String>[if (rel.isNotEmpty) ...rel.split('/'), name];
      final href = Uri.encodeFull('/${hrefParts.join('/')}${isDir ? '/' : ''}');
      buf.write('<D:response><D:href>$href</D:href>'
          '<D:propstat><D:prop>'
          '<D:displayname>$name</D:displayname>'
          '${isDir ? '<D:resourcetype><D:collection/></D:resourcetype>' : '<D:resourcetype/>'}'
          '<D:getcontentlength>${_png1x1.length}</D:getcontentlength>'
          '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
          '</D:response>');
    }
    buf.write('</D:multistatus>');
    req.response.statusCode = HttpStatus.multiStatus;
    req.response.headers.contentType =
        ContentType('text', 'xml', charset: 'utf-8');
    req.response.write(buf.toString());
    await req.response.close();
  }

  Future<void> _get(HttpRequest req) async {
    final rel = _rel(req.uri);
    final i = rel.lastIndexOf('/');
    final parent = i < 0 ? '' : rel.substring(0, i);
    final name = i < 0 ? rel : rel.substring(i + 1);
    if (_isDir(rel) || !(tree[parent] ?? const <String>[]).contains(name)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType('image', 'jpeg');
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    // 与真 NAS 一致：带 Range 返回 206（给头部嗅探），否则 200 全量
    if (req.headers.value(HttpHeaders.rangeHeader) != null) {
      req.response.statusCode = HttpStatus.partialContent;
    } else {
      req.response.statusCode = HttpStatus.ok;
    }
    req.response.add(_png1x1);
    await req.response.close();
  }
}

/// 假 path_provider：把应用私有目录重定向到临时目录
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.dir);
  final String dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// 测试环境里的 AppState：mock SharedPreferences + 假私有目录
Future<AppState> _newApp() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final app = AppState(await PrefsStore.open());
  await app.bootstrap();
  return app;
}

/// flutter_test 默认给全局 HttpClient 装一个假实现，所有请求返回 400。
/// 本组测试要打真实本地 HTTP（假 WebDAV 服务器），所以显式摘掉它。
/// 注意：这不是 mock，而是"让真实网络可用"——被测代码本身没有 http 注入点。
void _enableRealHttp() {
  HttpOverrides.global = null;
}

void main() {
  // 不用 TestWidgetsFlutterBinding：它会连带装上假 HttpClient。
  // 这里只需要纯 Dart 的 SharedPreferences mock 与 path_provider mock。
  setUpAll(_enableRealHttp);

  group('AppState · WebDAV 批量导入的收尾状态（回归）', () {
    late Directory appDir;
    late _FakeDav dav;

    setUp(() async {
      appDir = await Directory.systemTemp.createTemp('inkscroll_test_');
      PathProviderPlatform.instance = _FakePathProvider(appDir.path);
      dav = _FakeDav({
        '': ['tallimg'],
        'tallimg': ['p1.jpg', 'p2.jpg', 'p3.jpg'],
      });
      await dav.start();
    });

    tearDown(() async {
      await dav.stop();
      if (await appDir.exists()) await appDir.delete(recursive: true);
    });

    test('横幅清零 + 第二次导入不被"已有一批"卡死', () async {
      final app = await _newApp();
      final conn = WebDavConnection(
        id: 'dav_test',
        label: 'TestDAV',
        baseUrl: dav.base,
      );
      await app.webdavConnections.upsert(conn);

      // ── 第一轮：正常导入 ──
      final r1 = await app.importWebDavLibrary(
        connection: conn,
        folderUrl: '${dav.base}/',
        folderName: 'dav',
      );
      expect(r1.scanned, 1, reason: '根目录扫描应发现 tallimg 一个候选');
      expect(r1.imported, 1);
      expect(r1.failures, isEmpty);
      expect(app.importProgress, isNull,
          reason: '批量导入结束后进度横幅必须清零（旧 bug：停在 100%）');
      expect(app.books.length, 1);
      expect(app.books.first.source, isA<WebDavSource>(),
          reason: '导入的书应是 WebDAV 网络书');

      // ── 第二轮：全部已导入，应走判重跳过，而不是"已有一批导入正在进行" ──
      final r2 = await app.importWebDavLibrary(
        connection: conn,
        folderUrl: '${dav.base}/',
        folderName: 'dav',
      );
      expect(r2.imported, 0);
      expect(r2.skipped, 1, reason: '重复目录应被跳过');
      expect(r2.allAlreadyAdded, isTrue);
      expect(app.importProgress, isNull);
      expect(app.books.length, 1, reason: '不应产生重复书');
    });

    test('新书加入网盘后，第二次批量导入能正常追加', () async {
      final app = await _newApp();
      final conn = WebDavConnection(
        id: 'dav_test2',
        label: 'TestDAV',
        baseUrl: dav.base,
      );
      await app.webdavConnections.upsert(conn);

      final r1 = await app.importWebDavLibrary(
        connection: conn,
        folderUrl: '${dav.base}/',
        folderName: 'dav',
      );
      expect(r1.imported, 1);

      // 网盘上新到一本书
      dav.tree[''] = ['tallimg', 'newbook'];
      dav.tree['newbook'] = ['n1.jpg', 'n2.jpg'];

      final r2 = await app.importWebDavLibrary(
        connection: conn,
        folderUrl: '${dav.base}/',
        folderName: 'dav',
      );
      expect(r2.imported, 1, reason: '第二轮应导入新增的一本（旧 bug：被防重入标志卡死抛异常）');
      expect(r2.skipped, 1);
      expect(app.books.length, 2);
      expect(app.importProgress, isNull);
    });
  });

  group('书名原样（0.15.3 删除合集命名过滤）', () {
    test('本地文件夹导入：「XX合集」目录 → 书名「XX合集」', () async {
      final appDir = await Directory.systemTemp.createTemp('inkscroll_test_');
      PathProviderPlatform.instance = _FakePathProvider(appDir.path);
      addTearDown(() async {
        if (await appDir.exists()) await appDir.delete(recursive: true);
      });

      // 建一个名为「XX合集」的真实图片目录
      final bookDir = Directory(p.join(appDir.path, 'XX合集'));
      await bookDir.create(recursive: true);
      await File(p.join(bookDir.path, 'p1.png')).writeAsBytes(_png1x1);
      await File(p.join(bookDir.path, 'p2.png')).writeAsBytes(_png1x1);

      final app = await _newApp();

      final meta = await app.importFrom(SourcePick(
        kind: SourcePickKind.folder,
        displayName: 'XX合集',
        sourceId: ByteStore.newBookId(),
        path: bookDir.path,
      ));

      expect(meta.title, 'XX合集',
          reason: '0.15.3 删除名称过滤：书名 = 目录名原样');
      expect(meta.pageCount, 2);
      expect(app.importProgress, isNull);
    });
  });
}
