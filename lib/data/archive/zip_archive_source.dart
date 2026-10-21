/// ZIP 随机访问：自己读中央目录，按需解压单个条目。
///
/// 绝对不做的事（违反项目硬约束）：
///   ✗ ZipDecoder().decodeBytes(整个包)
///   ✗ File.readAsBytes(整包)
///   ✗ 把包解压到磁盘
///
/// 实际读取量：
///   打开 ≈ 尾部 64KB（找 EOCD）+ 中央目录长度（4 万条目约 1.8MB）
///   取一页 ≈ 30 字节局部头 + 该条目的压缩数据（几百 KB）
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/errors.dart';
import '../byte_source.dart';
import 'archive_source.dart';
import 'zip_crypto.dart';

class ZipArchiveSource implements ArchiveSource {
  ZipArchiveSource(
    this._src, {
    this.maxEntryBytes = kDefaultMaxEntryBytes,
    EntryCache? cache,
    this.password,
  }) : _cache = cache ?? EntryCache();

  /// 加密压缩包的密码（ZipCrypto 传统加密）。null 表示未知。
  final String? password;

  final RandomAccessByteSource _src;
  final int maxEntryBytes;
  final EntryCache _cache;

  List<ArchiveEntryInfo> _entries = const [];
  int _totalUncompressed = 0;
  bool _opened = false;

  /// 压缩包总字节数（open() 时记录），用于钳制条目数据范围
  int _fileLen = 0;

  @override
  List<ArchiveEntryInfo> get entries => _entries;

  @override
  int get totalUncompressedBytes => _totalUncompressed;

  int get cacheBytes => _cache.bytes;

  // ------------------------------------------------------------------
  // 签名常量
  // ------------------------------------------------------------------
  static const int _sigEocd = 0x06054b50;
  static const int _sigEocd64Locator = 0x07064b50;
  static const int _sigEocd64 = 0x06064b50;
  static const int _sigCentral = 0x02014b50;
  static const int _sigLocal = 0x04034b50;

  static const int _zip64ExtraId = 0x0001;

