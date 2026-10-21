/// 版本号与更新源的**唯一真相来源**。
///
/// `kAppVersion` 必须和 `pubspec.yaml` 里的 `version:` 保持一致 ——
/// 手写两份必然会漂移，所以 `test/app_version_test.dart` 会读 pubspec
/// 断言两者相等，改了版本号忘了改这里测试就会红。
library;

/// 当前应用版本（不含 build number）
const String kAppVersion = '0.11.2';

// ---------------------------------------------------------------------------
// 更新源
// ---------------------------------------------------------------------------
//
// 顺序即优先级：**国内镜像优先**，GitHub 兜底。
// 海外网络访问 GitHub API 常常超时，而商用产品的更新检查不能让用户
// 卡在"检查更新中…"十几秒。
//
// GitCode 的仓库路径在建立镜像后是 <用户名>/<仓库名>。
// 如果以后换了账号或仓库名，只改这三行即可。

/// GitCode 镜像的 owner（建立镜像后确认）
const String kGitCodeOwner = 'BaiFeng940';

/// GitCode 镜像的仓库名
const String kGitCodeRepo = 'inkscroll';

/// GitHub 上游 owner
const String kGitHubOwner = 'BaiFeng940';

/// GitHub 上游仓库名
const String kGitHubRepo = 'inkscroll';

/// 一次更新检查可能的来源
class UpdateSource {
  const UpdateSource({
    required this.name,
    required this.apiUrl,
    required this.fallbackPage,
  });

  /// 展示用名字
  final String name;

  /// 返回 release 列表/最新 release 的 JSON 接口
  final String apiUrl;

  /// 拿不到 API 时给用户手动下载的页面
  final String fallbackPage;
}

/// 按优先级排列的更新源
///
/// ⚠️ GitCode 的接口和 GitHub 不一样，这里踩过坑：
///   · `api.gitcode.com/api/v5/.../releases/latest` → **400**（该路径不存在）
///   · 真正可用的是 `gitcode.com/api/v5/.../releases`，返回的是**数组**
///   · `api.gitcode.com/api/v5/repos/{owner}/{repo}` 需要鉴权（401）
/// 所以 GitCode 用后者，并且 `UpdateService` 必须能处理数组返回体。
const List<UpdateSource> kUpdateSources = [
  UpdateSource(
    name: 'GitCode（国内镜像）',
    apiUrl:
        'https://gitcode.com/api/v5/repos/$kGitCodeOwner/$kGitCodeRepo/releases',
    fallbackPage: 'https://gitcode.com/$kGitCodeOwner/$kGitCodeRepo/releases',
  ),
  UpdateSource(
    name: 'GitHub',
    apiUrl:
        'https://api.github.com/repos/$kGitHubOwner/$kGitHubRepo/releases/latest',
    fallbackPage:
        'https://github.com/$kGitHubOwner/$kGitHubRepo/releases/latest',
  ),
];

/// 仓库主页（设置页「帮助/反馈」用得上）
const String kRepoHome = 'https://github.com/$kGitHubOwner/$kGitHubRepo';
const String kHelpUrl = 'https://baifeng940.github.io/inkscroll/help/';
