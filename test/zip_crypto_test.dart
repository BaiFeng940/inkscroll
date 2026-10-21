// ZipCrypto 解密的回归测试。
//
// 没有 7-Zip 可用，所以这里**自己实现一个加密器**来构造合法密文：
// ZipCrypto 是流密码，加解密共用同一套密钥流，因此用同一份算法
// 就能双向验证。这比"找个样本碰运气"更可靠，也能覆盖错误密码的路径。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkscroll/data/archive/zip_crypto.dart';

/// 测试用的加密器（与 [ZipCrypto] 对称）。
class _Encryptor {
  _Encryptor(String password) {
    for (final b in password.codeUnits) {
      _update(b & 0xff);
    }
  }

  int _k0 = 0x12345678;
  int _k1 = 0x23456789;
  int _k2 = 0x34567890;

  static final List<int> _table = () {
    final t = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1);
      }
      t[i] = c & 0xffffffff;
    }
    return t;
  }();

  static int _crc(int crc, int b) =>
      ((crc >> 8) & 0x00ffffff) ^ _table[(crc ^ b) & 0xff];

  void _update(int b) {
    _k0 = _crc(_k0, b);
    _k1 = ((_k1 + (_k0 & 0xff)) * 134775813 + 1) & 0xffffffff;
    _k2 = _crc(_k2, (_k1 >> 24) & 0xff);
  }

  int _stream() {
    final temp = (_k2 | 2) & 0xffff;
    return ((temp * (temp ^ 1)) >> 8) & 0xff;
  }

  Uint8List encrypt(Uint8List plain) {
    final out = Uint8List(plain.length);
    for (var i = 0; i < plain.length; i++) {
      final p = plain[i];
      out[i] = p ^ _stream();
      _update(p);
    }
    return out;
  }
}

void main() {
  group('ZipCrypto 解密', () {
    test('加密 → 解密可还原（含 12 字节加密头）', () {
      const password = 'manga123';
      // 12 字节头 + 正文，模拟真实条目的布局
      final header = Uint8List.fromList(List.generate(12, (i) => 0xA0 + i));
      final body =
          Uint8List.fromList(List.generate(200, (i) => (i * 7 + 3) & 0xff));
      final plain = Uint8List.fromList([...header, ...body]);

      final enc = _Encryptor(password).encrypt(plain);

      // 解密侧从密码重建密钥流，解出的头部要丢掉
      final dec = ZipCrypto.withPassword(password)!.decrypt(enc);
      expect(dec.sublist(ZipCrypto.headerSize), body);
    });

    test('空密码返回 null（视为没有密码）', () {
      expect(ZipCrypto.withPassword(null), isNull);
      expect(ZipCrypto.withPassword(''), isNull);
    });

    test('错误密码解出来的内容是错的（能被上层识别失败）', () {
      const right = 'manga123';
      final body = Uint8List.fromList(List.generate(64, (i) => i));
      final plain = Uint8List.fromList([...List.filled(12, 0), ...body]);
      final enc = _Encryptor(right).encrypt(plain);

      final wrong = ZipCrypto.withPassword('wrong-pass')!
          .decrypt(enc)
          .sublist(ZipCrypto.headerSize);
      expect(wrong, isNot(equals(body)));
    });

    test('长数据也要正确（跨多次密钥更新）', () {
      const password = 'a-longer-password-2026';
      final body =
          Uint8List.fromList(List.generate(64 * 1024, (i) => (i * 31) & 0xff));
      final plain = Uint8List.fromList([...List.filled(12, 0x5A), ...body]);
      final enc = _Encryptor(password).encrypt(plain);
      final dec = ZipCrypto.withPassword(password)!.decrypt(enc);
      expect(dec.sublist(12), body);
    });
  });
}
