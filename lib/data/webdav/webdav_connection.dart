/// WebDAV 连接配置及其持久化。
///
/// ## 关于密码存哪
///
/// 密码存在 **SharedPreferences**（应用私有目录）。在未 root 的 Android 上，
/// 其他应用读不到这份数据；但它**没有加密**，root 设备或 adb 备份能取到。
///
/// 这里额外做了一层 **XOR + Base64 的混淆**。必须说清楚：
///
/// > **这是混淆，不是加密。** 密钥就编译在 apk 里，拿得到 apk 就能还原。
/// > 它的作用只是让 `grep` 一眼看不到明文密码，抬高一点点门槛。
///
/// 真正的做法有两条，按需再做：
///   · 换 `flutter_secure_storage`，把密码交给 Android Keystore；
///   · 更推荐：**在 NAS 上单独建一个只读的 WebDAV 账号**给阅读器用，
///     就算泄露也只能读到你开放的那个目录。
///     这条建议也写在界面上，因为它比任何加密都实用。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'webdav_client.dart' show WebDavClient;

/// 一条 NAS 连接
class WebDavConnection {
  const WebDavConnection({
    required this.id,
    required this.label,
    required this.baseUrl,
    this.username = '',
    this.password = '',
    this.allowSelfSigned = false,
    this.lastUsedAt,
  });

  final String id;

  /// 给用户看的名字，例如「家里的飞牛」
  final String label;

  /// 根地址，例如 http://192.168.1.10:5005/dav
  final String baseUrl;

  final String username;
  final String password;

  /// 允许自签证书（家用 NAS 的 HTTPS 基本都是自签）
  final bool allowSelfSigned;

  final DateTime? lastUsedAt;

  String get displayLabel => label.trim().isEmpty ? baseUrl : label;

  /// 根目录在面包屑 / 书名里用的短名字。
  ///
  /// 用户没填备注名时，`displayLabel` 会退化成完整 URL
  /// （`http://192.168.1.10:5005/dav`），直接当书名很难看。
  /// 这里优先用备注名，其次用路径最后一段（通常是 `dav`），
  /// 再不行用主机名。
  String get rootName {
    final l = label.trim();
    if (l.isNotEmpty) return l;
    final u = Uri.tryParse(baseUrl);
    if (u == null) return baseUrl;
    final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isNotEmpty) return segs.last;
    return u.host.isEmpty ? baseUrl : u.host;
  }

  WebDavConnection copyWith({
    String? label,
    String? baseUrl,
    String? username,
    String? password,
    bool? allowSelfSigned,
    DateTime? lastUsedAt,
  }) =>
      WebDavConnection(
        id: id,
        label: label ?? this.label,
        baseUrl: baseUrl ?? this.baseUrl,
        username: username ?? this.username,
        password: password ?? this.password,
        allowSelfSigned: allowSelfSigned ?? this.allowSelfSigned,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      );

  /// 造一个客户端
  WebDavClient createClient() => WebDavClient(
        baseUrl: baseUrl,
        username: username.isEmpty ? null : username,
        password: password.isEmpty ? null : password,
        allowSelfSigned: allowSelfSigned,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'baseUrl': baseUrl,
        'username': username,
        // 混淆后再存，见文件头的说明
        'password': _obfuscate(password),
        'allowSelfSigned': allowSelfSigned,
        'lastUsedAt': lastUsedAt?.toIso8601String(),
      };

  static WebDavConnection fromJson(Map<String, dynamic> m) => WebDavConnection(
        id: m['id'] as String,
        label: m['label'] as String? ?? '',
        baseUrl: m['baseUrl'] as String? ?? '',
        username: m['username'] as String? ?? '',
        password: _deobfuscate(m['password'] as String? ?? ''),
        allowSelfSigned: m['allowSelfSigned'] as bool? ?? false,
        lastUsedAt: DateTime.tryParse(m['lastUsedAt'] as String? ?? ''),
      );

  // ── 混淆（**不是加密**）──
  static const String _key = 'inkScroll.webdav.v1';

  static String _obfuscate(String plain) {
    if (plain.isEmpty) return '';
    final bytes = utf8.encode(plain);
    final key = utf8.encode(_key);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = bytes[i] ^ key[i % key.length];
    }
    return base64Encode(bytes);
  }

  static String _deobfuscate(String stored) {
    if (stored.isEmpty) return '';
    try {
      final bytes = base64Decode(stored);
      final key = utf8.encode(_key);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = bytes[i] ^ key[i % key.length];
      }
      return utf8.decode(bytes);
    } catch (_) {
      return '';
    }
  }
}

/// 连接的增删改查（存在 SharedPreferences 里）
class WebDavConnectionStore {
  WebDavConnectionStore(this._prefs);

  final SharedPreferences _prefs;
  static const String _kConnections = 'inkscroll.webdav.connections';

  List<WebDavConnection> _loadRaw() {
    final raw = _prefs.getString(_kConnections);
    // ★ 必须返回**可增长**的空列表，不能返回 `const []`。
    //   `all()` / `upsert()` / `remove()` 都会对这个结果做 sort/add/removeWhere，
    //   一旦是编译期常量列表就会抛：
    //     Unsupported operation: Cannot modify an unmodifiable list
    //   这个 bug 在真机上表现为「点开 NAS 导入就红屏」——
    //   单元测试没覆盖“空存储”所以没提前发现，现在补上了。
    if (raw == null || raw.isEmpty) return <WebDavConnection>[];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .cast<Map<String, dynamic>>()
          .map(WebDavConnection.fromJson)
          .where((c) => c.baseUrl.isNotEmpty)
          .toList();
    } catch (_) {
      return <WebDavConnection>[];
    }
  }

  Future<void> _saveRaw(List<WebDavConnection> list) async {
    await _prefs.setString(
      _kConnections,
      jsonEncode(list.map((c) => c.toJson()).toList()),
    );
  }

  /// 全部连接，最近用过的排在前面
  List<WebDavConnection> all() {
    final list = _loadRaw();
    list.sort((a, b) {
      final x = a.lastUsedAt, y = b.lastUsedAt;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
    return list;
  }

  WebDavConnection? byId(String id) {
    for (final c in _loadRaw()) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> upsert(WebDavConnection conn) async {
    final list = _loadRaw();
    final i = list.indexWhere((c) => c.id == conn.id);
    if (i >= 0) {
      list[i] = conn;
    } else {
      list.add(conn);
    }
    await _saveRaw(list);
  }

  Future<void> remove(String id) async {
    final list = _loadRaw()..removeWhere((c) => c.id == id);
    await _saveRaw(list);
  }

  Future<void> touch(String id) async {
    final list = _loadRaw();
    final i = list.indexWhere((c) => c.id == id);
    if (i < 0) return;
    list[i] = list[i].copyWith(lastUsedAt: DateTime.now());
    await _saveRaw(list);
  }

  /// 新建连接时生成 id
  static String newId() =>
      'dav_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}
