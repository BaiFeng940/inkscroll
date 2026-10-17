/// 导入器共用的判定与工具。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../core/image_header.dart';
import '../core/magic.dart';
import '../core/natural_sort.dart';

/// 支持的图片扩展名。
///
/// 注意：扩展名只是**第一层**判定。真实文件常常没有扩展名、
/// 或者扩展名和内容不符（改名、导出错误）。所以还会用
/// [sniffFileKind] 读文件头按魔数判定 —— 见下面的说明。
const kImageExtensions = {
  // 常见
  '.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.webp', '.gif', '.bmp',
  // 现代格式
  '.avif', '.heic', '.heif', '.avifs', '.hif',
  // 扫描/印刷
  '.tif', '.tiff',
  // 其他 Flutter 能解的
  '.ico',
  // 矢量（Flutter 不能直接解，但先识别出来再给明确提示，好过"无法识别"）
  '.svg',
};

/// 已知但 Flutter 不保证能解码的图片格式 —— 单独识别以便给出可操作提示
const kUnsupportedImageExtensions = {
  '.jxl', // JPEG XL
  '.psd',
  '.qoi',
  '.dng', '.cr2', '.cr3', '.nef', '.arw', '.raf', '.rw2', '.orf', // 相机 RAW
  '.tga', '.pcx', '.ppm', '.pgm', '.pbm', '.xcf', '.kra', '.cbr2',
};

/// 支持的纯文本扩展名
const kTextExtensions = {
  '.txt', '.md', '.markdown', '.log', '.text', '.nfo', '.srt', '.ass', '.vtt',
};

/// 压缩包扩展名
const kArchiveExtensions = {
  '.zip', '.tar', '.gz', '.tgz', '.rar', '.7z', '.cbz', '.cbr', '.cb7', '.cbt',
};

/// 导入文件夹时允许复制的全部扩展名。
///
/// Android SAF 的枚举发生在**原生侧**，所以必须把这份清单传过去 ——
/// 否则会把整个文件夹（含视频、安装包）都复制进来，既慢又白占空间。
Set<String> get kImportableExtensions => {
      ...kImageExtensions,
      ...kUnsupportedImageExtensions,
      ...kTextExtensions,
    };

/// 去掉导入时可能加过的序号前缀（历史版本用过 `00001_原名.jpg`）。
///
/// 排序键要用**原始文件名**：`00001_`、`00002_` 这种前缀会掩盖用户真实的
/// 命名意图，而用户往往就是靠文件名表达顺序的（`1.jpg`、`2.jpg`、`10.jpg`）。
String stripImportIndexPrefix(String fileName) {
  final m = RegExp(r'^\d{5}_').firstMatch(fileName);
  return m == null ? fileName : fileName.substring(m.end);
}

/// 图片/文本文件的排序键：优先用"去掉序号前缀后的原始名"。
///
/// 注意这里只影响**排序**，不改动磁盘上的真实文件名 ——
/// 这样既尊重用户的命名，又不破坏"打开书就是本地文件"的稳定性。
int compareByOriginalName(String a, String b) =>
    NaturalComparator.comparePath(
      stripImportIndexPrefix(a),
      stripImportIndexPrefix(b),
    );

bool isImagePath(String path) {
  final ext = p.extension(path).toLowerCase();
  return kImageExtensions.contains(ext) ||
      kUnsupportedImageExtensions.contains(ext);
}

/// 只判断"Flutter 能渲染"的图片
bool isRenderableImagePath(String path) =>
    kImageExtensions.contains(p.extension(path).toLowerCase());

bool isUnsupportedImagePath(String path) =>
    kUnsupportedImageExtensions.contains(p.extension(path).toLowerCase());

bool isTextPath(String path) =>
    kTextExtensions.contains(p.extension(path).toLowerCase());

bool isArchivePath(String path) =>
    kArchiveExtensions.contains(p.extension(path).toLowerCase());

// ---------------------------------------------------------------------------
// 内容判定：读文件头按魔数识别
// ---------------------------------------------------------------------------

/// 文件"种类"的归类结果
enum FileKind { image, unsupportedImage, text, archive, other }

class SniffResult {
  const SniffResult({
    required this.kind,
    this.formatLabel,
    this.aspectRatio,
  });

  final FileKind kind;

  /// 例如 'JPEG' / 'HEIC/HEIF'，用于诊断提示
  final String? formatLabel;

