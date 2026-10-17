/// 图片"头部"尺寸解析：不解码一个像素就能拿到宽高。
///
/// 这是虚拟长页能工作的基石：
///   PageMetrics 需要每页的 aspectRatio 才能算出总高度，
///   而 aspectRatio 来自宽高，宽高就在文件头部的前几十到几百字节里。
///
/// 配合压缩包的"按需读取"，导入一万页只需解出每页前 ~192KB。
library;

import 'dart:typed_data';

class ImageDimension {
  const ImageDimension(this.width, this.height, this.mimeType);

  final int width;
  final int height;
  final String mimeType;

  double get aspectRatio => height == 0 ? 1.0 : width / height;

  @override
  String toString() => '$mimeType ${width}x$height';
}

class ImageHeaderParser {
  /// 解析失败返回 null —— 说明头部字节不够，调用方可以多解一点再试。
  static ImageDimension? tryParse(Uint8List b) {
    if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return _png(b);
    }
    if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) return _jpeg(b);
    if (b.length >= 30 && _ascii(b, 0, 4) == 'RIFF' && _ascii(b, 8, 4) == 'WEBP') {
      return _webp(b);
    }
    if (b.length >= 10 && _ascii(b, 0, 3) == 'GIF') {
      return ImageDimension(_le16(b, 6), _le16(b, 8), 'image/gif');
    }
    if (b.length >= 26 && _ascii(b, 0, 2) == 'BM') {
      return ImageDimension(_le32(b, 18), _le32(b, 22), 'image/bmp');
    }
    if (b.length >= 8 && _startsWith(b, const [0x00, 0x00, 0x01, 0x00])) {
      return _ico(b);
    }
    if (b.length >= 14 && _ascii(b, 0, 4) == 'qoif') {
      return _qoi(b);
    }
    // ISO-BMFF：AVIF / HEIC —— 在 box 树里找 'ispe'
    if (b.length >= 12 && _ascii(b, 4, 4) == 'ftyp') {
      return _isobmff(b);
    }
    return null;
  }

  // ---------------- ICO ----------------
  // ICONDIR(6) + ICONDIRENTRY(16)：b[6] 宽, b[7] 高（0 表示 256）
  static ImageDimension? _ico(Uint8List b) {
    if (b.length < 8) return null;
    final count = _le16(b, 4);
    if (count <= 0 || b.length < 6 + 16) return null;
    final w = b[6] == 0 ? 256 : b[6];
    final h = b[7] == 0 ? 256 : b[7];
    return ImageDimension(w, h, 'image/x-icon');
  }

  // ---------------- QOI ----------------
  // 'qoif' + width(4 BE) + height(4 BE)
  static ImageDimension? _qoi(Uint8List b) {
    if (b.length < 14) return null;
    return ImageDimension(_be32(b, 4), _be32(b, 8), 'image/qoi');
  }

  // ---------------- ISO-BMFF (AVIF / HEIC) ----------------
  //
  // 结构是一棵 box 树： [size:4][type:4][payload]
  // 尺寸在 'ispe' box 的 payload 里（version/flags 4 字节 + width 4 + height 4）。
  // 这里做一个有界的递归扫描（限制深度与扫描量），
  // 找到第一个 ispe 就返回 —— 对 AVIF/HEIC 都适用。
  static ImageDimension? _isobmff(Uint8List b) {
    final found = _findIspe(b, 0, b.length, 0);
    if (found == null) return null;
    return ImageDimension(found.$1, found.$2, 'image/avif');
  }

  static (int, int)? _findIspe(Uint8List b, int start, int end, int depth) {
    if (depth > 6) return null;
    int p = start;
    while (p + 8 <= end) {
      int size = _be32(b, p);
      final type = _ascii(b, p + 4, 4);
      int headerLen = 8;
      if (size == 1) {
        // 64 位长度：只用低 32 位（图片不会超过 4GB）
        if (p + 16 > end) return null;
        size = _be32(b, p + 12);
        headerLen = 16;
      } else if (size == 0) {
        size = end - p; // 延伸到末尾
      }
      if (size < headerLen || p + size > end) return null;

      if (type == 'ispe') {
        final q = p + headerLen + 4; // 跳过 version/flags
        if (q + 8 <= p + size) {
          final w = _be32(b, q);
          final h = _be32(b, q + 4);
          if (w > 0 && h > 0) return (w, h);
        }
      }

      // 递归进容器 box
      if (type == 'meta' || type == 'iprp' || type == 'ipco' ||
          type == 'moov' || type == 'trak' || type == 'mdia' ||
          type == 'minf' || type == 'stbl' || type == 'iinf' ||
          type == 'pitm' || type == 'iloc' || type == 'moov') {
        // 'meta' box 在 payload 前有 4 字节 version/flags
        final childStart = type == 'meta' ? p + headerLen + 4 : p + headerLen;
        final r = _findIspe(b, childStart, p + size, depth + 1);
        if (r != null) return r;
      }

      p += size;
    }
    return null;
  }

  // ---------------- PNG ----------------
  // 8 字节签名 + 4 字节长度 + 'IHDR' + width(4) + height(4)
  static ImageDimension _png(Uint8List b) =>
      ImageDimension(_be32(b, 16), _be32(b, 20), 'image/png');

  // ---------------- JPEG ----------------
  // 尺寸不在固定偏移，必须遍历 marker 找 SOF0..SOF15（排除 DHT/JPG/DAC）
  static ImageDimension? _jpeg(Uint8List b) {
    int i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      // 无长度字段的 marker
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (marker == 0xDA) return null; // 进入扫描数据，头部已结束
      if (i + 4 > b.length) return null;
      final segLen = _be16(b, i + 2);
      if (segLen < 2) return null;

      final isSof = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 && // DHT
          marker != 0xC8 && // JPG
          marker != 0xCC; // DAC
      if (isSof) {
        if (i + 9 > b.length) return null;
        // SOF: [len:2][precision:1][height:2][width:2]
        return ImageDimension(_be16(b, i + 7), _be16(b, i + 5), 'image/jpeg');
      }
      i += 2 + segLen;
    }
    return null;
  }

  // ---------------- WebP ----------------
  // 三种变体：VP8（有损）/ VP8L（无损）/ VP8X（扩展）
  static ImageDimension? _webp(Uint8List b) {
    if (b.length < 30) return null;
    final fourcc = _ascii(b, 12, 4);
    switch (fourcc) {
      case 'VP8 ':
        // 帧头：3 字节 tag + 3 字节起始码 9D 01 2A + width(2) + height(2)
        if (b.length < 30) return null;
        return ImageDimension(
          _le16(b, 26) & 0x3FFF,
          _le16(b, 28) & 0x3FFF,
          'image/webp',
        );
      case 'VP8L':
        if (b.length < 25) return null;
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return ImageDimension(
          (bits & 0x3FFF) + 1,
          ((bits >> 14) & 0x3FFF) + 1,
          'image/webp',
        );
      case 'VP8X':
        if (b.length < 30) return null;
        int rgb(int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);
        return ImageDimension(rgb(24) + 1, rgb(27) + 1, 'image/webp');
      default:
        return null;
    }
  }

  // ---------------- helpers ----------------
  static String _ascii(Uint8List b, int o, int n) {
    if (o + n > b.length) return '';
    return String.fromCharCodes(b.sublist(o, o + n));
  }

  static bool _startsWith(Uint8List b, List<int> sig) {
    if (b.length < sig.length) return false;
    for (int i = 0; i < sig.length; i++) {
      if (b[i] != sig[i]) return false;
    }
    return true;
  }

  static int _be16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
  static int _be32(Uint8List b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  static int _le16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
  static int _le32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
}
