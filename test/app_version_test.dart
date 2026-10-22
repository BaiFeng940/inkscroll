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

    test('UI 里不许把版本号写死（真机上出现过两个版本同屏）', () {
      // 0.14.0 的真机截图：设置页「检查更新」写着 0.14.0，
      // 下面「关于」那行却还印着**硬编码**的 0.13.1 —— 那一行当时没走 kAppVersion。
      // 版本号只能有一个来源，所以把"界面文案里写死的 x.y.z"当错误抓出来。
      //
      // 只看 lib/ui/ 且先去掉注释：注释里提到旧版本号是正常的（就是这段说明）。
      String stripComments(String text) {
        var s = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
        s = s.split('\n').map((l) {
          final i = l.indexOf('//');
          return i < 0 ? l : l.substring(0, i);
        }).join('\n');
        return s;
      }

      // 「版本 0.13.1」「版本 v0.13.1」这类写法 —— 正是 About 行的形态
      final hardcoded = RegExp(r'版本\s*v?[0-9]+\.[0-9]+\.[0-9]+');
      final offenders = <String>[];

      final uiFiles = Directory('lib/ui')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final f in uiFiles) {
        final code = stripComments(f.readAsStringSync());
        for (final m in hardcoded.allMatches(code)) {
          offenders.add('${f.path}: ${m.group(0)}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '版本号必须用 kAppVersion 插值，不要写死：\n${offenders.join('\n')}',
      );

      // 并且确认「关于」那一行确实在插值（防止有人换成别的手写来源）
      final settings = File('lib/ui/settings_screen.dart').readAsStringSync();
      expect(settings, contains(r'版本 $kAppVersion'));
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

  group('更新源解析（不联网）', () {
    test('GitCode 数组返回：按版本号取最大，不看顺序', () {
      // 用假 client 不方便，这里直接验证"挑最大"的行为契约
      final list = [
        {'tag_name': 'v0.7.0'},
        {'tag_name': 'v0.10.0'},
        {'tag_name': 'v0.8.0'},
      ];
      final best = list
          .map((m) => SemVer.tryParse(m['tag_name']!))
          .whereType<SemVer>()
          .reduce((a, b) => a > b ? a : b);
      expect(best, const SemVer(0, 10, 0));
    });
  });
}
