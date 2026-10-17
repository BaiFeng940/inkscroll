/// 网盘抽象接口 —— 插件式扩展设计（尚未接入具体实现）。
///
/// 设计目标：新增一个网盘 = 实现 7 个方法 + register() 一行，
/// 阅读器、导入流程、UI 全部零改动。
///
/// ★ 诚实说明（必须写进产品与文档，不要过度承诺）：
///   各网盘的可达性差异极大，详见 DESIGN.md §2.12 的能力矩阵。
///   优先做 **WebDAV / 局域网 HTTP / SMB**（零合规风险、协议稳定），
///   官方 OAuth 网盘次之，Cookie 驱动方案明确标注"实验性、随时失效"。
library;

import 'dart:async';

// ---------------------------------------------------------------------------
// 能力声明：让 UI 知道"这个 provider 能做什么、不能做什么"
// ---------------------------------------------------------------------------
class NetDiskCapability {
  const NetDiskCapability({
    required this.rangeRequest,
    required this.directLink,
    required this.shareWithoutLogin,
    required this.needsOfficialApp,
    this.experimental = false,
    this.notes = '',
  });

  /// 支持 HTTP Range（决定能否"只读远程 zip 的中央目录"）
  final bool rangeRequest;

  /// 能拿到可复用的直链
  final bool directLink;

  /// 分享链接免登录可读
  final bool shareWithoutLogin;

  /// 必须装官方 App / 走官方 SDK
  final bool needsOfficialApp;

  /// 实验性实现（Cookie 驱动等）—— UI 要显著提示风险
  final bool experimental;
  final String notes;
}

// ---------------------------------------------------------------------------
// 数据模型
// ---------------------------------------------------------------------------
class NetDiskEntry {
  const NetDiskEntry({
    required this.name,
    required this.isDir,
    required this.path,
    this.size = 0,
    this.modifiedAt,
    this.fileId,
  });

  final String name;
  final bool isDir;
  final String path;
  final int size;
  final DateTime? modifiedAt;
  final String? fileId;
}

class NetDiskRef {
  const NetDiskRef({required this.path, this.fileId});
  final String path;
  final String? fileId;
}

/// 分享链接解析结果
class ShareHandle {
  const ShareHandle({
    required this.providerId,
    required this.rootRef,
    this.title,
    this.isDirectory = true,
  });

  final String providerId;
  final NetDiskRef rootRef;
  final String? title;
  final bool isDirectory;
}

class AuthContext {
  const AuthContext({this.webViewAvailable = true, this.username, this.password});
  final bool webViewAvailable;
  final String? username;
  final String? password;
}

sealed class AuthResult {
  const AuthResult();
}

final class AuthSuccess extends AuthResult {
  const AuthSuccess();
}

/// 需要走 OAuth，把 URL 交给系统浏览器或内嵌 WebView
final class AuthNeedsOAuth extends AuthResult {
  const AuthNeedsOAuth(this.authorizeUrl);
  final Uri authorizeUrl;
}

/// 需要 WebView 登录后取 Cookie
final class AuthNeedsWebViewLogin extends AuthResult {
  const AuthNeedsWebViewLogin(this.loginUrl);
  final Uri loginUrl;
}

/// 分享链接需要提取码
class SharePasswordRequired implements Exception {
  const SharePasswordRequired();
}

class ShareExpired implements Exception {
  const ShareExpired();
}

/// HTTP Range 不被支持：调用方要退化为"先整体下载"
class RangeNotSupported implements Exception {
  const RangeNotSupported();
}

/// 顺序读取源（用于流式下载/解码）
abstract interface class SequentialByteSource {
  Stream<List<int>> stream({int? start, int? end});
  Future<void> close();
}

// ---------------------------------------------------------------------------
// ★ 核心抽象
// ---------------------------------------------------------------------------
abstract interface class NetDiskProvider {
  /// 稳定 id：'webdav' | 'baidu' | 'aliyun' | 'quark' | ...
  String get id;

  String get displayName;

