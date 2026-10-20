import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkscroll/app_version.dart';
import 'package:inkscroll/data/update_service.dart';

void main() {
  group('版本号', () {
    test('kAppVersion 必须与 pubspec.yaml 一致', () {
      // 手写两份版本号必然漂移；这条测试就是为了在漂移时立刻变红。
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
          .firstMatch(pubspec);
      expect(m, isNotNull, reason: 'pubspec.yaml 里没有 version:');
      expect(kAppVersion, m!.group(1),
          reason: '改了 pubspec.yaml 的版本号，也要同步改 lib/app_version.dart');
    });

    test('SemVer 解析各种标签写法', () {
      expect(SemVer.tryParse('v0.7.1'), const SemVer(0, 7, 1));
      expect(SemVer.tryParse('0.7.1'), const SemVer(0, 7, 1));
      expect(SemVer.tryParse('release-1.2.3-beta'), const SemVer(1, 2, 3));
      expect(SemVer.tryParse('没有版本号'), isNull);
    });

    test('比较不能退化成字符串比较', () {
      // 字符串比较会认为 "0.10.0" < "0.9.0" —— 这是最容易踩的坑
      final a = SemVer.tryParse('0.10.0')!;
      final b = SemVer.tryParse('0.9.0')!;
      expect(a > b, isTrue);
      expect(b < a, isTrue);
      expect(a.compareTo(a), 0);
      expect(const SemVer(1, 0, 0) > const SemVer(0, 99, 99), isTrue);
    });
  });

  group('更新源配置', () {
    test('国内镜像排在第一，GitHub 兜底', () {
      expect(kUpdateSources.length, greaterThanOrEqualTo(2));
      expect(kUpdateSources.first.apiUrl, contains('gitcode.com'));
      expect(kUpdateSources.last.apiUrl, contains('github.com'));
    });

    test('每个源都有可手动下载的兜底页面', () {
      for (final s in kUpdateSources) {
        expect(s.fallbackPage, startsWith('https://'));
      }
    });
  });
}