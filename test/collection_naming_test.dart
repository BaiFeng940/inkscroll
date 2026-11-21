import 'package:flutter_test/flutter_test.dart';

import 'package:inkscroll/importers/webdav_folder_importer.dart';

// 合集命名清洗回归测试（用户需求：滤除「合集」二字的同时，
// 把**前后**的各种括号也一起过滤掉）。
// 改坏这条规则的表现：书架上一堆「【XX】」「（XX）」，或者名字被撕成残缺文本。
void main() {
  group('stripCollectionMarkers（合集名清洗）', () {
    test('基础：去掉「合集」二字', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('XX合集'), 'XX');
      expect(WebDavFolderImporter.stripCollectionMarkers('XX合集'), 'XX');
    });

    test('前置全角括号：`（XX）合集` → XX', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('（XX）合集'), 'XX');
    });

    test('前置方头括号：`【XX】合集` → XX', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('【XX】合集'), 'XX');
    });

    test('直角引号：`「XX」合集` → XX', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('「XX」合集'), 'XX');
    });

    test('半角括号：`(XX)合集` → XX', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('(XX)合集'), 'XX');
    });

    test('尾随括号：`XX合集（完）` → XX', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('XX合集（完）'), 'XX');
    });

    test('尾随半角方括号：`XX合集[01-99]` → XX', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('XX合集[01-99]'), 'XX');
    });

    test('前后都有括号：`【XX】合集（完）` → XX', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('【XX】合集（完）'), 'XX');
    });

    test('「合集」本身在括号里：`（XX合集）` → XX', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('（XX合集）'), 'XX');
    });

    test('纯「合集」目录名：剥完为空则回退原名', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('合集'), '合集');
    });

    test('不误伤无括号的书名', () {
      expect(WebDavFolderImporter.stripCollectionMarkers('海贼王合集'), '海贼王');
    });
  });

  group('collectionTitle / collectionBookName（书架展示名）', () {
    test('整本书名：`【XX】合集` → XX', () {
      expect(WebDavFolderImporter.collectionTitle('【XX】合集'), 'XX');
    });

    test('整本书名：剥完为空保留原名', () {
      expect(WebDavFolderImporter.collectionTitle('合集'), '合集');
    });

    test('单话名拼上清洗后的合集名：`（XX）合集` + `第一话` → `XX 第一话`', () {
      expect(WebDavFolderImporter.collectionBookName('（XX）合集', '第一话'),
          'XX 第一话');
    });

    test('单话名已含合集名时不重复拼接', () {
      expect(WebDavFolderImporter.collectionBookName('XX合集', 'XX 第一话'),
          'XX 第一话');
    });

    test('压缩包子名去扩展名', () {
      expect(WebDavFolderImporter.collectionBookName('XX合集', '第一话.ZIP'),
          'XX 第一话');
    });
  });
}
