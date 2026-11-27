// 「打开时回到上次阅读位置」设置的序列化与兼容性。
//
// 0.15.4 及更早的设置 JSON 里没有 resumeLastPosition 这个键：
// 老用户升级后必须保持默认开启，不能因为解析缺键就关掉续读。
import 'package:flutter_test/flutter_test.dart';
import 'package:inkscroll/data/models/reader_settings.dart';

void main() {
  group('resumeLastPosition 设置', () {
    test('默认开启', () {
      expect(const ReaderSettings().resumeLastPosition, isTrue);
    });

    test('JSON 往返保留开/关状态', () {
      const on = ReaderSettings(resumeLastPosition: true);
      const off = ReaderSettings(resumeLastPosition: false);
      expect(
        ReaderSettings.fromJson(on.toJson()).resumeLastPosition,
        isTrue,
      );
      expect(
        ReaderSettings.fromJson(off.toJson()).resumeLastPosition,
        isFalse,
      );
    });

    test('copyWith 只改这一个开关', () {
      const base = ReaderSettings(
        reserveTopInset: false,
        keepScreenOn: false,
      );
      final toggled = base.copyWith(resumeLastPosition: false);
      expect(toggled.resumeLastPosition, isFalse);
      expect(toggled.reserveTopInset, isFalse);
      expect(toggled.keepScreenOn, isFalse);
      expect(toggled.copyWith(resumeLastPosition: true).resumeLastPosition,
          isTrue);
    });

    test('0.15.4 旧设置 JSON（缺键）→ 默认开启', () {
      // 0.15.4 真实存档的键集合，不含 resumeLastPosition
      final legacyJson = Map<String, dynamic>.from(
        const ReaderSettings().toJson(),
      )..remove('resumeLastPosition');
      expect(legacyJson.containsKey('resumeLastPosition'), isFalse);
      expect(
        ReaderSettings.fromJson(legacyJson).resumeLastPosition,
        isTrue,
      );
    });
  });
}
