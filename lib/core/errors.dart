/// 统一错误类型。UI 只关心 [ErrorAction]，不关心异常类名。
///
/// 注意：`AppError` 是 sealed 类，**不能直接实例化**。
/// 需要"通用错误"时用 [GenericError]。
library;

enum ErrorAction {
  retry,
  enterPassword,
  chooseAnother,
  openSettings,
  convertFile,
  none,
}

sealed class AppError implements Exception {
  const AppError(this.message, {this.technicalDetail, this.action = ErrorAction.none});

  /// 面向用户的中文提示
  final String message;

  /// 写日志用的技术细节
  final String? technicalDetail;

  /// UI 应该给什么按钮
  final ErrorAction action;

  @override
  String toString() =>
      'AppError($message${technicalDetail == null ? '' : ' | $technicalDetail'})';
}

/// 通用错误：不想为每种情况都新建子类时用它
final class GenericError extends AppError {
  const GenericError(
    super.message, {
    super.technicalDetail,
    super.action,
  });
}

final class NotAnArchiveError extends AppError {
  const NotAnArchiveError({String? detail})
      : super('这看起来不是有效的压缩包（找不到中央目录）', technicalDetail: detail);
}

final class ArchivePasswordRequiredError extends AppError {
  const ArchivePasswordRequiredError({this.entryPath})
      : super('压缩包已加密，请输入密码', action: ErrorAction.enterPassword);
  final String? entryPath;
}

final class ArchivePasswordWrongError extends AppError {
  const ArchivePasswordWrongError()
      : super('密码不正确，请重试', action: ErrorAction.enterPassword);
}

final class UnsupportedCompressionError extends AppError {
  const UnsupportedCompressionError(this.method)
      : super('不支持的压缩算法（method=$method）', action: ErrorAction.convertFile);
  final int method;
}

final class PayloadTooLargeError extends AppError {
  PayloadTooLargeError(this.entryPath, this.declared, this.limit)
      : super(
          '压缩包内该文件声明解压后为 ${_human(declared)}，'
          '超过安全上限 ${_human(limit)}。已中止以避免内存溢出。',
          technicalDetail: 'zip bomb guard: $entryPath',
        );

  final String entryPath;
  final int declared;
  final int limit;

  // 不能在 const 构造里做字符串格式化，所以用静态方法而非 const
  static String _human(int v) => '${(v / 1024 / 1024).toStringAsFixed(1)}MB';
}

final class CorruptArchiveError extends AppError {
  const CorruptArchiveError({String? detail})
      : super('压缩包已损坏或数据被截断', technicalDetail: detail);
}

final class UnsupportedFormatError extends AppError {
  const UnsupportedFormatError(this.format, {this.hint})
      : super('暂不支持该格式：$format', action: ErrorAction.convertFile);
  final String format;
  final String? hint;
}

final class ImportEmptyError extends AppError {
  const ImportEmptyError() : super('没有找到可阅读的内容');
}

final class Rar7zNotImplementedError extends AppError {
  const Rar7zNotImplementedError(this.format)
      : super(
          '$format 使用专有压缩算法，Flutter 端无法纯 Dart 实现。'
          '请先用 7-Zip / WinRAR 转换为 zip 后重新导入。',
          action: ErrorAction.convertFile,
        );
  final String format;
}
