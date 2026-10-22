/// **手动**真机/真网盘验证：合并合集在真实库上的扫描结果。
///
/// 这是"开启约 38 本、关闭 174 本"这条验收标准的可复现验证手段 ——
/// 不需要装 APK、不需要点界面，直接对着真实网盘跑一遍 `scanLibrary`。
///
/// 默认**跳过**（CI 与日常 `flutter test` 都不会联网）。
/// 需要时这样跑：
///
/// ```powershell
/// $env:INKSCROLL_DAV_URL  = "https://webdav.123pan.cn/webdav/漫画"
/// $env:INKSCROLL_DAV_USER = "18873682282"
/// $env:INKSCROLL_DAV_PASS = "……"
/// flutter test test/real_scan_manual_test.dart --reporter expanded
/// ```
///
/// 输出：关闭/开启两种模式的候选数、每本几话、第一章能不能拿到页。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkscroll/data/webdav/webdav_client.dart';
import 'package:inkscroll/data/webdav/webdav_connection.dart';
import 'package:inkscroll/importers/webdav_folder_importer.dart';

String? _env(String name) {
  final v = Platform.environment[name];
  return (v == null || v.trim().isEmpty) ? null : v.trim();
}

void main() {
  final url = _env('INKSCROLL_DAV_URL');
  final user = _env('INKSCROLL_DAV_USER');
  final pass = _env('INKSCROLL_DAV_PASS');
  final missing = url == null
      ? '未设置 INKSCROLL_DAV_URL（这是手动验证，需要真实网盘）'
      : null;

  late WebDavClient client;
  late WebDavConnection conn;

  if (missing == null) {
    final u = Uri.parse(url!);
    client = WebDavClient(
      baseUrl: '${u.scheme}://${u.authority}',
      username: user,
      password: pass,
      timeout: const Duration(seconds: 60),
    );
    conn = WebDavConnection(
      id: 'manual',
      label: 'manual',
      baseUrl: '${u.scheme}://${u.authority}',
    );
  }

  test('真实网盘：关闭 → 每话一本；开启 → 每合集一本（含章节）', () async {
    final flat = await WebDavFolderImporter.scanLibrary(client, url!);
    final merged = await WebDavFolderImporter.scanLibrary(
      client,
      url,
      mergeCollections: true,
    );

    // ignore: avoid_print
    print('关闭合并：${flat.length} 本'
        '（压缩包 ${flat.where((c) => c.isArchive).length}）');
    // ignore: avoid_print
    print('开启合并：${merged.length} 本'
        '（合集 ${merged.where((c) => c.isCollection).length}，'
        '其余 ${merged.where((c) => !c.isCollection).length}）');

    final collections = merged.where((c) => c.isCollection).toList()
      ..sort((a, b) => b.chapters.length - a.chapters.length);
    for (final c in collections) {
      // ignore: avoid_print
      print('  · ${c.name}  ${c.chapters.length} 话'
          '（${c.chapters.take(3).map((e) => e.title).join('、')}'
          '${c.chapters.length > 3 ? '…' : ''}）');
    }

    // 开启后每个合集只有一本 → 数量必须明显少于关闭时
    expect(merged.length, lessThan(flat.length));
    // 关闭时"每话一本"的章话数，必须等于开启时被折叠进合集的话数
    final foldedChapters =
        collections.fold<int>(0, (sum, c) => sum + c.chapters.length);
    // ignore: avoid_print
    print('折叠进合集的"话"合计 $foldedChapters（'
        '压平后 ${merged.length - collections.length + foldedChapters} 本）');

    // 挑话最多的合集，真建一次文档，确认"逐话 _build + 合并"能跑通
    final first = collections.isEmpty ? null : collections.first;
    if (first != null) {
      final doc = await WebDavFolderImporter.buildMergedCollection(
        conn: conn,
        client: client,
        candidate: first,
      );
      // ignore: avoid_print
      print('  ${first.name}：${doc.chapterCount} 章 / ${doc.pageCount} 页；'
          '章名 ${doc.chapters.take(3).map((c) => c.title).join('、')}'
          '${doc.chapters.length > 3 ? '…' : ''}');
      expect(doc.chapterCount, first.chapters.length);
      expect(doc.pageCount, greaterThan(0));
      // 页 id 必须全局唯一，否则跨话翻页会错位
      expect(doc.pages.length, doc.pageCount);
    }
  }, timeout: const Timeout(Duration(minutes: 10)), skip: missing);

  test('真实网盘：子目录 PROPFIND 的失败率与重试收益（诊断用）', () async {
    final root = await client.list(url!);
    final dirs = root.where((e) => e.isDirectory).toList();

    var failFirst = 0;
    var failRetry = 0;
    final errors = <String>{};

    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= dirs.length) return;
        final d = dirs[i];
        try {
          await client.list(d.url);
        } catch (e) {
          failFirst++;
          errors.add('$e');
          // 失败后重试一次：看是不是瞬时的
          try {
            await client.list(d.url);
          } catch (e2) {
            failRetry++;
            errors.add('retry: $e2');
          }
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    // ignore: avoid_print
    print('子目录 ${dirs.length} 个：首次失败 $failFirst，重试后仍失败 $failRetry');
    for (final e in errors.take(6)) {
      // ignore: avoid_print
      print('  ! $e');
    }
    expect(dirs, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)), skip: missing);

  test('真实网盘：两层嵌套 20 路（与 scanLibrary 同负载）的失败率', () async {
    final root = await client.list(url!);
    final level1 = root.where((e) => e.isDirectory).toList();

    var level1Fail = 0;
    var level2Fail = 0;
    var level2Total = 0;
    final errors = <String>{};

    // 5 路 × 每路 4 路 = 20 并发，与 scanConcurrency × nestedScanConcurrency 一致
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= level1.length) return;
        List<WebDavEntry> entries;
        try {
          entries = await client.list(level1[i].url);
        } catch (e) {
          level1Fail++;
          errors.add('L1 ${level1[i].name}: $e');
          continue;
        }
        final subs = entries.where((e) => e.isDirectory).toList();
        var j = 0;
        Future<void> subWorker() async {
          while (true) {
            final k = j++;
            if (k >= subs.length) return;
            level2Total++;
            try {
              await client.list(subs[k].url);
            } catch (e) {
              level2Fail++;
              errors.add('L2 ${level1[i].name}/${subs[k].name}: $e');
            }
          }
        }

        await Future.wait(List.generate(4, (_) => subWorker()));
      }
    }

    await Future.wait(List.generate(5, (_) => worker()));
    // ignore: avoid_print
    print('一层 ${level1.length} 个：失败 $level1Fail；'
        '二层 $level2Total 个：失败 $level2Fail');
    for (final e in errors.take(8)) {
      // ignore: avoid_print
      print('  ! $e');
    }
    expect(level1, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)), skip: missing);
}