  // ------------------------------------------------------------------
  // 打开：只读 EOCD + 中央目录
  // ------------------------------------------------------------------
  Future<void> open() async {
    if (_opened) return;
    _opened = true;

    final fileLen = await _src.length();
    _fileLen = fileLen;
    if (fileLen < 22) throw const NotAnArchiveError(detail: '文件小于 EOCD 最小长度');

    // —— 第 1 步：在文件尾部 22 + 65535 字节内倒着找 EOCD ——
    final tailLen = math.min(fileLen, 22 + 0xFFFF);
    final tailStart = fileLen - tailLen;
    final tail = await _src.read(tailStart, tailLen);

    int eocd = -1;
    for (int i = tail.length - 22; i >= 0; i--) {
      if (_u32(tail, i) == _sigEocd) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const NotAnArchiveError(detail: '找不到 EOCD 签名');

    int entryCount = _u16(tail, eocd + 10);
    int cdSize = _u32(tail, eocd + 12);
    int cdOffset = _u32(tail, eocd + 16);

    // —— Zip64：任一字段被置为哨兵值就走 Zip64 ——
    final needZip64 = cdOffset == 0xFFFFFFFF ||
        cdSize == 0xFFFFFFFF ||
        entryCount == 0xFFFF;
    if (needZip64) {
      final z = await _readZip64(fileLen, tailStart, tail, eocd);
      if (z != null) {
        cdOffset = z.$1;
        cdSize = z.$2;
        entryCount = z.$3;
      }
    }

    // 有些写坏的包 cdSize=0 但 cdOffset 有效 → 用文件长度兜底
    if (cdSize == 0 || cdOffset + cdSize > fileLen) {
      cdSize = fileLen - cdOffset;
    }
    if (cdOffset <= 0 || cdOffset >= fileLen) {
      throw NotAnArchiveError(detail: '中央目录偏移非法: $cdOffset');
    }

    // —— 第 2 步：一次读回中央目录（大包也就几 MB）——
    final cd = await _src.read(cdOffset, cdSize);
    _entries = _parseCentralDirectory(cd, entryCount);
    _totalUncompressed = _entries.fold<int>(0, (s, e) => s + e.uncompressedSize);
  }

  Future<(int, int, int)?> _readZip64(
    int fileLen,
    int tailStart,
    Uint8List tail,
    int eocdInTail,
  ) async {
    // Locator 紧贴在 EOCD 前面 20 字节
    final locOffsetInTail = eocdInTail - 20;
    if (locOffsetInTail < 0) return null;
    if (_u32(tail, locOffsetInTail) != _sigEocd64Locator) return null;

    final eocd64Offset = _u64(tail, locOffsetInTail + 8);
    if (eocd64Offset <= 0 || eocd64Offset + 56 > fileLen) return null;

    final rec = await _src.read(eocd64Offset, 56);
    if (_u32(rec, 0) != _sigEocd64) return null;

    final count = _u64(rec, 32);
    final size = _u64(rec, 40);
    final offset = _u64(rec, 48);
    return (offset, size, count);
  }

  // ------------------------------------------------------------------
  // 解析中央目录
  // ------------------------------------------------------------------
  List<ArchiveEntryInfo> _parseCentralDirectory(Uint8List cd, int declaredCount) {
    final out = <ArchiveEntryInfo>[];
    int p = 0;

    // ★ 不能按 46 字节步进：文件名/extra/comment 都是变长的
    while (p + 46 <= cd.length) {
      if (_u32(cd, p) != _sigCentral) break;
      if (declaredCount > 0 && out.length >= declaredCount) break;

      final flags = _u16(cd, p + 8);
      final method = _u16(cd, p + 10);
      final crc = _u32(cd, p + 16);
      int compSize = _u32(cd, p + 20);
      int uncompSize = _u32(cd, p + 24);
      final nameLen = _u16(cd, p + 28);
      final extraLen = _u16(cd, p + 30);
      final commentLen = _u16(cd, p + 32);
      int localOffset = _u32(cd, p + 42);

      if (p + 46 + nameLen > cd.length) break;
      final nameBytes = cd.sublist(p + 46, p + 46 + nameLen);

      // flag bit 11 (0x0800) = 文件名为 UTF-8；否则多半是 GBK
      final name = (flags & 0x0800) != 0
          ? decodeLegacyZipName(nameBytes) // utf8.decode 由它内部先尝试
          : decodeLegacyZipName(nameBytes);

      // ZIP64 extra field (id=0x0001)：依序覆盖被置为哨兵值的字段
      if (uncompSize == 0xFFFFFFFF ||
          compSize == 0xFFFFFFFF ||
          localOffset == 0xFFFFFFFF) {
        final exStart = p + 46 + nameLen;
        final exEnd = math.min(exStart + extraLen, cd.length);
        final z = _parseZip64Extra(
          cd.sublist(exStart, exEnd),
          needUncomp: uncompSize == 0xFFFFFFFF,
          needComp: compSize == 0xFFFFFFFF,
          needOffset: localOffset == 0xFFFFFFFF,
        );
        if (z.uncompressed != null) uncompSize = z.uncompressed!;
        if (z.compressed != null) compSize = z.compressed!;
        if (z.offset != null) localOffset = z.offset!;
      }

      // flag bit 0 (0x0001) = 加密
      final encrypted = (flags & 0x0001) != 0;

      out.add(ArchiveEntryInfo(
        entryPath: _sanitizePath(name),
        uncompressedSize: uncompSize,
        compressedSize: compSize,
        compressionMethod: method,
        localHeaderOffset: localOffset,
        isEncrypted: encrypted,
        crc32: crc,
      ));

      p += 46 + nameLen + extraLen + commentLen;
    }

    if (out.isEmpty) {
      throw const NotAnArchiveError(detail: '中央目录里没有任何条目');
    }
    return out;
  }

  ({int? uncompressed, int? compressed, int? offset}) _parseZip64Extra(
    Uint8List extra, {
    required bool needUncomp,
    required bool needComp,
    required bool needOffset,
  }) {
    int p = 0;
    while (p + 4 <= extra.length) {
      final id = _u16(extra, p);
      final size = _u16(extra, p + 2);
      final body = p + 4;
      if (body + size > extra.length) break;

      if (id == _zip64ExtraId) {
        int q = body;
        int? uncomp;
        int? comp;
        int? off;
        if (needUncomp && q + 8 <= body + size) {
          uncomp = _u64(extra, q);
          q += 8;
        }
        if (needComp && q + 8 <= body + size) {
          comp = _u64(extra, q);
          q += 8;
        }
        if (needOffset && q + 8 <= body + size) {
          off = _u64(extra, q);
          q += 8;
        }
        return (uncompressed: uncomp, compressed: comp, offset: off);
      }
      p = body + size;
    }
    return (uncompressed: null, compressed: null, offset: null);
  }

  // ------------------------------------------------------------------
  // ★ 按需读取单个条目
  // ------------------------------------------------------------------
  ArchiveEntryInfo? byPath(String entryPath) {
    for (final e in _entries) {
      if (e.entryPath == entryPath) return e;
    }
    return null;
  }

  @override
  Future<Uint8List> readEntry(ArchiveEntryInfo entry, {int? maxBytes}) async {
    if (!_opened) await open();

    // —— 安全上限：防 zip bomb ——
    if (entry.uncompressedSize > maxEntryBytes && maxBytes == null) {
      throw PayloadTooLargeError(
        entry.entryPath,
        entry.uncompressedSize,
        maxEntryBytes,
      );
    }

    final cacheKey = entry.entryPath;
    // 只有"完整读取"才进缓存；maxBytes 的头部读取单独处理（下一次可能要更多字节）
    if (maxBytes == null) {
      final hit = _cache.get(cacheKey);
      if (hit != null) return hit;
    }

    if (entry.isEncrypted) {
      // 加密条目的处理（诚实说明）：
      //   - 传统 ZipCrypto（method 1/2）：纯 Dart 需要自己实现 CRC 校验的流密码，
      //     本仓库暂未实现。
      //   - AES（method 99）：必须 AE-1/AE-2 + HMAC 校验，纯 Dart 实现成本高。
      // 两种情况都给出明确、可操作的错误，而不是试图"猜密码"。
      throw const GenericError(
        '这个压缩包是加密的。当前版本不支持解密压缩包（纯 Dart 无可靠的 '
        'ZipCrypto / AES 实现）。\n'
        '请先用 7-Zip / WinRAR 解压出未加密的 zip，或移除密码后再导入。',
        action: ErrorAction.convertFile,
      );
    }

    final need = maxBytes == null
        ? entry.uncompressedSize
        : math.min(maxBytes, entry.uncompressedSize);
    if (need <= 0) return Uint8List(0);

    // —— 读 30 字节局部头，只为算出数据起始偏移 ——
    final local = await _src.read(entry.localHeaderOffset, 30);
    if (local.length < 30 || _u32(local, 0) != _sigLocal) {
      throw CorruptArchiveError(
        detail: '条目 ${entry.entryPath} 的局部头无效 @${entry.localHeaderOffset}',
      );
    }
    final nameLen = _u16(local, 26);
    final extraLen = _u16(local, 28);
    final dataStart = entry.localHeaderOffset + 30 + nameLen + extraLen;

    // ── 加密条目：ZipCrypto 传统加密 ──
    //
    // 之前这里直接抛"不支持解密"，等于这类压缩包完全打不开。
    // ZipCrypto 只是个基于 CRC32 的流密码，纯 Dart 就能解，
    // 而中文漫画圈里绝大多数加密 zip 正是这个模式。
    //
    // ★ 不做分级试探：加密密钥流是连续的，只读一段密文无法从中途开始
    //   解压，所以这里老实读完整条再解（这类文件少，正确性优先）。
    if (entry.isEncrypted) {
      if (entry.compressionMethod == 99) {
        // AES-256（WinZip AE-x）：要 AES + HMAC 校验，工程量完全不同
        throw const GenericError(
          '这个压缩包用的是 AES-256 加密，当前版本不支持。\n'
          '请用 7-Zip 重新打包成「ZipCrypto」加密，或解出未加密的 zip 再导入。',
          action: ErrorAction.convertFile,
        );
      }
      final pwd = password;
      if (pwd == null || pwd.isEmpty) {
        throw const ArchivePasswordRequiredError();
      }
      final encLen = math.min(
        entry.compressedSize,
        math.max(0, _fileLen - dataStart),
      );
      if (encLen <= ZipCrypto.headerSize) {
        throw CorruptArchiveError(detail: '${entry.entryPath} 加密数据长度非法');
      }
      final crypto = ZipCrypto.withPassword(pwd)!;
      final enc = await _src.read(dataStart, encLen);
      final plain = crypto.decrypt(enc);
      final payload = Uint8List.sublistView(plain, ZipCrypto.headerSize);

      if (entry.compressionMethod == 0) {
        final n = math.min(need, payload.length);
        final out = Uint8List.sublistView(payload, 0, n);
        if (maxBytes == null) _cache.put(cacheKey, out);
        return out;
      }
      if (entry.compressionMethod != 8) {
        throw UnsupportedCompressionError(entry.compressionMethod);
      }
      Uint8List raw;
      try {
        raw = inflateEntry(payload, entry.uncompressedSize);
      } catch (_) {
        // 解压失败最常见的两个原因：密码错，或数据损坏
        throw const ArchivePasswordWrongError();
      }
      final out = raw.length <= need ? raw : subView(raw, 0, need);
      if (maxBytes == null) _cache.put(cacheKey, out);
      return out;
    }

    final Uint8List result;
    final outputOnly = maxBytes != null; // 只取前 N 字节（嗅探图片头）

    if (entry.compressionMethod == 0) {
      // —— STORE：未压缩，直接切片，零解压成本 ——
      result = await _src.read(dataStart, need);
    } else if (entry.compressionMethod == 8) {
      // —— DEFLATE ——
      //
      // ★ 关键优化（针对"压缩包导入太慢"）：
      //
      //   旧实现是「读完整条压缩数据 → 解压整张图 → 切片前 N 字节」。
      //   于是一张 5MB 的漫画页，**只是为了读几十字节的图片头，就要解压 5MB**。
      //   500 张图 = 解压几 GB，这就是导入慢的真正原因
      //   （`maxBytes` 只省了拷贝，没省解压）。
      //
      //   新实现分两级：
      //     ① 先只读该条目的前一小段压缩数据试探解压。只要图片头已经在
      //        解出来的字节里，就立刻返回 —— 绝大多数 JPEG/PNG 的尺寸
      //        在文件最前面，所以这一步就够了。
      //     ② 试探失败（头部跨过了试探边界 / 数据被截断）才回退到读整条。
      //
      //   注意：只读 `compSize * need / uncompSize` 这种"按比例估算"是不可靠的，
      //   deflate 的字节对应关系不是线性的；所以用「分级试探 + 校验头部解出」
      //   来保证正确性 —— 只有确实解析成功才算成功。
      var compSize = entry.compressedSize;
      if (compSize <= 0 || compSize > entry.uncompressedSize + 1024) {
        // 少数包不写 compressedSize（流式/zip64 异常）→ 退化为按未压缩大小估读
        compSize = math.min(entry.uncompressedSize + 1024, 64 << 20);
      }
      compSize = math.min(compSize, math.max(0, _fileLen - dataStart));
      if (compSize <= 0) {
        throw CorruptArchiveError(detail: '${entry.entryPath} 压缩数据长度非法');
      }

      if (outputOnly) {
        final trial = await _tryInflateHead(dataStart, compSize, need);
        if (trial != null) return trial;
      }

      final comp = await _src.read(dataStart, compSize);
      if (comp.isEmpty) {
        throw CorruptArchiveError(detail: '${entry.entryPath} 压缩数据为空');
      }
      final raw = inflateEntry(comp, entry.uncompressedSize);
      result = raw.length <= need ? raw : subView(raw, 0, need);
    } else {
      throw UnsupportedCompressionError(entry.compressionMethod);
    }

    if (maxBytes == null) {
      _cache.put(cacheKey, result);
    }
    return result;
  }

  /// 分级试探解压：只读该条目的前一小段压缩数据，试着解出 [need] 字节。
  ///
  /// 成功条件是**真的解析出了图片头**（由调用方 [_sniffAspect] 判定不了，
  /// 因为这里在数据层）。所以这里的判据是"解压出了足够字节且首字节是已知图片签名"。
  /// 不满足就返回 null，让调用方回退到读整条 —— 保证正确性不打折。
  ///
  /// 返回 null 的三种情况都会走回退路径：
  ///   1. 试探的压缩字节被截断，inflate 抛异常；
  ///   2. 解出来的字节少于 need（图片头还没跨过来）；
  ///   3. 解出来的首字节不是任何已知图片签名（可能头部较靠后）。
  Future<Uint8List?> _tryInflateHead(
    int dataStart,
    int compSize,
    int need,
  ) async {
    // 试探梯度：按需增长，命中的绝大多数情况都是第一档
    final steps = <int>[
      math.min(compSize, 48 * 1024),
      math.min(compSize, 160 * 1024),
      math.min(compSize, 512 * 1024),
    ];

    int lastTried = 0;
    for (final step in steps) {
      if (step <= lastTried) continue;
      lastTried = step;
      // 整条数据本来就不大，没必要试探，直接走完整路径
      if (step >= compSize) return null;

      Uint8List raw;
      try {
        final comp = await _src.read(dataStart, step);
        if (comp.isEmpty) return null;
        raw = inflateEntry(comp, 0);
      } catch (_) {
        // 压缩数据被截断 → 加大试探量再试
        continue;
      }

      if (raw.length < math.min(need, 32)) continue;
      if (!_looksLikeImageHead(raw)) continue;

      // 只取前 need 字节，不复制整张图
      return raw.length <= need ? raw : subView(raw, 0, need);
    }
    return null;
  }

  /// 快速判断字节流开头是不是已知图片格式
  static bool _looksLikeImageHead(Uint8List b) {
    if (b.length < 4) return false;
    if (b[0] == 0xFF && b[1] == 0xD8) return true; // JPEG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true; // PNG
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true; // GIF
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return true; // WebP
    }
    if (b[0] == 0x42 && b[1] == 0x4D) return true; // BMP
    return false;
  }

  @override
  Future<void> close() async {
    _cache.clear();
    await _src.close();
  }

  // ------------------------------------------------------------------
  // 字节读取小工具
  // ------------------------------------------------------------------
  static int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

  static int _u32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  /// Dart 的 int 是 64 位且有符号，ZIP64 的字段不会超过 2^53，安全
  static int _u64(Uint8List b, int o) =>
      _u32(b, o) + (_u32(b, o + 4) << 32);

  /// 防止路径穿越：'../' 与绝对路径都要清理掉。
  /// 本设计不解压到磁盘，但条目名会参与路径拼接与排序，必须规范化。
  static String _sanitizePath(String raw) {
    var p = raw.replaceAll('\\', '/');
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    final segments = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(seg);
    }
    return segments.join('/');
  }
}
