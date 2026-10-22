/// 「合并合集」的单元测试。
///
/// ## 为什么这些测试必须存在
///
/// 这个功能的核心风险在**页 id 撞车**：每一话的页都是话内编号（`n:0`…），
/// 直接拼进同一个 Document 的话，第二话的 `n:0` 会顶掉第一话的第一页 ——
/// 表现是"整本书只剩第一话加最后一话最后一页"，而且**总页数还是对的**，
/// 靠肉眼几乎发现不了。所以断言必须精确到"页 id 唯一 + 阅读顺序连续"。
///
/// 扫描部分用假的 WebDAV 服务器（`MockClient`）覆盖，不需要真的 NAS。
/// 同时锁住"关闭开关时行为一点没变"，防止以后改动把 174 本打回 38 本。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inkscroll/data/prefs_store.dart';
import 'package:inkscroll/data/webdav/webdav_client.dart';
import 'package:inkscroll/data/webdav/webdav_connection.dart';
import 'package:inkscroll/importers/webdav_folder_importer.dart';
import 'package:inkscroll/reader/document.dart';
import 'package:inkscroll/reader/webdav_page_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// 假 WebDAV 服务器
// ---------------------------------------------------------------------------

String _multistatus(String body) =>
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<D:multistatus xmlns:D="DAV:">$body</D:multistatus>';

String _response({
  required String href,
  required String displayName,
  required bool isDir,
  int? size,
}) {
  final props = StringBuffer()
    ..write('<D:displayname>$displayName</D:displayname>');
  if (size != null) {
    props.write('<D:getcontentlength>$size</D:getcontentlength>');
  }
  props.write(isDir
      ? '<D:resourcetype><D:collection/></D:resourcetype>'
      : '<D:resourcetype/>');
  return '<D:response><D:href>$href</D:href>'
      '<D:propstat><D:prop>$props</D:prop>'
      '<D:status>HTTP/1.1 200 OK</D:status>'
      '</D:propstat></D:response>';
}

/// 1×1 之外的"图片"：只要 PNG 头（宽高 1000×1500）就够 `ImageHeaderParser`。
///
/// 导入阶段只嗅探前 4 张图的尺寸，**不解码像素** —— 所以不需要真的图片。
Uint8List _pngHeader({int width = 1000, int height = 1500}) {
  final b = BytesBuilder();
  b.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  b.add(const [0x00, 0x00, 0x00, 0x0D]); // IHDR 长度
  b.add(ascii.encode('IHDR'));
  b.add((ByteData(4)..setUint32(0, width)).buffer.asUint8List());
  b.add((ByteData(4)..setUint32(0, height)).buffer.asUint8List());
  b.add([8, 6, 0, 0, 0]); // bitDepth / colorType / …
  b.add(List<int>.filled(16, 0)); // CRC 等：解析头部用不到
  return b.toBytes();
}

/// 目录结构：key 是相对 `/dav` 的路径（无首尾斜杠，根为 `''`），
/// value 是子项名字（目录名不加斜杠，是否目录由 tree 里有没有这个 key 判断）。
class FakeDav {
  FakeDav(this.tree, {Set<String>? dirs}) : _dirs = dirs ?? {};

  final Map<String, List<String>> tree;

  /// 显式声明的目录（用于"空目录"这种 tree 里看不到的项）
  final Set<String> _dirs;

  bool isDir(String key) => tree.containsKey(key) || _dirs.contains(key);

  /// 处理一次请求（`client()` 只是把它包成 MockClient，便于测试里再套一层）
  Future<http.Response> handle(http.Request req) async {
    if (req.method == 'GET') {
      // 嗅探尺寸：任何图片都回同一个 PNG 头
      return http.Response.bytes(_pngHeader(), 206);
    }
    final key =
        req.url.pathSegments.skip(1).where((s) => s.isNotEmpty).join('/');
    final children = tree[key];
    if (children == null) {
      return http.Response('not found', 404);
    }
    final buf = StringBuffer();
    for (final name in children) {
      final childKey = key.isEmpty ? name : '$key/$name';
      final dir = isDir(childKey);
      final encoded = Uri.encodeComponent(name);
      buf.write(_response(
        href: '/dav/${key.isEmpty ? '' : '$key/'}$encoded${dir ? '/' : ''}',
        displayName: name,
        isDir: dir,
        size: dir ? null : 1024,
      ));
    }
    return http.Response(
      _multistatus(buf.toString()),
      207,
      headers: {'content-type': 'application/xml; charset=utf-8'},
    );
  }