  /// 如果能解析出宽高，顺手带回来（省一次读取）
  final double? aspectRatio;
}

/// 读文件头部若干字节，按**内容**判断这是什么文件。
///
/// 为什么必须有这一层：
///   用户反馈"文件夹导入找不到图片"。真实世界的图片目录里经常有
///   无扩展名文件、`.dat`、或者扩展名与内容不符的文件。
///   只按扩展名过滤必然漏掉它们。
///
/// 成本：每个文件只读前 4KB（[headBytes]），且进来之前已经用扩展名
/// 筛过一轮，所以只会对"扩展名不认识"的文件调用它。
Future<SniffResult?> sniffFileKind(
  File file, {
  int headBytes = 4096,
}) async {
  try {
    final raf = await file.open();
    try {
      final len = await raf.length();
      if (len < 12) return null;
      final n = len < headBytes ? len : headBytes;
      final head = await raf.read(n);
      final fmt = MagicDetector.detect(head);
      final dim = ImageHeaderParser.tryParse(head);

      if (fmt.isRenderableImage) {
        return SniffResult(
          kind: FileKind.image,
          formatLabel: fmt.label,
          aspectRatio: dim?.aspectRatio,
        );
      }
      if (fmt.isKnownButUnsupportedImage) {
        return SniffResult(kind: FileKind.unsupportedImage, formatLabel: fmt.label);
      }
      switch (fmt) {
        case ContainerFormat.zip:
        case ContainerFormat.tar:
        case ContainerFormat.gzip:
        case ContainerFormat.rar4:
        case ContainerFormat.rar5:
        case ContainerFormat.sevenZip:
          return SniffResult(kind: FileKind.archive, formatLabel: fmt.label);
        case ContainerFormat.plainText:
        case ContainerFormat.html:
        case ContainerFormat.svg:
          return SniffResult(kind: FileKind.text, formatLabel: fmt.label);
        default:
          return const SniffResult(kind: FileKind.other);
      }
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
}

/// 预检：目录能不能读、里面有没有东西。
///
/// 之所以单独做这一步，是因为 Android SAF 选到的目录可能是
/// Provider 型（下载/GDrive/SD 卡），file_picker 解析不出真实文件路径，
/// 或者授权已失效 —— 这两种情况都必须给出明确提示。
Future<void> ensureReadableDirectory(String path) async {
  if (path.startsWith('content://')) {
    throw GenericError(
      'Android 只返回了 SAF 的 content:// 地址，无法直接按目录读取文件。\n'
      '请改用「选择图片（可多选）」导入，或先把该文件夹复制到手机本地存储'
      '（例如 Download 目录）后重新导入。',
      action: ErrorAction.chooseAnother,
      technicalDetail: 'SAF provider directory: $path',
    );
  }

  final dir = Directory(path);
  if (!await dir.exists()) {
    throw GenericError(
      '文件夹不存在或已无法访问：$path\n'
      '如果它在外置 SD 卡或云盘目录下，请先复制到手机本地存储再导入。',
      action: ErrorAction.chooseAnother,
    );
  }

  try {
    // 只取第一个元素验证权限；空目录会直接结束循环
    await dir.list(followLinks: false).take(1).toList();
  } on FileSystemException catch (e) {
    throw GenericError(
      '没有权限读取该文件夹：${e.message}\n'
      '请在系统设置里重新授予文件访问权限，或改用其它目录。'
      '也可以改用「选择图片（可多选）」导入。',
      action: ErrorAction.openSettings,
      technicalDetail: '$e',
    );
  }
}

/// 判断条目名是不是"垃圾"，要在导入时过滤掉
bool isJunkEntry(String entryPath) {
  final lower = entryPath.toLowerCase();
  final base = p.basename(lower);
  if (lower.startsWith('__macosx/') || lower.contains('/__macosx/')) return true;
  if (base == '.ds_store' || base == 'thumbs.db' || base == 'desktop.ini') return true;
  if (base.startsWith('._')) return true; // macOS 资源分叉文件
  if (lower.endsWith('/.gitkeep')) return true;
  return false;
}

/// 自然排序（逐段比较，避免 '第1话/10.jpg' 与 '第10话/1.jpg' 错位）
int naturalComparePath(String a, String b) => NaturalComparator.comparePath(a, b);

/// 目录前缀，'' 表示根
String parentDirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// 目录名转章节名："第01话" → 保留；"" → "正文"
String chapterTitleFromDir(String dir) {
  if (dir.isEmpty) return '正文';
  return p.basename(dir);
}

/// 递归收集文件（限制深度与数量，避免用户误选整个磁盘时把 App 卡死）。
///
/// 与旧实现的区别：**不再静默吞掉失败**。
///   旧实现在目录不可读时直接返回空列表，上层只会得到
///   "没有找到可阅读的内容" —— 用户完全不知道发生了什么
///   （这正是"文件夹导入识别不了图片"这个 bug 最难查的地方）。
///   现在先做可读性预检，并把目录项数量、跳过原因一并带出来。
class CollectResult {
  const CollectResult({
    required this.files,
    required this.entriesSeen,
    required this.skippedByDepth,
    required this.truncated,
  });

  final List<File> files;

  /// 遍历过程中看到的目录项总数（用于诊断"是不是路径本身有问题"）
  final int entriesSeen;

  /// 因超出深度被跳过的文件数
  final int skippedByDepth;

  /// 是否因达到 maxFiles 而提前停止
  final bool truncated;
}
Future<CollectResult> collectFiles(
  Directory root, {
  int maxDepth = 6,
  int maxFiles = 50000,
}) async {
  final out = <File>[];
  int seen = 0;
  int skippedDepth = 0;
  bool truncated = false;

  // 用平台分隔符计算深度；Windows 与 Android 都是 '\' 与 '/' 混用的历史包袱，
  // 这里统一按两种分隔符取最大切分数，避免深度算错导致漏文件。
  int depthOf(String path) {
    final rel = path.startsWith(root.path) ? path.substring(root.path.length) : path;
    final norm = rel.replaceAll('\\', '/');
    return norm.split('/').where((s) => s.isNotEmpty).length;
  }

  final stream = root.list(recursive: true, followLinks: false);
  await for (final entity in stream) {
    if (entity is! File) continue;
    seen++;
    if (depthOf(entity.path) > maxDepth) {
      skippedDepth++;
      continue;
    }
    if (isJunkEntry(entity.path.replaceAll('\\', '/'))) continue;
    out.add(entity);
    if (out.length >= maxFiles) {
      truncated = true;
      break;
    }
  }

  return CollectResult(
    files: out,
    entriesSeen: seen,
    skippedByDepth: skippedDepth,
    truncated: truncated,
  );
}

/// 是否看起来像长条（Webtoon）—— 用于给出默认模式建议
bool looksLikeWebtoon(Iterable<double?> aspectRatios) {
  final known = aspectRatios.whereType<double>().where((a) => a.isFinite && a > 0).toList();
  if (known.length < 3) return false;
  known.sort();
  final median = known[known.length ~/ 2];
  // 中位比例 < 0.5 说明大部分页都"又窄又长"
  return median < 0.5;
}

/// 给未知比例的页一个兜底（中位数或 1.4）
double medianAspect(Iterable<double?> list) {
  final known = list
      .whereType<double>()
      .where((a) => a.isFinite && a > 0.05 && a < 50)
      .toList()
    ..sort();
  if (known.isEmpty) return 1.4;
  return known[known.length ~/ 2];
}

/// 简单分块工具
Iterable<List<T>> chunk<T>(List<T> list, int size) sync* {
  for (int i = 0; i < list.length; i += size) {
    yield list.sublist(i, math.min(i + size, list.length));
  }
}

/// 有并发上限的 map —— 保持输入顺序返回结果。
///
/// 为什么需要它：导入时"逐张读图片头部拿尺寸"是 I/O 密集型，
/// 顺序 await 500 次文件句柄会明显拖慢导入。
/// 但也不能无脑 `Future.wait` 全部并发：上千个并发文件句柄会直接
/// 触发 `Too many open files` / EMFILE。
///
/// 所以用"滑动窗口"：始终保持 [concurrency] 个任务在飞。
Future<List<R>> mapConcurrent<T, R>(
  List<T> items, {
  required Future<R> Function(T item) task,
  int concurrency = 8,
  void Function(int done)? onProgress,
}) async {
  if (items.isEmpty) return <R>[];

  final results = List<R?>.filled(items.length, null);
  int next = 0;
  int done = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      results[i] = await task(items[i]);
      done++;
      onProgress?.call(done);
    }
  }

  final workers = <Future<void>>[
    for (int i = 0; i < math.min(concurrency, items.length); i++) worker(),
  ];
  await Future.wait(workers);

  return results.cast<R>();
}
