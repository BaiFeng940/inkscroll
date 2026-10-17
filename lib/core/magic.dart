/// 魔术字节识别：用文件头判断真实格式，而不是相信扩展名。
///
/// 现实里经常遇到：
///   - 无扩展名的文件
///   - 扩展名被改成 .zip 其实是 rar
///   - .zip 其实是 docx（docx 就是 zip）
library;

import 'dart:typed_data';

enum ContainerFormat {
  zip,
  rar4,
  rar5,
  sevenZip,
  gzip,
  bzip2,
  xz,
  tar,
  pdf,
  jpeg,
  png,
  webp,
  gif,
  bmp,
  /// ISO-BMFF 家族（ftyp box）：AVIF / HEIC / HEIF / JPEG2000 等
  avif,
  heic,
  jxl,
  tiff,
  ico,
  psd,
  qoi,
  svg,
  docOle,
  plainText,
  html,
  unknown,
}

extension ContainerFormatX on ContainerFormat {
  /// 这个格式能不能当"图片"喂给 Flutter 的 Image 渲染
  bool get isRenderableImage => switch (this) {
        ContainerFormat.jpeg ||
        ContainerFormat.png ||
        ContainerFormat.webp ||
        ContainerFormat.gif ||
        ContainerFormat.bmp ||
        ContainerFormat.avif ||
        ContainerFormat.heic ||
        ContainerFormat.tiff ||
        ContainerFormat.ico =>
          true,
        _ => false,
      };

  /// 能识别但 Flutter 不保证能解码的格式 —— 要单独提示用户
  bool get isKnownButUnsupportedImage => switch (this) {
        ContainerFormat.jxl || ContainerFormat.psd || ContainerFormat.qoi => true,
        _ => false,
      };

  String get label => switch (this) {
        ContainerFormat.jpeg => 'JPEG',
        ContainerFormat.png => 'PNG',
        ContainerFormat.webp => 'WebP',
        ContainerFormat.gif => 'GIF',
        ContainerFormat.bmp => 'BMP',
        ContainerFormat.avif => 'AVIF',
        ContainerFormat.heic => 'HEIC/HEIF',
        ContainerFormat.jxl => 'JPEG XL',
        ContainerFormat.tiff => 'TIFF',
        ContainerFormat.ico => 'ICO',
        ContainerFormat.psd => 'Photoshop PSD',
        ContainerFormat.qoi => 'QOI',
        ContainerFormat.svg => 'SVG',
        _ => name,
      };
}

class MagicDetector {
  static const _zipSignatures = <List<int>>[
    [0x50, 0x4B, 0x03, 0x04], // 普通条目
    [0x50, 0x4B, 0x05, 0x06], // 空压缩包（EOCD）
    [0x50, 0x4B, 0x07, 0x08], // 跨卷
  ];