  http.Client client() => MockClient(handle);
}

WebDavClient _client(FakeDav dav) => WebDavClient(
      baseUrl: 'http://nas:5005/dav',
      httpClient: dav.client(),
    );

/// `漫画根目录/XX合集/第X话/` + 一个"整话是一个 zip"的合集
FakeDav _sampleLibrary() => FakeDav({
      'comic': ['A合集', 'B合集'],
      'comic/A合集': ['第一话', '第二话'],
      'comic/A合集/第一话': ['001.jpg', '002.jpg'],
      'comic/A合集/第二话': ['001.jpg', '002.jpg'],
      'comic/B合集': ['第三话.zip', '第四话.zip'],
    });

// ---------------------------------------------------------------------------

void main() {
  group('scanLibrary · 合并合集（默认关闭时行为不变）', () {
    test('关闭时每一话各成一本，命名仍是「XX 第一话」', () async {
      final list = await WebDavFolderImporter.scanLibrary(
        _client(_sampleLibrary()),
        'http://nas:5005/dav/comic',
      );

      final names = list.map((c) => c.name).toList();
      expect(names, containsAll(['A 第一话', 'A 第二话']));
      expect(list.every((c) => !c.isCollection), isTrue);
      // 两个 zip 各成一本
      expect(list.where((c) => c.isArchive).length, 2);
    });

    test('开启时整个合集只产出 1 个候选，各话进 chapters', () async {
      final list = await WebDavFolderImporter.scanLibrary(
        _client(_sampleLibrary()),
        'http://nas:5005/dav/comic',
        mergeCollections: true,
      );

      final collections = list.where((c) => c.isCollection).toList();
      // 「A合集」= 图片子目录；「B合集」= 整话是 zip
      expect(collections.length, 2);
      // 开启后不该再有"每话一本"的散书
      expect(list.where((c) => !c.isCollection).length, 0);

      final a = collections.firstWhere((c) => c.name == 'A');
      expect(a.name, 'A'); // 「合集」二字已去掉
      expect(a.chapters.map((c) => c.title).toList(), ['第一话', '第二话']);
      expect(a.chapters.first.images.length, 2);
      // 候选 URL 是**合集目录**（判重与重建文档都以它为准）
      expect(a.url, endsWith('/A%E5%90%88%E9%9B%86/'));

      final b = collections.firstWhere((c) => c.name == 'B');
      expect(b.chapters.map((c) => c.title).toList(), ['第三话', '第四话']);
      expect(b.chapters.every((c) => c.isArchive), isTrue);
    });

    test('合集里没图也没压缩包时不产出空候选', () async {
      final list = await WebDavFolderImporter.scanLibrary(
        _client(FakeDav({
          'comic': ['空合集'],
          'comic/空合集': ['x.txt'],
          'comic/空合集/笔记': [],
        })),
        'http://nas:5005/dav/comic',
        mergeCollections: true,
      );
      expect(list, isEmpty);
    });

    test('★ 目录回「207 + 空列表」时会重试，书不会静默消失', () async {
      // 123云盘的经典坑：并发 PROPFIND 不报错，只是回一个空列表。
      // 旧代码会当成"这个目录是空的"，于是同一账号每次导入数量都不一样。
      final dav = _sampleLibrary();
      var dropped = false;
      final flaky = MockClient((req) async {
        final segs = req.url.pathSegments;
        final isCollection =
            req.method == 'PROPFIND' && segs.contains('A合集');
        if (!dropped && isCollection) {
          dropped = true;
          return http.Response(
            _multistatus(''), // 空，但状态是成功
            207,
            headers: {'content-type': 'application/xml; charset=utf-8'},
          );
        }
        return dav.handle(req);
      });

      final list = await WebDavFolderImporter.scanLibrary(
        WebDavClient(baseUrl: 'http://nas:5005/dav', httpClient: flaky),
        'http://nas:5005/dav/comic',
        mergeCollections: true,
      );

      expect(dropped, isTrue); // 空响应确实发生过
      final names = list.where((c) => c.isCollection).map((c) => c.name);
      expect(names, contains('A')); // 重试后合集没丢
    });
  });

  group('设置持久化 · 合并合集默认关闭', () {
    test('默认 false（不打开就等于没有这个功能）', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PrefsStore.open();
      expect(prefs.loadMergeCollections(), isFalse);
    });

    test('存进去能读回来，键名固定为 library.mergeCollections.v1', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PrefsStore.open();
      await prefs.saveMergeCollections(true);
      expect(prefs.loadMergeCollections(), isTrue);
      // 键名一旦改了，老用户的开关就会"自己关掉"
      expect(prefs.prefs.getBool('library.mergeCollections.v1'), isTrue);
      // 与「识别合集结构」互不影响
      await prefs.saveMergeCollections(false);
      expect(prefs.loadMergeCollections(), isFalse);
      expect(prefs.loadDeepScan(), isTrue);
    });
  });

  group('★ 页 id 撞车（合并合集最容易出的错）', () {
    Document docWithPages(String id, int count) {
      final pages = <String, PageNode>{};
      final ids = <String>[];
      for (var i = 0; i < count; i++) {
        final pid = 'n:$i';
        pages[pid] = PageNode(
          id: pid,
          kind: PageKind.image,
          content: ImageContent(
            ref: WebDavRef(url: 'http://nas/$id/$i.jpg', connectionId: 'c1'),
          ),
          aspectRatio: 1.5,
        );
        ids.add(pid);
      }
      return Document(
        id: 'doc-$id',
        bookId: '',
        title: id,
        kind: DocumentKind.comic,
        chapters: [Chapter(index: 0, title: id, pageIds: ids)],
        pages: pages,
      );
    }

    test('各话的页 id 加了章前缀，页数不丢、顺序不乱', () {
      final merged = WebDavFolderImporter.mergeDocuments(
        connId: 'c1',
        collectionUrl: 'http://nas/dav/A%E5%90%88%E9%9B%86/',
        title: 'A',
        parts: [
          (title: '第一话', document: docWithPages('a', 3)),
          (title: '第二话', document: docWithPages('b', 2)),
        ],
      );

      expect(merged.pageCount, 5); // 3 + 2，没有被顶掉
      expect(merged.chapters.length, 2);
      expect(merged.chapters[0].pageIds.take(2), ['c0_n:0', 'c0_n:1']);
      expect(merged.chapters[1].pageIds.first, 'c1_n:0');
      // 阅读顺序：整本连续，不按话重置
      expect(merged.pagesInOrder.map((p) => p.id).toList(), [
        'c0_n:0', 'c0_n:1', 'c0_n:2', 'c1_n:0', 'c1_n:1',
      ]);
      expect(merged.pages.keys.length, 5); // id 全局唯一
    });

    test('跨话翻页连续：第 4 页属于第二话（进度/章节定位的基础）', () {
      final merged = WebDavFolderImporter.mergeDocuments(
        connId: 'c1',
        collectionUrl: 'http://nas/dav/A%E5%90%88%E9%9B%86/',
        title: 'A',
        parts: [
          (title: '第一话', document: docWithPages('a', 3)),
          (title: '第二话', document: docWithPages('b', 2)),
        ],
      );

      expect(merged.chapterOfPage(2)!.title, '第一话');
      expect(merged.chapterOfPage(3)!.title, '第二话'); // 第 4 页 = 第二话第 1 页
      expect(merged.indexOfPage('c1_n:0'), 3);
    });

    test('空话被跳过，且后面的章号不错位', () {
      final merged = WebDavFolderImporter.mergeDocuments(
        connId: 'c1',
        collectionUrl: 'http://nas/dav/B/',
        title: 'B',
        parts: [
          (title: '第一话', document: docWithPages('a', 2)),
          (title: '空话', document: docWithPages('empty', 0)),
          (title: '第三话', document: docWithPages('c', 2)),
        ],
      );

      expect(merged.chapters.length, 2);
      expect(merged.chapters.map((c) => c.title).toList(), ['第一话', '第三话']);
      expect(merged.chapters.map((c) => c.index).toList(), [0, 1]);
      expect(merged.pagesInOrder[2].id, 'c1_n:0'); // 第三话的页接在第一话后面
    });
  });

  group('★ 请求解析：同一本书里既有直链图片也有包内页', () {
    test('两种页都能读出字节（否则 zip 章节是一片空白）', () async {
      // 一张 PNG 头 + 一个只含这张图的 zip
      final png = _pngHeader();
      final archive = Archive()
        ..addFile(ArchiveFile('001.jpg', png.length, png));
      final zipBytes = ZipEncoder().encode(archive)!;

      // 假服务器：PROPFIND 报大小，GET 支持 Range（zip 靠它按需读）
      final httpClient = MockClient((req) async {
        if (req.method == 'PROPFIND') {
          return http.Response(
            '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
            '<D:response><D:href>${req.url.path}</D:href>'
            '<D:propstat><D:prop>'
            '<D:getcontentlength>${zipBytes.length}</D:getcontentlength>'
            '<D:resourcetype/>'
            '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
            '</D:response></D:multistatus>',
            207,
            headers: {'content-type': 'application/xml; charset=utf-8'},
          );
        }
        // 压缩包 URL 回 zip 字节，其它回图片字节
        final body = req.url.path.endsWith('.zip') ? zipBytes : <int>[...png];
        final range =
            req.headers['Range'] ?? req.headers['range'];
        if (range != null) {
          final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
          final start = int.parse(m.group(1)!);
          final end = m.group(2)!.isEmpty
              ? body.length - 1
              : int.parse(m.group(2)!);
          if (start >= body.length) return http.Response('', 416);
          final stop = (end + 1).clamp(0, body.length);
          return http.Response.bytes(body.sublist(start, stop), 206);
        }
        return http.Response.bytes(body, 200);
      });

      final direct = PageNode(
        id: 'c0_n:0',
        kind: PageKind.image,
        content: ImageContent(
          ref: const WebDavRef(
            url: 'http://nas:5005/dav/comic/direct/001.jpg',
            connectionId: 'c1',
          ),
        ),
        aspectRatio: 1000 / 1500,
      );
      // 第二话是 zip：页引用是"包 + 包内路径"
      final inZip = PageNode(
        id: 'c1_n:0',
        kind: PageKind.image,
        content: ImageContent(
          ref: const WebDavArchiveRef(
            connectionId: 'c1',
            archiveUrl: 'http://nas:5005/dav/comic/vol2.zip',
            entryPath: '001.jpg',
          ),
        ),
        aspectRatio: 1000 / 1500,
      );

      final cacheDir = Directory.systemTemp.createTempSync('inkscroll_merge');
      final resolver = WebDavPageByteResolver(
        client: WebDavClient(
          baseUrl: 'http://nas:5005/dav',
          httpClient: httpClient,
        ),
        cacheDir: cacheDir,
        pageList: [direct, inZip],
        prefetchRadius: 1,
      );
      addTearDown(() async {
        await resolver.dispose();
        try {
          cacheDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      // 直链页
      expect(await resolver.imageBytes(direct), png);
      // 包内页：走 WebDavArchivePageResolver（以前这里直接抛
      // "页内容引用类型与网络来源不匹配"，整章空白）
      expect(await resolver.imageBytes(inZip), png);
      expect((await resolver.peekBytes(inZip, bytes: 16)).length, 16);
    });
  });

  group('buildMergedCollection · 逐话复用 _build 再合并', () {
    test('2 话 × 2 图 → 1 本 4 页 2 章，书名不带「合集」', () async {
      final dav = _sampleLibrary();
      final client = _client(dav);
      final candidates = await WebDavFolderImporter.scanLibrary(
        client,
        'http://nas:5005/dav/comic',
        mergeCollections: true,
      );
      final candidate = candidates.firstWhere((c) => c.name == 'A');

      final doc = await WebDavFolderImporter.buildMergedCollection(
        conn: WebDavConnection(
          id: 'c1',
          baseUrl: 'http://nas:5005/dav',
          username: '',
          password: '',
          label: '测试',
          allowSelfSigned: false,
        ),
        client: client,
        candidate: candidate,
      );

      expect(doc.title, 'A');
      expect(doc.kind, DocumentKind.comic);
      expect(doc.chapters.length, 2);
      expect(doc.pageCount, 4);
      expect(doc.chapters.map((c) => c.title).toList(), ['第一话', '第二话']);
      // 尺寸来自嗅探（不解码像素）：1000×1500
      expect(doc.pagesInOrder.first.aspectRatio, closeTo(1000 / 1500, 0.001));
      expect(doc.warnings.join(), contains('合并'));
    });
  });
}
