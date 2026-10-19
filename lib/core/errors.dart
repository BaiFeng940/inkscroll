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

// ---------------------------------------------------------------------------
// 网络（WebDAV / NAS）
// ---------------------------------------------------------------------------

/// 连不上服务器：地址写错、端口没开、不在同一网络、防火墙拦截……
final class NetworkUnreachableError extends AppError {
  const NetworkUnreachableError({String? address, String? detail})
      : super(
          '连接不上服务器。\n'
          '请检查：地址和端口是否正确、网盘服务是否开机、'
          '手机和网盘服务是否在同一个局域网、WebDAV 是否已开启。',
          technicalDetail: '${address ?? ''} $detail',
          action: ErrorAction.retry,
        );
}

/// 认证失败
final class NetworkAuthError extends AppError {
  const NetworkAuthError({String? detail})
      : super(
          '用户名或密码不正确。\n'
          '请确认是网盘的 WebDAV 账号（不一定与登录其网页的账号相同）。',
          technicalDetail: detail,
          action: ErrorAction.enterPassword,
        );
}

/// 服务器返回了非预期状态码
final class NetworkHttpError extends AppError {
  const NetworkHttpError(this.statusCode, {String? path, String? detail})
      : super(
          '服务器返回错误（HTTP $statusCode）。\n'
          '常见原因：路径不存在（404）、没有访问权限（403）、'
          '或该地址不是 WebDAV 服务（200 但内容不是文件列表）。',
          technicalDetail: 'HTTP $statusCode ${path ?? ''} $detail',
          action: ErrorAction.none,
        );
  final int statusCode;
}

/// 返回的内容不是 WebDAV 的多状态响应 —— 多半是地址填成了网页地址
final class NotWebDavError extends AppError {
  const NotWebDavError({String? detail})
      : super(
          '这个地址看起来不是 WebDAV 服务。\n'
          '你填的可能是网盘的网页管理地址。\n'
          '请在飞牛 OS 里开启「文件服务 → WebDAV」，'
          '然后填写形如 http://192.168.1.10:5005/dav 的地址。',
          technicalDetail: detail,
          action: ErrorAction.retry,
        );
}

/// TLS 证书校验失败（自签证书的 NAS 非常常见）
final class NetworkCertificateError extends AppError {
  const NetworkCertificateError({String? detail})
      : super(
          'HTTPS 证书校验失败。\n'
          '自建网盘通常使用自签证书。你可以：\n'
          '· 改用 http:// 地址（局域网内可以接受）；或\n'
          '· 在下方打开「允许自签名证书」。',
          technicalDetail: detail,
          action: ErrorAction.retry,
        );
}
