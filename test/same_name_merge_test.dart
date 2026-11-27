/// 「同名漫画自动合并」的单元测试。
///
/// 覆盖四件纯逻辑（不需要网络）：
/// 1. 分组标题归一化 [WebDavFolderImporter.normalizeGroupTitle] ——
///    只影响分组，不影响显示书名；
/// 2. 章节标题去重 [WebDavFolderImporter.dedupeTitles] ——
///    同名成员在章节菜单里必须能区分；
/// 3. 候选分组 [WebDavFolderImporter.groupCandidatesByTitle] ——
///    保序、跨类型（文件夹/压缩包/合集）都能归到一组；
/// 4. 追加章节 [WebDavFolderImporter.appendDocumentPart] ——
///    跨批合并的核心风险同样是页 id 撞车：新章号必须从旧章节数起算，
///    旧页 id 与旧章节一概不动（阅读进度按 pageIndex/chapterIndex 存）。
///
/// 以及 [WebDavMergedSource] 的 JSON 往返（书源持久化的契约）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:inkscroll/data/models/book_meta.dart';
import 'package:inkscroll/importers/webdav_folder_importer.dart';
import 'package:inkscroll/reader/document.dart';

Document _docWithPages(String id, int count) {
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

void main() {
  group('normalizeGroupTitle（只管分组，不改显示名）', () {
    test('压缩包后缀被剥掉（大小写不敏感）', () {
      expect(WebDavFolderImporter.normalizeGroupTitle('海贼王.zip'), '海贼王');
      expect(WebDavFolderImporter.normalizeGroupTitle('海贼王.CBZ'), '海贼王');
      expect(WebDavFolderImporter.normalizeGroupTitle('OP.tar.gz'), 'op');
    });

    test('重复下载序号（1）被剥掉', () {
      expect(
          WebDavFolderImporter.normalizeGroupTitle('海贼王 (1).zip'), '海贼王');
      expect(WebDavFolderImporter.normalizeGroupTitle('海贼王（12）'), '海贼王');
    });

    test('空格折叠 + 大小写归一', () {
      expect(
        WebDavFolderImporter.normalizeGroupTitle('  One   Piece  '),
        'one piece',
      );
      expect(WebDavFolderImporter.normalizeGroupTitle('ONE PIECE'), 'one piece');
    });

    test('只有序号本身时不剥（避免剥成空串）', () {
      expect(WebDavFolderImporter.normalizeGroupTitle('(1)'), '(1)');
    });

    test('真书名不受影响', () {
      expect(
        WebDavFolderImporter.normalizeGroupTitle('进击的巨人 第1卷'),
        '进击的巨人 第1卷',
      );
    });
  });

  group('dedupeTitles（同名成员在章节菜单里要能区分）', () {
    test('无重复原样返回', () {
      expect(
        WebDavFolderImporter.dedupeTitles(['第一话', '第二话']),
        ['第一话', '第二话'],
      );
    });

    test('重名追加 (2)、(3)', () {
      expect(
        WebDavFolderImporter.dedupeTitles(['海贼王.zip', '海贼王.cbz', '海贼王.zip']),
        ['海贼王.zip', '海贼王.cbz', '海贼王.zip (2)'],
      );
    });

    test('空标题给默认名', () {
      expect(WebDavFolderImporter.dedupeTitles(['', '']), ['第 1 部分', '第 2 部分']);
    });
  });

  group('groupCandidatesByTitle（保序分组）', () {
    WebDavComicCandidate folder(String name) => WebDavComicCandidate(
          url: 'http://nas/$name/',
          name: name,
          images: const [],
        );

    WebDavComicCandidate archive(String name) => WebDavComicCandidate(
          url: 'http://nas/$name.zip',
          name: name,
          images: const [],
          isArchive: true,
        );

    test('同名（含后缀/序号差异）归为一组，顺序不变', () {
      final groups = WebDavFolderImporter.groupCandidatesByTitle([
        folder('进击的巨人'),
        archive('海贼王'),
        archive('海贼王 (1)'),
      ]);
      expect(groups.length, 2);
      expect(groups[0].length, 1);
      expect(groups[0][0].name, '进击的巨人');
      expect(groups[1].length, 2);
      expect(groups[1][0].url, 'http://nas/海贼王.zip');
      expect(groups[1][1].url, 'http://nas/海贼王 (1).zip');
    });

    test('不同书名不合并', () {
      final groups = WebDavFolderImporter.groupCandidatesByTitle([
        archive('海贼王'),
        archive('海贼王 第2卷'),
      ]);
      expect(groups.length, 2);
    });
  });

  group('appendDocumentPart（跨批追加：旧页 id 与进度一概不动）', () {
    test('新章号从旧章节数起算，页 id 全局唯一，文档级字段保留', () {
      final old = WebDavFolderImporter.mergeDocuments(
        connId: 'c1',
        collectionUrl: 'http://nas/dav/A/',
        title: 'A',
        parts: [
          (title: '第一话', document: _docWithPages('a', 3)),
          (title: '第二话', document: _docWithPages('b', 2)),
        ],
      );
      final merged = WebDavFolderImporter.appendDocumentPart(
        old,
        title: '第三话',
        part: _docWithPages('c', 4),
      );

      expect(merged.pageCount, 9); // 3 + 2 + 4
      expect(merged.chapters.length, 3);
      expect(merged.chapters[2].title, '第三话');
      expect(merged.chapters[2].index, 2);
      // 旧章节的页 id 原样（阅读进度按索引存，不受追加影响）
      expect(merged.chapters[0].pageIds, old.chapters[0].pageIds);
      expect(merged.chapters[1].pageIds, old.chapters[1].pageIds);
      // 新章页 id 用新章号前缀，全局唯一
      expect(merged.chapters[2].pageIds.first, 'c2_n:0');
      expect(merged.pages.keys.toSet().length, merged.pageCount);
      // 文档级字段
      expect(merged.id, old.id);
      expect(merged.bookId, old.bookId);
      expect(merged.title, old.title);
      expect(merged.kind, old.kind);
      // 跨话定位：第 6 页（index 5）属于第三话
      expect(merged.chapterOfPage(5)!.title, '第三话');
    });

    test('追加进「单文件夹书」（页 id 无章前缀 n:i）也不撞车', () {
      final single = _docWithPages('solo', 5); // 页 id = n:0…
      final merged = WebDavFolderImporter.appendDocumentPart(
        single,
        title: '续',
        part: _docWithPages('more', 2),
      );
      expect(merged.pageCount, 7);
      expect(merged.chapters[0].pageIds.first, 'n:0'); // 原样
      expect(merged.chapters[1].pageIds.first, 'c1_n:0'); // 新章前缀
    });

    test('空成员不追加，返回原文档', () {
      final old = _docWithPages('a', 3);
      final empty = _docWithPages('empty', 0);
      final merged = WebDavFolderImporter.appendDocumentPart(
        old,
        title: '空',
        part: empty,
      );
      expect(merged.pageCount, 3);
      expect(merged.chapters.length, 1);
      expect(identical(merged, old), isTrue);
    });
  });

  group('WebDavMergedSource JSON 往返', () {
    test('成员（含密码与压缩包标记）完整还原', () {
      const src = WebDavMergedSource(
        connectionId: 'c1',
        rootUrl: 'http://nas/dav/',
        members: [
          WebDavMergedMember(url: 'http://nas/a.zip', name: 'a.zip',
              isArchive: true, archiveSize: 123, password: 'pw1'),
          WebDavMergedMember(url: 'http://nas/b/', name: 'b'),
        ],
      );
      final restored =
          BookSource.fromJson(src.toJson()) as WebDavMergedSource;
      expect(restored.connectionId, 'c1');
      expect(restored.rootUrl, 'http://nas/dav/');
      expect(restored.members.length, 2);
      expect(restored.members[0].url, 'http://nas/a.zip');
      expect(restored.members[0].isArchive, isTrue);
      expect(restored.members[0].archiveSize, 123);
      expect(restored.members[0].password, 'pw1');
      expect(restored.members[1].isArchive, isFalse);
      expect(restored.members[1].password, isNull);
    });
  });
}
