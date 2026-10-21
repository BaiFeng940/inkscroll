import 'package:flutter_test/flutter_test.dart';
import 'package:inkscroll/data/models/book_meta.dart';

void main() {
  group('ArchiveSourceSpec 加密密码持久化', () {
    test('带密码往返一致', () {
      const spec = ArchiveSourceSpec(
        path: '/x/a.zip',
        format: 'zip',
        password: 'manga123',
      );
      final back = BookSource.fromJson(spec.toJson()) as ArchiveSourceSpec;
      // 密码丢了会导致"导入成功但翻开就报请输入密码"
      expect(back.password, 'manga123');
      expect(back.path, '/x/a.zip');
    });

    test('无密码不写 pw 字段', () {
      const spec = ArchiveSourceSpec(path: '/x/a.zip');
      expect(spec.toJson().containsKey('pw'), isFalse);
      final back = BookSource.fromJson(spec.toJson()) as ArchiveSourceSpec;
      expect(back.password, isNull);
    });
  });
}