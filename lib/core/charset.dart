/// 文本编码探测 + 解码。
///
/// 起步实现走"零依赖"路线，覆盖 UTF-8 / UTF-16 / UTF-32（含 BOM）：
///   ① BOM 最可靠，直接定案
///   ② UTF-8 严格校验（多字节序列一旦违规立刻否定）
///   ③ 都不匹配 → 报出"疑似 GBK"，让上层提示用户
///
/// GBK / GB2312 / Big5 的接入点见本文件末尾 [decodeLegacy]。
library;

import 'dart:convert';
import 'dart:typed_data';

enum EncodingDetectionMethod { bom, utf8Validation, asciiOnly, fallback }

class CharsetResult {
  const CharsetResult(this.encoding, {required this.method, this.confidence = 1.0});

  final String encoding; // 'utf-8' | 'utf-16le' | 'utf-16be' | 'utf-32le' | 'utf-32be'
  final EncodingDetectionMethod method;
  final double confidence;

  bool get isUtf8 => encoding == 'utf-8';

  @override
  String toString() => '$encoding (${method.name}, ${confidence.toStringAsFixed(2)})';
}

class CharsetDetector {
  /// 采样上限：512KB 足够判定，没必要读整个文件
  static const int sampleBytes = 512 * 1024;

  static CharsetResult detect(Uint8List sample) {
    final bom = _detectBom(sample);
    if (bom != null) return bom;

    if (_isValidUtf8(sample)) {
      final asciiOnly = sample.every((b) => b < 0x80);
      return CharsetResult(
        'utf-8',
        method: asciiOnly
            ? EncodingDetectionMethod.asciiOnly
            : EncodingDetectionMethod.utf8Validation,
        confidence: asciiOnly ? 0.7 : 0.97,
      );
    }

    // 非合法 UTF-8。可能是 GBK / GB18030 / Big5 / Latin-1。
    // 起步阶段不内置 GBK 解码表，降级为 UTF-8 容错解码并给出低置信度，
    // 上层 UI 据此提示"疑似 GBK 编码"。
    return const CharsetResult(
      'utf-8',
      method: EncodingDetectionMethod.fallback,
      confidence: 0.3,
    );
  }

  /// 按探测结果解码。allowMalformed 保证不会抛异常中断导入。
  static String decode(Uint8List bytes, CharsetResult result) {
    return decodeLegacy(bytes, result.encoding);
  }

