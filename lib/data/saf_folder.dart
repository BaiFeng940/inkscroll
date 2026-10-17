/// SAF（Android Storage Access Framework）文件夹导入的 Dart 侧封装。
///
/// ## 为什么不用 `file_picker.getDirectoryPath()`
///
/// 实测（Android 14 模拟器）确认它在 Android 11+ 上**不可用**，原因有两层：
///
/// 1. **系统限制**：Android 11 起不允许把存储根目录、`Download` 等受保护目录
///    授权给应用，界面上直接显示
///    "Can't use this folder / To protect your privacy, choose another folder"。
/// 2. **插件实现限制**：`file_picker` 的 `getFullPathFromTreeUri()` 里，
///    Downloads provider 的 `content://` → 文件路径转换被
///    `if (Build.VERSION.SDK_INT < R)` 包住 —— 只在 Android 11 以下生效。
///    Android 11+ 会返回 null 或抛 `unknown_path`。
///
/// 结果就是"选了文件夹但什么都没发生"（旧代码里 `if (dir == null) return;`
/// 把失败彻底吞掉了）。
///
/// ## 这里怎么做
///
/// 不试图把 `content://` 转成路径（本来就不可靠），而是**通过 SAF 直接读内容**：
/// 原生侧枚举 tree URI 下所有子文档，用 `ContentResolver.openInputStream`
/// 逐个复制进应用私有目录。
///
/// 顺带解决阅读性能：复制完成后每页都是本地文件，读取不再经过 SAF 的
/// Binder 往返（那非常慢）。
///
/// 非 Android 平台（iOS/桌面）返回 [SafCopyResult.unsupported]，由调用方回退。
library;

import 'dart:io';

import 'package:flutter/services.dart';

class SafCopyResult {
  const SafCopyResult({
    required this.supported,
    this.cancelled = false,
    this.copied = 0,
    this.total = 0,
    this.skipped = 0,
    this.folderName = '',
    this.errorMessage,
  });

  /// 当前平台是否支持 SAF（仅 Android）
  final bool supported;

  /// 用户取消了选择
  final bool cancelled;

  /// 成功复制的文件数
  final int copied;

  /// 枚举到的文件总数
  final int total;

  /// 因扩展名不匹配或读取失败而跳过
  final int skipped;

  /// 所选文件夹的名字（用于书籍标题）
  final String folderName;

  final String? errorMessage;

  static const SafCopyResult unsupported =
      SafCopyResult(supported: false, errorMessage: '当前平台不支持 SAF 文件夹选择');

  @override
  String toString() =>
      'SafCopyResult(copied: $copied/$total, skipped: $skipped, '
      'cancelled: $cancelled, folder: $folderName)';
}

class SafFolder {
  SafFolder._();

  static const MethodChannel _channel = MethodChannel('inkscroll/saf');

  static bool get isSupported => Platform.isAndroid;

  /// 弹出系统文件夹选择器，并把选中目录下的文件复制到 [destDir]。
  ///
  /// [extensions] 形如 `['.jpg', '.png']`；为空表示不过滤（全部复制）。
  static Future<SafCopyResult> pickAndCopy({
    required String destDir,
    List<String> extensions = const [],
  }) async {
    if (!isSupported) return SafCopyResult.unsupported;

    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'pickAndCopy',
        {'destDir': destDir, 'extensions': extensions},
      );
      if (raw == null) {
        return const SafCopyResult(
          supported: true,
          errorMessage: '文件夹选择器没有返回结果',
        );
      }
      return SafCopyResult(
        supported: true,
        cancelled: raw['cancelled'] == true,
        copied: (raw['copied'] as num?)?.toInt() ?? 0,
        total: (raw['total'] as num?)?.toInt() ?? 0,
        skipped: (raw['skipped'] as num?)?.toInt() ?? 0,
        folderName: (raw['folderName'] as String?) ?? '',
      );
    } on PlatformException catch (e) {
      return SafCopyResult(
        supported: true,
        errorMessage: '${e.code}: ${e.message ?? ''}',
      );
    } on MissingPluginException {
      return const SafCopyResult(
        supported: false,
        errorMessage: 'SAF 原生插件未注册（请确认使用最新构建）',
      );
    } catch (e) {
      return SafCopyResult(supported: true, errorMessage: '$e');
    }
  }
}
