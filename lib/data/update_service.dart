/// 检查更新。
///
/// 设计原则：
///
/// 1) **不阻塞启动**。更新检查是后台任务，失败就静默 —— 用户打开应用
///    是为了看书，不是为了看错误提示。
/// 2) **国内镜像优先**。GitHub API 在国内经常几十秒超时；先问 GitCode，
///    失败再兜底 GitHub，两者都失败就当"已是最新"。
/// 3) **版本比较走语义化**，不用字符串比较 —— 否则 `0.10.0` 会被判成
///    比 `0.9.0` 更旧。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app_version.dart';

/// 解析出来的版本号（只关心数字部分）
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// 从任意标签里提取版本号：`v0.7.1` / `0.7.1` / `release-0.7.1` 都行。
  static SemVer? tryParse(String raw) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(raw);
    if (m == null) return null;
    return SemVer(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
  }

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major - other.major;
    if (minor != other.minor) return minor - other.minor;
    return patch - other.patch;
  }

  bool operator >(SemVer other) => compareTo(other) > 0;
  bool operator <(SemVer other) => compareTo(other) < 0;

  @override
  String toString() => '$major.$minor.$patch';

  @override
  bool operator ==(Object other) =>
      other is SemVer &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);
}

/// 一次检查的结论
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.hasUpdate,
    this.latest,
    this.notes,
    this.downloadUrl,
    this.sourceName,
    this.checked = true,
  });

  /// 是否有新版本
  final bool hasUpdate;

  /// 远端最新版本
  final SemVer? latest;

  /// 更新说明（release body，可能为空）
  final String? notes;

  /// APK 直链（优先），拿不到则给发布页
  final String? downloadUrl;

  /// 这个结论来自哪个源
  final String? sourceName;

  /// 是否真的完成了检查（网络全失败时为 false）
  final bool checked;

  static const UpdateCheckResult none =
      UpdateCheckResult(hasUpdate: false, checked: false);
}

class UpdateService {
  UpdateService({http.Client? client, this.timeout = const Duration(seconds: 8)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  void close() => _client.close();

  /// 依次尝试各更新源，返回第一个成功的结果。
  Future<UpdateCheckResult> check() async {
    for (final src in kUpdateSources) {
      final r = await _trySource(src);
      if (r != null) return r;
    }
    return UpdateCheckResult.none;
  }

  Future<UpdateCheckResult?> _trySource(UpdateSource src) async {
    try {
      final resp = await _client.get(
        Uri.parse(src.apiUrl),
        headers: const {
          'Accept': 'application/json',
          'User-Agent': 'inkScroll',
        },
      ).timeout(timeout);

      if (resp.statusCode != 200) return null;

      // 有些镜像返回的是**数组**（releases 列表），有些返回单个对象。
      // 两种都兼容，否则换个源就解析不出东西。
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      final Map<String, dynamic>? rel = switch (decoded) {
        Map<String, dynamic> m => m,
        List l when l.isNotEmpty && l.first is Map<String, dynamic> =>
          l.first as Map<String, dynamic>,
        _ => null,
      };
      if (rel == null) return null;

      final tag = (rel['tag_name'] ?? rel['name'] ?? '').toString();
      final latest = SemVer.tryParse(tag);
      if (latest == null) return null;

      final current = SemVer.tryParse(kAppVersion) ?? const SemVer(0, 0, 0);

      return UpdateCheckResult(
        hasUpdate: latest > current,
        latest: latest,
        notes: (rel['body'] ?? rel['description'])?.toString(),
        downloadUrl: _pickDownload(rel) ?? src.fallbackPage,
        sourceName: src.name,
      );
    } catch (_) {
      // 超时 / DNS / JSON 异常都只是"这个源不可用"，继续试下一个
      return null;
    }
  }

  /// 从 assets 里挑一个 APK 直链；优先 arm64（绝大多数手机）。
  String? _pickDownload(Map<String, dynamic> rel) {
    final assets = rel['assets'];
    if (assets is! List) return null;
    String? arm64;
    String? any;
    for (final a in assets) {
      if (a is! Map) continue;
      final url =
          (a['browser_download_url'] ?? a['download_url'] ?? a['url'])
              ?.toString();
      final name = (a['name'] ?? '').toString().toLowerCase();
      if (url == null || !name.endsWith('.apk')) continue;
      any ??= url;
      if (name.contains('arm64-v8a')) arm64 = url;
    }
    return arm64 ?? any;
  }
}