  static ContainerFormat detect(Uint8List head, {String? filename}) {
    // ---------- 压缩容器 ----------
    for (final sig in _zipSignatures) {
      if (_startsWith(head, sig)) return ContainerFormat.zip;
    }
    if (_startsWith(head, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])) {
      return ContainerFormat.rar4;
    }
    if (_startsWith(head, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])) {
      return ContainerFormat.rar5;
    }
    if (_startsWith(head, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) {
      return ContainerFormat.sevenZip;
    }
    if (_startsWith(head, [0x1F, 0x8B])) return ContainerFormat.gzip;
    if (_startsWith(head, [0x42, 0x5A, 0x68])) return ContainerFormat.bzip2;
    if (_startsWith(head, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) {
      return ContainerFormat.xz;
    }

    // tar: offset 257 处是 "ustar"
    if (head.length >= 263 && _ascii(head, 257, 5) == 'ustar') {
      return ContainerFormat.tar;
    }

    // ---------- 文档 ----------
    if (_startsWith(head, [0x25, 0x50, 0x44, 0x46])) return ContainerFormat.pdf;
    if (_startsWith(head, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) {
      return ContainerFormat.docOle;
    }

    // ---------- 位图 ----------
    if (_startsWith(head, [0xFF, 0xD8, 0xFF])) return ContainerFormat.jpeg;
    if (_startsWith(head, [0x89, 0x50, 0x4E, 0x47])) return ContainerFormat.png;
    if (head.length >= 12 && _ascii(head, 0, 4) == 'RIFF' && _ascii(head, 8, 4) == 'WEBP') {
      return ContainerFormat.webp;
    }
    if (head.length >= 6 && _ascii(head, 0, 3) == 'GIF') return ContainerFormat.gif;
    if (head.length >= 2 && _ascii(head, 0, 2) == 'BM') return ContainerFormat.bmp;
    if (_startsWith(head, [0x00, 0x00, 0x01, 0x00])) return ContainerFormat.ico;
    if (_startsWith(head, [0x38, 0x42, 0x50, 0x53])) return ContainerFormat.psd; // '8BPS'
    if (head.length >= 4 &&
        (head[0] == 0x49 && head[1] == 0x49 && head[2] == 0x2A && head[3] == 0x00 ||
            head[0] == 0x4D && head[1] == 0x4D && head[2] == 0x00 && head[3] == 0x2A)) {
      return ContainerFormat.tiff;
    }
    if (head.length >= 2 && head[0] == 0xFF && head[1] == 0x0A) return ContainerFormat.jxl;
    if (_startsWith(head, [0x71, 0x6F, 0x69, 0x66])) return ContainerFormat.qoi; // 'qoif'
    if (head.length >= 4 && _ascii(head, 0, 4) == 'qoif') return ContainerFormat.qoi;

    // ---------- ISO-BMFF（ftyp box）：AVIF / HEIC / HEIF ----------
    // 结构：[size:4]['ftyp'][major_brand:4][minor_version:4][compatible_brands...]
    if (head.length >= 12 && _ascii(head, 4, 4) == 'ftyp') {
      final brand = _ascii(head, 8, 4).toLowerCase();
      final brands = <String>[brand];
      // 兼容品牌列表也一起看，很多设备写 'mif1' 但实际是 HEIC
      for (int i = 16; i + 4 <= head.length && i < 64; i += 4) {
        brands.add(_ascii(head, i, 4).toLowerCase());
      }
      bool has(String prefix) => brands.any((b) => b.startsWith(prefix));
      if (has('avif') || has('avis')) return ContainerFormat.avif;
      if (has('heic') || has('heix') || has('hevc') || has('hevx') ||
          has('heim') || has('heis') || has('mif1') || has('msf1')) {
        return ContainerFormat.heic;
      }
      // 其他 ftyp（mp4/mov…）不算图片
      return ContainerFormat.unknown;
    }

    // ---------- SVG：是文本，交给文本分支 ----------
    // （在下面的 looksLikeText 里处理）

    // ---------- 文本兜底（必须放最后） ----------
    if (looksLikeText(head)) {
      if (looksLikeSvg(head)) return ContainerFormat.svg;
      return looksLikeHtml(head) ? ContainerFormat.html : ContainerFormat.plainText;
    }
    return ContainerFormat.unknown;
  }

  /// SVG 是纯文本，只能靠内容特征识别
  static bool looksLikeSvg(Uint8List b) {
    final n = b.length > 2048 ? 2048 : b.length;
    final s = String.fromCharCodes(b.sublist(0, n)).toLowerCase();
    return s.contains('<svg') || (s.contains('<?xml') && s.contains('svg'));
  }

  /// 判断一个 zip 是否是 docx（docx = zip + 特定内部结构）
  static bool looksLikeDocx(List<String> entryPaths) =>
      entryPaths.contains('[Content_Types].xml') &&
      entryPaths.contains('word/document.xml');

  /// 判断一个 zip 是否是 epub
  static bool looksLikeEpub(List<String> entryPaths) =>
      entryPaths.contains('META-INF/container.xml') &&
      entryPaths.any((p) => p.endsWith('.opf'));

  static bool looksLikeText(Uint8List b) {
    final n = b.length > 4096 ? 4096 : b.length;
    if (n == 0) return false;
    int control = 0;
    for (int i = 0; i < n; i++) {
      final c = b[i];
      if (c == 0) return false; // 含 NUL → 二进制
      if (c < 0x09 || (c > 0x0D && c < 0x20)) control++;
    }
    return control / n < 0.02;
  }

  static bool looksLikeHtml(Uint8List b) {
    final n = b.length > 2048 ? 2048 : b.length;
    final s = String.fromCharCodes(b.sublist(0, n)).toLowerCase();
    return s.contains('<!doctype html') ||
        s.contains('<html') ||
        s.contains('<head') ||
        s.contains('<body') ||
        s.contains('<meta charset');
  }

  static bool _startsWith(Uint8List b, List<int> sig) {
    if (b.length < sig.length) return false;
    for (int i = 0; i < sig.length; i++) {
      if (b[i] != sig[i]) return false;
    }
    return true;
  }

  static String _ascii(Uint8List b, int offset, int length) {
    if (offset + length > b.length) return '';
    return String.fromCharCodes(b.sublist(offset, offset + length));
  }
}
