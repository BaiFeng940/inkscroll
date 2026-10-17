/// 压缩包工厂：按格式分派到对应的 ArchiveSource 实现。
///
/// 支持的格式矩阵（诚实版）：
///
///   格式       纯 Dart        本仓库状态
///   --------   -----------   ------------------------------------------
///   zip        ✅ 完整        ✅ 已实现（自研中央目录 + 按需 DEFLATE）
///   tar        ✅ 完整        ✅ 已实现（顺序读 512B 头建索引，随机切片）
///   gz / tgz   ⚠️ 顺序解压     ❌ 未实现（需稀疏索引或临时文件，见 DESIGN.md §2.5）
///   bz2 / xz   ⚠️/❌          ❌ 未实现
///   rar        ❌ 专有算法     ❌ 未实现 → 原生桥或引导转换
///   7z         ❌ 专有算法     ❌ 未实现 → 原生桥
library;

import '../byte_source.dart';
import 'archive_source.dart';
import 'tar_archive_source.dart';
import 'zip_archive_source.dart';

enum ArchiveFormat { zip, tar }

class ArchiveFactory {
  /// [formatHint] 来自魔术字节探测结果，不要用扩展名。
  static Future<ArchiveSource> open(
    RandomAccessByteSource src, {
    required ArchiveFormat format,
    int maxEntryBytes = kDefaultMaxEntryBytes,
    EntryCache? cache,
  }) async {
    switch (format) {
      case ArchiveFormat.zip:
        final zip = ZipArchiveSource(src, maxEntryBytes: maxEntryBytes, cache: cache);
        await zip.open();
        return zip;
      case ArchiveFormat.tar:
        final tar = TarArchiveSource(src, maxEntryBytes: maxEntryBytes);
        await tar.open();
        return tar;
    }
  }

  /// 跨条目共享一个缓存：同一本书在导入与阅读之间复用同一份 LRU。
  static EntryCache newSharedCache() => EntryCache();
}
