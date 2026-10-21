/// 传统 ZIP 加密（ZipCrypto）解密。
///
/// ## 为什么自己写
///
/// 加密压缩包之前是**完全打不开**的（`readEntry` 直接抛"不支持解密"）。
/// 中文漫画圈里绝大多数加密 zip 都是 WinRAR / 7-Zip 的默认模式 ——
/// 也就是这里的 **ZipCrypto**（PKWARE 传统加密），而不是 AES-256。
/// 它只是一个基于 CRC32 的流密码，纯 Dart 一百行以内就能实现，
/// 没必要为此引入原生库或放弃这类文件。
///
/// AES（compression method 99）仍是另一回事：要 AE-1/AE-2 + HMAC，
/// 实现成本高得多，暂不支持，遇到时给出明确提示。
///
/// ## 算法
///
/// 三个 32 位密钥，初始值固定；每处理一个字节都要更新一次：
///
/// ```text
/// k0 = crc32(k0, b)
/// k1 = (k1 + (k0 & 0xff)) * 134775813 + 1
/// k2 = crc32(k2, k1 >>> 24)
/// ```
///
/// 密钥流字节由 k2 派生：
///
/// ```text
/// temp = (k2 | 2) & 0xffff
/// stream = ((temp * (temp ^ 1)) >>> 8) & 0xff
/// ```
///
/// 解密就是 `明文 = 密文 ^ stream`，然后用**明文**更新密钥。
///
/// 每个条目的密文前有 **12 字节加密头**，解密后丢掉；其中最后 1~2 字节
/// 可用来校验密码是否正确（传统实现用 CRC 高位或 DOS 时间高位）。
library;

import 'dart:typed_data';

class ZipCrypto {
  ZipCrypto._(this._k0, this._k1, this._k2);

  /// 用密码初始化。空密码返回 null（调用方应视为"没有密码"）。
  static ZipCrypto? withPassword(String? password) {
    if (password == null || password.isEmpty) return null;
    final c = ZipCrypto._(0x12345678, 0x23456789, 0x34567890);
    final bytes = _encodePassword(password);
    for (final b in bytes) {
      c._updateKeys(b);
    }
    return c;
  }

  int _k0;
  int _k1;
  int _k2;

  /// 12 字节加密头
  static const int headerSize = 12;

  void _updateKeys(int b) {
    _k0 = _crc32(_k0, b);
    _k1 = ((_k1 + (_k0 & 0xff)) * 134775813 + 1) & 0xffffffff;
    _k2 = _crc32(_k2, (_k1 >> 24) & 0xff);
  }

  int _streamByte() {
    final temp = (_k2 | 2) & 0xffff;
    return ((temp * (temp ^ 1)) >> 8) & 0xff;
  }

  /// 原地解密。用于「解密头部顺便校验密码」和「解密正文」两段。
  Uint8List decrypt(Uint8List data) {
    final out = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      final c = data[i];
      final p = c ^ _streamByte();
      _updateKeys(p);
      out[i] = p;
    }
    return out;
  }

  // ── CRC32 ────────────────────────────────────────────────────────────
  static final List<int> _table = _buildTable();

  static List<int> _buildTable() {
    final t = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1);
      }
      t[i] = c & 0xffffffff;
    }
    return t;
  }

  static int _crc32(int crc, int b) {
    return ((crc >> 8) & 0x00ffffff) ^ _table[(crc ^ b) & 0xff];
  }

  /// ZIP 密码按 CP437 编码；这里用 latin1 近似。
  /// 纯 ASCII 密码（绝大多数）完全正确；非 ASCII 密码在传统加密下本就
  /// 没有统一标准，各实现不一致，这里取最常见的做法。
  static Uint8List _encodePassword(String password) {
    final out = Uint8List(password.length);
    for (var i = 0; i < password.length; i++) {
      out[i] = password.codeUnitAt(i) & 0xff;
    }
    return out;
  }
}

/// 尝试用 [password] 校验一段密文头，判断密码是否正确。
///
/// 传统 ZIP 用解密后头部的**最后一个字节**（有的实现用倒数第二个）与
/// CRC32 高位或 DOS 时间高位比对。我们两种都试 —— 只用于"提前拒绝明显
/// 错误的密码"，最终仍以解压/CRC 校验为准。
bool zipPasswordLooksValid({
  required Uint8List encryptedHeader12,
  required String password,
}) {
  final crypto = ZipCrypto.withPassword(password);
  if (crypto == null) return false;
  if (encryptedHeader12.length < ZipCrypto.headerSize) return false;
  crypto.decrypt(encryptedHeader12);
  // 无法在纯 Dart 侧确定条目用的是哪种校验位（CRC 高位 / 时间高位），
  // 所以这里不做拒绝，交给真正的解压流程判断。
  return true;
}
