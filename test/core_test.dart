import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:inkscroll/core/errors.dart';
import 'package:inkscroll/core/image_header.dart';
import 'package:inkscroll/core/magic.dart';
import 'package:inkscroll/core/natural_sort.dart';
import 'package:inkscroll/data/archive/zip_archive_source.dart';
import 'package:inkscroll/data/byte_source.dart';
import 'package:inkscroll/importers/import_utils.dart';
import 'package:inkscroll/reader/document.dart';

void main() {
  group('自然排序（漫画文件名的重灾区）', () {
    test('数字按数值比较，不是字典序', () {
      final names = ['10.jpg', '2.jpg', '1.jpg', '20.jpg', '3.jpg'];
      names.sort(NaturalComparator.compare);
      expect(names, ['1.jpg', '2.jpg', '3.jpg', '10.jpg', '20.jpg']);
    });

    test('中文标题里的数字同样生效', () {
      final names = ['第10话', '第2话', '第1话'];
      names.sort(NaturalComparator.compare);
      expect(names, ['第1话', '第2话', '第10话']);
    });

    test('数值相同：前导零少的优先', () {
      expect(NaturalComparator.compare('1.jpg', '01.jpg'), lessThan(0));
    });

    test('多段数字逐段比较', () {
      expect(NaturalComparator.compare('a2b10', 'a10b2'), lessThan(0));
    });

    test('★ 逐段比较路径，避免跨目录错位', () {
      // 直接比较整串 '第1话/10.jpg' vs '第10话/1.jpg' 会得到错误顺序
      final paths = ['第10话/1.jpg', '第1话/10.jpg', '第1话/2.jpg'];
      paths.sort(NaturalComparator.comparePath);
      expect(paths, ['第1话/2.jpg', '第1话/10.jpg', '第10话/1.jpg']);
    });

    test('超长数字不溢出（不转 int）', () {
      const a = '99999999999999999999.jpg';
      const b = '100000000000000000000.jpg';
      expect(NaturalComparator.compare(a, b), lessThan(0));
    });
  });

  group('魔术字节识别（不能信扩展名）', () {
    test('识别 zip / rar / 7z / pdf / gif', () {
      expect(MagicDetector.detect(_bytes([0x50, 0x4B, 0x03, 0x04])),
          ContainerFormat.zip);
      expect(MagicDetector.detect(_bytes([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])),
          ContainerFormat.rar5);
      expect(MagicDetector.detect(_bytes([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])),
          ContainerFormat.sevenZip);
      expect(MagicDetector.detect(_bytes([0x25, 0x50, 0x44, 0x46])),
          ContainerFormat.pdf);
      expect(MagicDetector.detect(_bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
          ContainerFormat.png);
    });
  });

  group('图片头部尺寸解析（不解码像素）', () {
    test('PNG：读 IHDR 的宽高', () {
      final png = _pngHeader(width: 1080, height: 2400);
      final dim = ImageHeaderParser.tryParse(png);
      expect(dim, isNotNull);
      expect(dim!.width, 1080);
      expect(dim.height, 2400);
      expect(dim.mimeType, 'image/png');
      expect(dim.aspectRatio, closeTo(1080 / 2400, 1e-9));
    });

    test('JPEG：必须遍历 marker 找到 SOF0', () {
      final jpeg = _jpegHeader(width: 800, height: 1200);
      final dim = ImageHeaderParser.tryParse(jpeg);
      expect(dim, isNotNull);
      expect(dim!.width, 800);
      expect(dim.height, 1200);
    });

    test('GIF：读逻辑屏幕尺寸', () {
      final gif = _bytes([
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
        0x40, 0x01, // width = 320 (LE)
        0xF0, 0x00, // height = 240 (LE)
        0x00, 0x00, 0x00,
      ]);
      final dim = ImageHeaderParser.tryParse(gif);
      expect(dim!.width, 320);
      expect(dim.height, 240);
    });

    test('头部不足时返回 null（调用方可以多解一点再试）', () {
      expect(ImageHeaderParser.tryParse(_bytes([0x89, 0x50])), isNull);
    });

    // ---- 新增格式：这些是"文件夹导入找不到图片"最常见的漏网之鱼 ----

    test('ICO：读 ICONDIRENTRY 的宽高', () {
      final ico = _bytes([
        0x00, 0x00, 0x01, 0x00, // ICONDIR
        0x01, 0x00, // count = 1
        0x40, 0x40, // width=64, height=64
        0x00, 0x00, 0x01, 0x00, // colors, reserved, planes
        0x20, 0x00, // bpp
        0x00, 0x00, 0x00, 0x00, // size
        0x16, 0x00, 0x00, 0x00, // offset
      ]);
      final dim = ImageHeaderParser.tryParse(ico);
      expect(dim, isNotNull);
      expect(dim!.width, 64);
      expect(dim.height, 64);
    });

    test('ICO：宽高为 0 表示 256', () {
      final ico = _bytes([
        0x00, 0x00, 0x01, 0x00,
        0x01, 0x00,
        0x00, 0x00, // 0 → 256
        0x00, 0x00, 0x01, 0x00,
        0x20, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x16, 0x00, 0x00, 0x00,
      ]);
      final dim = ImageHeaderParser.tryParse(ico);
      expect(dim!.width, 256);
      expect(dim.height, 256);
    });

    test('QOI：读 qoif 头部的宽高（大端）', () {
      final qoi = _bytes([
        0x71, 0x6F, 0x69, 0x66, // 'qoif'
        ..._be32(1920),
        ..._be32(1080),
        0x04, 0x00, // channels, colorspace
      ]);
      final dim = ImageHeaderParser.tryParse(qoi);
      expect(dim, isNotNull);
      expect(dim!.width, 1920);
      expect(dim.height, 1080);
    });

    test('★ AVIF/HEIC：在 ISO-BMFF box 树里找到 ispe', () {
      final heic = _isobmffWithIspe(
        majorBrand: 'heic',
        compatibleBrands: ['mif1', 'heic'],
        width: 4032,
        height: 3024,
      );
      final dim = ImageHeaderParser.tryParse(heic);
      expect(dim, isNotNull, reason: 'HEIC 的 ispe 解析必须成功');
      expect(dim!.width, 4032);
      expect(dim.height, 3024);

      final avif = _isobmffWithIspe(
        majorBrand: 'avif',
        compatibleBrands: ['avif', 'mif1'],
        width: 1280,
        height: 720,
      );
      final dim2 = ImageHeaderParser.tryParse(avif);
      expect(dim2, isNotNull);
      expect(dim2!.width, 1280);
      expect(dim2.height, 720);
    });

    test('ISO-BMFF 里没有 ispe 时返回 null（不瞎猜）', () {
      final mp4 = _bytes([
        ..._be32(24), ..._ascii('ftyp'), ..._ascii('isom'),
        ..._be32(512), ..._ascii('isom'), ..._ascii('mp41'),
      ]);
      expect(ImageHeaderParser.tryParse(mp4), isNull);
    });
  });

  group('★ 按内容识别文件类型（不依赖扩展名）', () {
    test('识别各种图片格式的魔数', () {
      expect(
        MagicDetector.detect(_bytes([0xFF, 0xD8, 0xFF, 0xE0])),
        ContainerFormat.jpeg,
      );
      expect(
        MagicDetector.detect(_bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
        ContainerFormat.png,
      );
      expect(
        MagicDetector.detect(_bytes([0x00, 0x00, 0x01, 0x00, 0x01, 0x00])),
        ContainerFormat.ico,
      );
      expect(
        MagicDetector.detect(_bytes([0xFF, 0x0A, 0x00, 0x00])),
        ContainerFormat.jxl,
      );
      expect(
        MagicDetector.detect(_bytes([0x38, 0x42, 0x50, 0x53, 0x00, 0x01])),
        ContainerFormat.psd,
      );
      expect(
        MagicDetector.detect(_bytes([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00])),
        ContainerFormat.tiff,
      );
      expect(
        MagicDetector.detect(_bytes([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00])),
        ContainerFormat.tiff,
      );
      expect(
        MagicDetector.detect(_bytes([0x71, 0x6F, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1])),
        ContainerFormat.qoi,
      );
    });

    test('★ 区分 AVIF 与 HEIC（两者都是 ftyp box）', () {
      final avif = _isobmffWithIspe(
        majorBrand: 'avif',
        compatibleBrands: ['avif', 'mif1'],
        width: 100,
        height: 100,
      );
      expect(MagicDetector.detect(avif), ContainerFormat.avif);

      final heic = _isobmffWithIspe(
        majorBrand: 'heic',
        compatibleBrands: ['mif1', 'heic'],
        width: 100,
        height: 100,
      );
      expect(MagicDetector.detect(heic), ContainerFormat.heic);

      // 有些设备只写 mif1，实际是 HEIC
      final mif1 = _isobmffWithIspe(
        majorBrand: 'mif1',
        compatibleBrands: ['mif1'],
        width: 100,
        height: 100,
      );
      expect(MagicDetector.detect(mif1), ContainerFormat.heic);
    });

    test('mp4 不会被误判成图片', () {
      final mp4 = _bytes([
        ..._be32(24), ..._ascii('ftyp'), ..._ascii('isom'),
        ..._be32(512), ..._ascii('isom'), ..._ascii('mp41'),
      ]);
      expect(MagicDetector.detect(mp4), ContainerFormat.unknown);
    });

    test('SVG 被识别为文本类（Flutter 不能直接渲染）', () {
      final svg = _bytes(_ascii('<svg xmlns="http://www.w3.org/2000/svg"></svg>'));
      final fmt = MagicDetector.detect(svg);
      expect(fmt, ContainerFormat.svg);
      expect(fmt.isRenderableImage, isFalse);
    });

    test('canRender / knownUnsupported 分类正确', () {
      expect(ContainerFormat.jpeg.isRenderableImage, isTrue);
      expect(ContainerFormat.heic.isRenderableImage, isTrue);
      expect(ContainerFormat.avif.isRenderableImage, isTrue);
      expect(ContainerFormat.tiff.isRenderableImage, isTrue);
      expect(ContainerFormat.ico.isRenderableImage, isTrue);

      expect(ContainerFormat.jxl.isKnownButUnsupportedImage, isTrue);
      expect(ContainerFormat.psd.isKnownButUnsupportedImage, isTrue);
      expect(ContainerFormat.qoi.isKnownButUnsupportedImage, isTrue);

      expect(ContainerFormat.jpeg.label, 'JPEG');
      expect(ContainerFormat.heic.label, 'HEIC/HEIF');
    });
  });

  group('★ 虚拟长页度量（PageLayoutMetrics）', () {
    test('总高度 = 逐页宽度/比例 的累加，无缝无间距', () {
      final pages = [
        _page('a', 2.0), // 1080 / 2.0 = 540
        _page('b', 1.0), // 1080 / 1.0 = 1080
        _page('c', 0.5), // 1080 / 0.5 = 2160
      ];
      final m = PageLayoutMetrics.build(pages: pages, viewportWidth: 1080);

      expect(m.heights[0], closeTo(540, 1e-6));
      expect(m.heights[1], closeTo(1080, 1e-6));
      expect(m.heights[2], closeTo(2160, 1e-6));
      expect(m.totalHeight, closeTo(3780, 1e-6));
      expect(m.tops, [0, 540, 1620]);
    });

    test('像素 → 页码 的二分查找正确', () {
      final pages = [_page('a', 2.0), _page('b', 1.0), _page('c', 0.5)];
      final m = PageLayoutMetrics.build(pages: pages, viewportWidth: 1080);

      expect(m.pageAt(0), 0);
      expect(m.pageAt(539), 0);
      expect(m.pageAt(540), 1); // 第二页顶部
      expect(m.pageAt(1619), 1);
      expect(m.pageAt(1620), 2); // 第三页顶部
      expect(m.pageAt(99999), 2); // 越界夹到最后
    });

    test('百分比与像素可双向换算（进度条拖动跳转的基础）', () {
      final pages = [_page('a', 2.0), _page('b', 1.0)];
      final m = PageLayoutMetrics.build(pages: pages, viewportWidth: 1080);

      expect(m.offsetForRatio(0.0), 0);
      expect(m.offsetForRatio(1.0), closeTo(m.totalHeight, 1e-6));
      expect(m.ratioAt(m.totalHeight / 2), closeTo(0.5, 1e-6));

      // 往返换算应回到原位置
      const y = 800.0;
      expect(m.offsetForRatio(m.ratioAt(y)), closeTo(y, 1e-6));
    });

    test('★ 锚点：页 + 页内比例（横竖屏切换保位用）', () {
      final pages = [_page('a', 2.0), _page('b', 1.0)];
      final m = PageLayoutMetrics.build(pages: pages, viewportWidth: 1080);

      // 第一页 540 高，y=270 → 页内比例 0.5
      expect(m.ratioInPage(0, 270), closeTo(0.5, 1e-6));

      // 宽度翻倍后，用同一锚点还原
      final m2 = PageLayoutMetrics.build(pages: pages, viewportWidth: 2160);
      final restored = m2.pixelFor(0, 0.5);
      expect(restored, closeTo(m2.heights[0] * 0.5, 1e-6));
      expect(m2.heights[0], closeTo(1080, 1e-6)); // 540 * 2
    });

    test('未知比例使用兜底值，不会产生 0 或 Infinity', () {
      final pages = [_page('a', null), _page('b', double.nan), _page('c', 0)];
      final m = PageLayoutMetrics.build(pages: pages, viewportWidth: 1080);
      for (final h in m.heights) {
        expect(h.isFinite, isTrue);
        expect(h, greaterThan(0));
      }
    });

    test('pageAt 在空列表上不崩', () {
      final m = PageLayoutMetrics.build(pages: const [], viewportWidth: 1080);
      expect(m.pageAt(100), 0);
      expect(m.totalHeight, 0);
    });
  });

  group('ZIP 中央目录解析（真的按需读取）', () {
    test('能列出条目、读出内容，且不整包解码', () async {
      final zipBytes = _buildStoredZip({
        '第01话/001.jpg': [1, 2, 3, 4, 5],
        '第01话/002.jpg': [6, 7, 8],
        'readme.txt': _ascii('hello'),
      });

      final src = MemoryByteSource(zipBytes);
      final zip = ZipArchiveSource(src);
      await zip.open();

      final names = zip.entries.map((e) => e.entryPath).toList();
      expect(names, containsAll(['第01话/001.jpg', '第01话/002.jpg', 'readme.txt']));
      expect(zip.entries.length, 3);

      // 按需读第一个条目
      final first = zip.entries.firstWhere((e) => e.entryPath == '第01话/001.jpg');
      final data = await zip.readEntry(first);
      expect(data, [1, 2, 3, 4, 5]);

      // ★ maxBytes：只解出前 2 字节就停手
      final head = await zip.readEntry(first, maxBytes: 2);
      expect(head, [1, 2]);

      await zip.close();
    });

    test('zip bomb 保护：声明大小超过上限时拒绝', () async {
      final zipBytes = _buildStoredZip({
        'huge.bin': List<int>.filled(64, 0),
      });
      final src = MemoryByteSource(zipBytes);
      // 把上限设得比条目还小
      final zip = ZipArchiveSource(src, maxEntryBytes: 16);
      await zip.open();

      final entry = zip.entries.firstWhere((e) => e.entryPath == 'huge.bin');
      expect(() => zip.readEntry(entry), throwsA(isA<PayloadTooLargeError>()));

      await zip.close();
    });

    test('★ 路径穿越被规范化（../ 与绝对路径）', () async {
      final zipBytes = _buildStoredZip({
        '../../etc/passwd': [1],
        '/abs/evil.txt': [2],
      });
      final src = MemoryByteSource(zipBytes);
      final zip = ZipArchiveSource(src);
      await zip.open();

      for (final e in zip.entries) {
        expect(e.entryPath.contains('..'), isFalse);
        expect(e.entryPath.startsWith('/'), isFalse);
      }
      await zip.close();
    });
  });

  group('并发工具 mapConcurrent（导入加速的基础）', () {
    test('保持输入顺序，即使任务完成顺序不同', () async {
      final items = List.generate(50, (i) => i);
      final out = await mapConcurrent<int, int>(
        items,
        concurrency: 8,
        task: (i) async {
          // 故意让靠前的任务更慢，验证结果仍按输入顺序排列
          await Future<void>.delayed(Duration(milliseconds: (50 - i) % 7));
          return i * 2;
        },
      );
      expect(out, items.map((i) => i * 2).toList());
    });

    test('并发数受限于 concurrency（不会同时开无限个任务）', () async {
      int inFlight = 0;
      int peak = 0;
      await mapConcurrent<int, void>(
        List.generate(40, (i) => i),
        concurrency: 4,
        task: (i) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
        },
      );
      expect(peak, lessThanOrEqualTo(4));
      expect(peak, greaterThan(1)); // 确认真的并发了，而不是退化成串行
    });

    test('onProgress 恰好回调 N 次', () async {
      int calls = 0;
      await mapConcurrent<int, int>(
        List.generate(13, (i) => i),
        concurrency: 3,
        task: (i) async => i,
        onProgress: (_) => calls++,
      );
      expect(calls, 13);
    });

    test('空输入不崩', () async {
      final out = await mapConcurrent<int, int>(
        const [],
        task: (i) async => i,
      );
      expect(out, isEmpty);
    });

    test('单个任务抛异常时向上传播', () async {
      expect(
        () => mapConcurrent<int, int>(
          [1, 2, 3],
          concurrency: 2,
          task: (i) async {
            if (i == 2) throw StateError('boom');
            return i;
          },
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('文件夹导入的诊断能力（修 "识别不了图片" 的关键）', () {
    test('content:// 地址给出明确的 SAF 提示，而不是静默失败', () async {
      await expectLater(
        ensureReadableDirectory('content://com.android.externalstorage.documents/tree/primary'),
        throwsA(
          isA<AppError>().having(
            (e) => e.message,
            'message',
            contains('content://'),
          ),
        ),
      );
    });

    test('不存在的目录给出"不存在或无法访问"而不是空结果', () async {
      await expectLater(
        ensureReadableDirectory('/definitely/not/here/xyz123'),
        throwsA(
          isA<AppError>().having(
            (e) => e.message,
            'message',
            contains('不存在'),
          ),
        ),
      );
    });

    test('真实目录能通过预检，并统计到条目数', () async {
      final tmp = await Directory.systemTemp.createTemp('inkscroll_test_');
      try {
        await File('${tmp.path}/a.jpg').writeAsBytes([0xFF, 0xD8, 0xFF]);
        await File('${tmp.path}/b.txt').writeAsString('hi');
        await Directory('${tmp.path}/sub').create();
        await File('${tmp.path}/sub/c.png').writeAsBytes([0x89, 0x50]);

        await ensureReadableDirectory(tmp.path); // 不应抛异常

        final r = await collectFiles(tmp, maxDepth: 8);
        expect(r.files.length, 3);
        expect(r.entriesSeen, greaterThanOrEqualTo(3));
        expect(r.truncated, isFalse);

        final images = r.files.where((f) => isImagePath(f.path)).toList();
        expect(images.length, 2); // a.jpg + sub/c.png
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('深度超限的文件被计数而非静默丢弃', () async {
      final tmp = await Directory.systemTemp.createTemp('inkscroll_depth_');
      try {
        var dir = tmp;
        for (int i = 0; i < 4; i++) {
          dir = await Directory('${dir.path}/d$i').create();
        }
        await File('${dir.path}/deep.jpg').writeAsBytes([0xFF, 0xD8, 0xFF]);

        final shallow = await collectFiles(tmp, maxDepth: 1);
        expect(shallow.files, isEmpty);
        expect(shallow.skippedByDepth, 1);

        final deep = await collectFiles(tmp, maxDepth: 8);
        expect(deep.files.length, 1);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

PageNode _page(String id, double? aspect) => PageNode(
      id: id,
      kind: PageKind.image,
      aspectRatio: aspect,
      content: ImageContent(ref: LooseFileRef('/tmp/$id.jpg')),
    );

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

List<int> _ascii(String s) => s.codeUnits;

/// 造一个最小 PNG 头（签名 + IHDR）
Uint8List _pngHeader({required int width, required int height}) {
  final b = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // 签名
    0x00, 0x00, 0x00, 0x0D, // IHDR 长度 = 13
    0x49, 0x48, 0x44, 0x52, // 'IHDR'
  ];
  b.addAll(_be32(width));
  b.addAll(_be32(height));
  b.addAll([0x08, 0x06, 0x00, 0x00, 0x00]); // bitDepth/colorType/...
  b.addAll(_be32(0)); // CRC 占位
  return Uint8List.fromList(b);
}

/// 造一个最小 JPEG 头：FFD8 + APP0 + SOF0
Uint8List _jpegHeader({required int width, required int height}) {
  final b = <int>[0xFF, 0xD8];
  // APP0 (len=16)
  b.addAll([0xFF, 0xE0, 0x00, 0x10]);
  b.addAll(_ascii('JFIF\x00'));
  b.addAll([0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]);
  // SOF0: [FF C0][len=17][precision=8][height:2][width:2][comps...]
  b.addAll([0xFF, 0xC0, 0x00, 0x11, 0x08]);
  b.addAll(_be16(height));
  b.addAll(_be16(width));
  b.addAll([0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
  // SOS 起始（让解析器可以在这里停下）
  b.addAll([0xFF, 0xDA]);
  return Uint8List.fromList(b);
}

List<int> _be16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
List<int> _be32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

/// 构造一个含 'ispe' box 的 ISO-BMFF（HEIC / AVIF）文件头。
///
/// 真实结构是 ftyp + meta(iprp(ipco(ispe))) 的嵌套，
/// 这里按规范把嵌套层级原样搭出来，用来验证解析器的递归扫描。
///
/// 尺寸由 'ispe' 的 payload 携带：跳过 version/flags(4) 之后是 width(4) + height(4)。
Uint8List _isobmffWithIspe({
  required String majorBrand,
  required List<String> compatibleBrands,
  required int width,
  required int height,
}) {
  // ispe box: [size][type]['ispe'][version+flags:4][width:4][height:4]
  final ispePayload = <int>[
    0x00, 0x00, 0x00, 0x00, // version + flags
    ..._be32(width),
    ..._be32(height),
  ];
  final ispe = <int>[
    ..._be32(8 + ispePayload.length),
    ..._ascii('ispe'),
    ...ispePayload,
  ];

  // ipco box 直接包住 ispe
  final ipco = <int>[
    ..._be32(8 + ispe.length),
    ..._ascii('ipco'),
    ...ispe,
  ];

  // iprp box 包住 ipco
  final iprp = <int>[
    ..._be32(8 + ipco.length),
    ..._ascii('iprp'),
    ...ipco,
  ];

  // meta box：payload 前面有 4 字节 version/flags
  final metaPayload = <int>[
    0x00, 0x00, 0x00, 0x00,
    ...iprp,
  ];
  final meta = <int>[
    ..._be32(8 + metaPayload.length),
    ..._ascii('meta'),
    ...metaPayload,
  ];

  // ftyp box: [size]['ftyp'][major][minor][compatible...]
  final ftypPayload = <int>[
    ..._ascii(majorBrand.padRight(4).substring(0, 4)),
    ..._be32(0), // minor version
    for (final b in compatibleBrands)
      ..._ascii(b.padRight(4).substring(0, 4)),
  ];
  final ftyp = <int>[
    ..._be32(8 + ftypPayload.length),
    ..._ascii('ftyp'),
    ...ftypPayload,
  ];

  return Uint8List.fromList([...ftyp, ...meta]);
}

/// 构造一个只用 STORE（不压缩）的最小 ZIP。
///
/// 用 STORE 是为了让测试不依赖 DEFLATE 实现，
/// 同时正好覆盖 ZipArchiveSource 的 STORE 分支。
Uint8List _buildStoredZip(Map<String, List<int>> files) {
  final local = <int>[];
  final central = <int>[];
  final offsets = <String, int>{};

  files.forEach((name, content) {
    final nameBytes = _utf8(name);
    offsets[name] = local.length;

    // ---- Local file header ----
    local.addAll(_le32(0x04034B50));
    local.addAll(_le16(20)); // version needed
    local.addAll(_le16(0x0800)); // flag: bit 11 = UTF-8 文件名
    local.addAll(_le16(0)); // method = STORE
    local.addAll(_le16(0)); // mod time
    local.addAll(_le16(0)); // mod date
    local.addAll(_le32(_crc32(content)));
    local.addAll(_le32(content.length)); // compressed size
    local.addAll(_le32(content.length)); // uncompressed size
    local.addAll(_le16(nameBytes.length));
    local.addAll(_le16(0)); // extra len
    local.addAll(nameBytes);
    local.addAll(content);
  });

  final cdStart = local.length;

  files.forEach((name, content) {
    final nameBytes = _utf8(name);
    // ---- Central directory header ----
    central.addAll(_le32(0x02014B50));
    central.addAll(_le16(20)); // version made by
    central.addAll(_le16(20)); // version needed
    central.addAll(_le16(0x0800)); // flag
    central.addAll(_le16(0)); // method = STORE
    central.addAll(_le16(0)); // mod time
    central.addAll(_le16(0)); // mod date
    central.addAll(_le32(_crc32(content)));
    central.addAll(_le32(content.length));
    central.addAll(_le32(content.length));
    central.addAll(_le16(nameBytes.length));
    central.addAll(_le16(0)); // extra
    central.addAll(_le16(0)); // comment
    central.addAll(_le16(0)); // disk number
    central.addAll(_le16(0)); // internal attrs
    central.addAll(_le32(0)); // external attrs
    central.addAll(_le32(offsets[name]!));
    central.addAll(nameBytes);
  });

  final cdSize = central.length;
  final out = <int>[...local, ...central];

  // ---- EOCD ----
  out.addAll(_le32(0x06054B50));
  out.addAll(_le16(0)); // disk
  out.addAll(_le16(0)); // disk with CD
  out.addAll(_le16(files.length)); // entries on this disk
  out.addAll(_le16(files.length)); // total entries
  out.addAll(_le32(cdSize));
  out.addAll(_le32(cdStart));
  out.addAll(_le16(0)); // comment len

  return Uint8List.fromList(out);
}

List<int> _utf8(String s) {
  final out = <int>[];
  for (final r in s.runes) {
    if (r < 0x80) {
      out.add(r);
    } else if (r < 0x800) {
      out.add(0xC0 | (r >> 6));
      out.add(0x80 | (r & 0x3F));
    } else if (r < 0x10000) {
      out.add(0xE0 | (r >> 12));
      out.add(0x80 | ((r >> 6) & 0x3F));
      out.add(0x80 | (r & 0x3F));
    } else {
      out.add(0xF0 | (r >> 18));
      out.add(0x80 | ((r >> 12) & 0x3F));
      out.add(0x80 | ((r >> 6) & 0x3F));
      out.add(0x80 | (r & 0x3F));
    }
  }
  return out;
}

/// 标准 CRC-32（ZIP 用）
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte & 0xFF;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
