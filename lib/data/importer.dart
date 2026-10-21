/// 导入抽象层。
///
/// 设计要点：
///   1. `Importer` 必须**幂等** —— 同一个 pick + password 可以重复调用
///      （密码错误就是靠"带着新密码再跑一遍"来重试的）。
///   2. **密码错误是正常返回值**（[NeedPassword]），不是异常穿透。
///      这样 UI 只需处理三个分支，不需要 try/catch 整个调用栈。
library;

import 'dart:typed_data';

import '../core/errors.dart';
import '../reader/document.dart';
import 'byte_source.dart';

// ---------------------------------------------------------------------------
// 用户选了什么
// ---------------------------------------------------------------------------

enum SourcePickKind { file, files, folder, url, webdav }

class SourcePick {
  const SourcePick({
    required this.kind,
    required this.displayName,
    required this.sourceId,
    this.path,
    this.paths = const [],
    this.uri,
    this.sizeBytes,
    this.modifiedAt,
    this.alreadyLocal = false,
    this.manuallyOrdered = false,

    this.webdavConnectionId,
    this.webdavFolderUrl,
    this.webdavFolderName,
  });

  final SourcePickKind kind;
  final String displayName;

  /// 内容指纹 / 去重用的稳定标识
  final String sourceId;

  final String? path;
  final List<String> paths;
  final Uri? uri;
  final int? sizeBytes;
  final DateTime? modifiedAt;

  /// `path` 是否**已经在应用私有目录里**。
  ///
  /// 为 true 时导入器跳过"复制到私有目录"这一步。
  /// 用于 Android 的 SAF 文件夹导入：原生侧已经把文件直接复制进了书目录，
  /// 再复制一次纯属浪费（几百张图会明显拖慢导入）。
  final bool alreadyLocal;

  /// 散图导入时，[paths] 是否已被用户**手动调整过顺序**。
  ///
  /// 为 false（默认）时导入器会按**原始文件名自然排序**；
  /// 为 true 时原样保留调用方给的顺序。
  final bool manuallyOrdered;

  // ---- WebDAV / NAS ----

  /// 用哪条 NAS 连接（凭据存在连接表里，不在 pick 上）
  final String? webdavConnectionId;

  /// 目标文件夹的绝对 URL
  final String? webdavFolderUrl;

  /// 文件夹显示名（用作书籍标题）
  final String? webdavFolderName;
}

/// 格式探测结果
class SourceProbe {
  const SourceProbe({
    required this.formatName,
    required this.entryNames,
    this.isContainer = false,
    this.isEncrypted = false,
    this.mimeHint,
  });

  /// 'zip' / 'tar' / 'rar' / '7z' / 'folder' / 'txt' / 'image' / 'pdf' ...
  final String formatName;

  /// 容器格式的内部条目名（用于区分 zip vs docx、判断是不是漫画）
  final List<String> entryNames;

  final bool isContainer;
  final bool isEncrypted;

  /// 具体格式的人类可读名（例如 'HEIC/HEIF'、'AVIF'），用于错误提示
  final String? mimeHint;
}

// ---------------------------------------------------------------------------
// 导入上下文与结果
// ---------------------------------------------------------------------------

class ImportContext {
  ImportContext({
    required this.pick,
    this.password,
    this.passwordAttempt = 1,
    void Function(double ratio, String label)? onProgress,
  }) : onProgress = onProgress ?? _noop;

  final SourcePick pick;

  /// 上一轮用户输入的密码（重试时携带）
  final String? password;
  final int passwordAttempt;

  /// 进度回调：(0~1, 描述文本)
  final void Function(double ratio, String label) onProgress;

  static void _noop(double r, String l) {}

  ImportContext withPassword(String pwd) => ImportContext(
        pick: pick,
        password: pwd,
        passwordAttempt: passwordAttempt + 1,
        onProgress: onProgress,
      );
}

sealed class ImportOutcome {
  const ImportOutcome();
}

final class ImportedDocument extends ImportOutcome {
  const ImportedDocument(this.document);
  final Document document;
}

/// 需要密码 / 密码错误：UI 弹密码框后带 [attempt] 再跑一次
final class NeedPassword extends ImportOutcome {
  const NeedPassword({required this.attempt, this.hint = '该压缩包已加密，请输入密码'});
  final int attempt;
  final String hint;
}

final class ImportFailure extends ImportOutcome {
  const ImportFailure(this.error);
  final AppError error;
}

// ---------------------------------------------------------------------------
// Importer 接口
// ---------------------------------------------------------------------------

abstract interface class Importer {
  /// 稳定标识，用于日志与调试
  String get id;

  /// 这个导入器能不能处理该来源
  bool canHandle(SourceProbe probe);

  /// 执行导入。必须幂等。
  Future<ImportOutcome> run(ImportContext ctx);
}

/// 探测阶段的一个小工具：读文件头部字节，判断真实格式。
///
/// 一定不要用 `File.readAsBytes()`：一个 2GB 的漫画包会直接 OOM。
class HeadReader {
  HeadReader(this._src);
  final RandomAccessByteSource _src;

  Future<Uint8List> head({int bytes = 8192}) async {
    final len = await _src.length();
    final n = bytes < len ? bytes : len;
    return _src.read(0, n);
  }

  Future<int> length() => _src.length();
  Future<void> close() => _src.close();
}