  static String decodeLegacy(Uint8List bytes, String encoding) {
    switch (encoding) {
      case 'utf-8':
        return utf8.decode(bytes, allowMalformed: true);
      case 'utf-16le':
        return _decodeUtf16(bytes, littleEndian: true);
      case 'utf-16be':
        return _decodeUtf16(bytes, littleEndian: false);
      case 'utf-32le':
        return _decodeUtf32(bytes, littleEndian: true);
      case 'utf-32be':
        return _decodeUtf32(bytes, littleEndian: false);
      default:
        // ── P2 接入点 ──────────────────────────────────────────────
        // GBK / GB18030 / Big5:  pubspec 里加 fast_gbk 后：
        //   import 'package:fast_gbk/fast_gbk.dart';
        //   if (encoding == 'gb18030') return gbk.decode(bytes);
        // 或用 charset_converter（走平台原生，更准但有异步成本）：
        //   return await CharsetConverter.decode(encoding, bytes);
        // ──────────────────────────────────────────────────────────
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// 判断一段文本是不是"看起来像中文小说"。
  /// 用于给用户提示"这个文件的编码可能不对"。
  static double cjkRatio(String text) {
    if (text.isEmpty) return 0;
    int cjk = 0;
    int considered = 0;
    for (final r in text.runes) {
      if (r < 0x20) continue;
      considered++;
      if ((r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3000 && r <= 0x303F) ||
          (r >= 0xFF00 && r <= 0xFFEF)) {
        cjk++;
      }
    }
    return considered == 0 ? 0 : cjk / considered;
  }

  // ------------------------------------------------------------------

  static CharsetResult? _detectBom(Uint8List b) {
    if (b.length >= 4) {
      if (b[0] == 0xFF && b[1] == 0xFE && b[2] == 0x00 && b[3] == 0x00) {
        return const CharsetResult('utf-32le', method: EncodingDetectionMethod.bom);
      }
      if (b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xFE && b[3] == 0xFF) {
        return const CharsetResult('utf-32be', method: EncodingDetectionMethod.bom);
      }
    }
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
      return const CharsetResult('utf-8', method: EncodingDetectionMethod.bom);
    }
    if (b.length >= 2) {
      if (b[0] == 0xFF && b[1] == 0xFE) {
        return const CharsetResult('utf-16le', method: EncodingDetectionMethod.bom);
      }
      if (b[0] == 0xFE && b[1] == 0xFF) {
        return const CharsetResult('utf-16be', method: EncodingDetectionMethod.bom);
      }
    }
    // UTF-8 BOM 的字节有时只被读进来 2 个（分块边界）
    if (b.length == 2 && b[0] == 0xEF && b[1] == 0xBB) {
      return const CharsetResult('utf-8', method: EncodingDetectionMethod.bom);
    }
    return null;
  }

  /// 严格的 UTF-8 合法性校验（不是 decode + allowMalformed，那永远成功）
  static bool _isValidUtf8(Uint8List b) {
    int i = 0;
    final n = b.length;
    while (i < n) {
      final c = b[i];
      if (c < 0x80) {
        i++;
        continue;
      }
      int extra;
      int min;
      int max;
      if (c >= 0xC2 && c <= 0xDF) {
        extra = 1;
        min = 0x80;
        max = 0xBF;
      } else if (c >= 0xE0 && c <= 0xEF) {
        extra = 2;
        min = 0x80;
        max = 0xBF;
      } else if (c >= 0xF0 && c <= 0xF4) {
        extra = 3;
        min = 0x80;
        max = 0xBF;
      } else {
        return false; // 0x80-0xC1 / 0xF5-0xFF 在 UTF-8 里非法
      }
      if (i + extra >= n) return true; // 采样在字符中间截断，按合法处理
      for (int k = 1; k <= extra; k++) {
        final cc = b[i + k];
        if (cc < 0x80 || cc > 0xBF) return false;
      }
      // 额外检查首字节的第二字节约束（防止过长编码）
      final c1 = b[i + 1];
      if (c == 0xE0 && c1 < 0xA0) return false;
      if (c == 0xED && c1 > 0x9F) return false;
      if (c == 0xF0 && c1 < 0x90) return false;
      if (c == 0xF4 && c1 > 0x8F) return false;
      i += extra + 1;
      // 只校验这些就够了；min/max 仅作说明用途
      assert(min <= max);
    }
    return true;
  }

  static String _decodeUtf16(Uint8List b, {required bool littleEndian}) {
    // 跳过 BOM
    int start = 0;
    if (b.length >= 2) {
      if ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF)) start = 2;
    }
    final end = b.length - ((b.length - start) % 2);
    final codeUnits = <int>[];
    for (int i = start; i < end; i += 2) {
      codeUnits.add(littleEndian ? (b[i] | (b[i + 1] << 8)) : ((b[i] << 8) | b[i + 1]));
    }
    return String.fromCharCodes(codeUnits);
  }

  static String _decodeUtf32(Uint8List b, {required bool littleEndian}) {
    int start = 0;
    if (b.length >= 4) start = 4; // BOM
    final end = b.length - ((b.length - start) % 4);
    final runes = <int>[];
    for (int i = start; i < end; i += 4) {
      runes.add(littleEndian
          ? (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24))
          : ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]));
    }
    return String.fromCharCodes(runes);
  }
}