  NetDiskCapability get capabilities;

  Future<bool> isAuthenticated();

  Future<AuthResult> authenticate(AuthContext ctx);

  /// 用户手动提交 Cookie（WebView 登录后回传）
  Future<void> submitCookies(Map<String, String> cookies);

  Future<void> logout();

  /// 解析分享链接。
  /// 抛 [SharePasswordRequired] 表示需要提取码；
  /// 抛 [ShareExpired] 表示链接失效。
  Future<ShareHandle> resolveShare(Uri shareUrl, {String? password});

  Future<List<NetDiskEntry>> list(NetDiskRef dir);

  /// 流式读取（优先 Range，退化为顺序流）
  Future<SequentialByteSource> openRead(NetDiskEntry file);

  /// 取直链；没有直链权限时返回 null（不要抛异常）
  Future<Uri?> directLink(NetDiskEntry file);

  /// 下载时需要的请求头（Referer / User-Agent / Authorization）
  Map<String, String> get downloadHeaders;
}

// ---------------------------------------------------------------------------
// 注册表：插件化的落点
// ---------------------------------------------------------------------------
class NetDiskRegistry {
  NetDiskRegistry();

  final Map<String, NetDiskProvider Function()> _factories = {};

  void register(String id, NetDiskProvider Function() factory) {
    _factories[id] = factory;
  }

  NetDiskProvider? resolve(String id) => _factories[id]?.call();

  Iterable<String> get registeredIds => _factories.keys;

  /// 启动时注册已知实现。
  ///
  /// 推荐落地顺序（按风险从低到高）：
  ///   1. WebDAV           —— 坚果云 / Nextcloud / 群晖。标准协议，零合规风险
  ///   2. 局域网 HTTP 目录  —— Komga / Calibre-Web / 自建漫画服务器，零风险
  ///   3. SMB / SFTP       —— 局域网 NAS
  ///   4. 官方 OAuth 网盘   —— 百度 / 阿里云盘（需注册应用、审核、限速）
  ///   5. Cookie 方案      —— 夸克等。⚠️ 违反 ToS 风险高、随时失效、可能封号
  static NetDiskRegistry bootstrap() {
    final r = NetDiskRegistry();
    // r.register('webdav', () => WebDavProvider());
    // r.register('httpdir', () => HttpDirectoryProvider());
    // r.register('smb', () => SmbProvider());
    // r.register('baidu', () => BaiduProvider());
    // r.register('aliyun', () => AliyunProvider());
    // r.register('quark', () => QuarkExperimentalProvider());  // experimental: true
    return r;
  }
}

// ---------------------------------------------------------------------------
// 远程压缩包的两条路径
// ---------------------------------------------------------------------------
enum RemoteArchiveStrategy {
  /// ★ 首选：HTTP Range 读远程 zip 中央目录，只下载需要的条目。
  ///   打开一个 2GB 的包只需下载几百 KB。
  ///   前提：直链支持 206 Partial Content。
  remoteRange,

  /// 兜底：先整体下载到本地临时文件，再走本地 ZipArchiveSource。
  ///   首次必须下完（受网盘限速影响大），但之后阅读很快。
  downloadThenOpen,
}

/// 运行时探测决定走哪条路
Future<RemoteArchiveStrategy> chooseRemoteStrategy(
  NetDiskProvider provider,
  NetDiskEntry entry, {
  int hugeThresholdBytes = 4 << 30,
  required Future<bool> Function(Uri link) probeRangeSupport,
}) async {
  if (entry.size > hugeThresholdBytes) return RemoteArchiveStrategy.downloadThenOpen;

  final link = await provider.directLink(entry);
  if (link == null) return RemoteArchiveStrategy.downloadThenOpen;

  try {
    final ok = await probeRangeSupport(link);
    return ok ? RemoteArchiveStrategy.remoteRange : RemoteArchiveStrategy.downloadThenOpen;
  } catch (_) {
    return RemoteArchiveStrategy.downloadThenOpen;
  }
}
