/// 应用设置界面。
///
/// ## 为什么设置要单独一屏
///
/// 之前"从 NAS 导入"藏在书架右下角的导入菜单里，而它本质上不是
/// "导入一本书"，是**配置一个内容源**——放错地方了。
/// 现在把它挪到设置里，叫「添加 WebDAV 库」，语义就对上了。
///
/// 设置项按「会经常改的」排前面：
///   · 外观（主题）
///   · 在线库（WebDAV 连接管理 = 添加/删除 NAS）
///   · 关于
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/webdav/webdav_connection.dart';
import '../core/errors.dart';
import '../data/models/reader_settings.dart';
import 'external_link.dart';
import '../state/app_state.dart';
import 'webdav_browse_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  CacheStats? _cache;
  bool _cacheClearing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCache());
  }

  Future<void> _refreshCache() async {
    if (!mounted) return;
    try {
      final stats = await context.read<AppState>().cacheStats();
      if (!mounted) return;
      setState(() => _cache = stats);
    } catch (_) {
      // 统计失败不影响设置页
    }
  }

  String _cacheLabel(CacheStats? s) {
    if (s == null) return '正在统计…';
    if (s.total == 0) return '暂无缓存';
    return '共 ${CacheStats.human(s.total)}'
        '（网盘页 ${CacheStats.human(s.webdavBytes)}'
        ' · 解压 ${CacheStats.human(s.extractedBytes)}'
        ' · 封面 ${CacheStats.human(s.coverBytes)}）';
  }

  Future<void> _clearCache(AppState app) async {
    setState(() => _cacheClearing = true);
    try {
      await app.clearCache();
      await _refreshCache();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('缓存已清理。书架与网盘连接都还在。'),
          behavior: SnackBarBehavior.floating,
        ));
    } finally {
      if (mounted) setState(() => _cacheClearing = false);
    }
  }

  String _modeLabel(ReadingMode? m) => switch (m) {
        null => '自动（按内容判断）',
        ReadingMode.horizontal => '左右翻页',
        ReadingMode.verticalContinuous => '上下滑动',
      };

  Future<void> _pickDefaultMode(AppState app) async {
    final picked = await showModalBottomSheet<Object>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('自动（按内容判断）'),
              subtitle: const Text('长条图用上下滑动，普通页用左右翻页'),
              onTap: () => Navigator.of(ctx).pop(_autoValue),
            ),
            for (final m in ReadingMode.values)
              ListTile(
                leading: Icon(m.icon),
                title: Text(m.label),
                subtitle: Text(m.description),
                onTap: () => Navigator.of(ctx).pop(m),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await app.updateSettings(
      picked is ReadingMode
          ? app.settings.copyWith(defaultMode: picked)
          : app.settings.copyWith(clearDefaultMode: true),
    );
  }

  /// 哨兵值，表示用户选了"自动"
  static const String _autoValue = '__auto__';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final conns = app.webdavConnections.all();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── 外观 ──
          _SectionHeader('外观'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('主题'),
            subtitle: Text(_themeLabel(app.settings.themeMode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickTheme(app),
          ),

          const Divider(height: 24),

          // ── 阅读 ──
          _SectionHeader('阅读'),
          ListTile(
            leading: const Icon(Icons.swipe_outlined),
            title: const Text('默认翻页方式'),
            subtitle: Text(_modeLabel(app.settings.defaultMode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickDefaultMode(app),
          ),

          const Divider(height: 24),

          // ── 屏幕刷新率 ──
          _SectionHeader('屏幕刷新率'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: theme.hintColor,
                ),
                children: const [
                  TextSpan(
                    text: 'inkScroll 会主动向系统申请高刷新率，但 Android '
                        '默认只给系统允许列表里的应用开高刷。\n\n',
                  ),
                  TextSpan(
                    text: '需要你手动把本应用加进去：',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text: '\n打开 系统设置 → 显示与亮度 → 屏幕刷新率，'
                        '找到「使用高刷新率的应用」（有的机型叫「高刷新率应用列表」'
                        '或「选择应用」），把 inkScroll 打开。\n\n'
                        '常见机型位置：\n'
                        '· vivo / iQOO：设置 → 显示与亮度 → 屏幕刷新率 → '
                        '使用高刷新率的应用\n'
                        '· OPPO / 一加：设置 → 显示与亮度 → 屏幕刷新率 → 选择应用\n'
                        '· 小米 / Redmi：设置 → 显示 → 高刷新率 → 应用列表\n'
                        '· 华为 / 荣耀：设置 → 显示与亮度 → 屏幕刷新率\n\n',
                  ),
                  TextSpan(
                    text: '找不到这个选项也不影响使用',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text: '：不动它照样能正常看书，只是滑动可能停在 60Hz。'
                        '系统不允许应用自己绕过这个限制。',
                  ),
                ],
              ),
            ),
          ),

          const Divider(height: 24),

          // ── 通过压缩包导入 ──
          _SectionHeader('通过压缩包导入'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: theme.hintColor,
                ),
                children: const [
                  TextSpan(
                    text: '支持的格式：',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text: '.zip / .cbz（推荐）、.tar\n'
                        '包内图片支持 JPG / PNG / GIF / WebP / BMP / AVIF。\n\n',
                  ),
                  TextSpan(
                    text: '网盘上的压缩包也能直接导入：',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text: '不用先把压缩包下载到手机。导入时只读取压缩包的'
                        '目录结构，翻到哪一页才下载那一页 —— '
                        '200 MB 的包通常几秒就能建好，也不占手机空间。\n\n',
                  ),
                  TextSpan(
                    text: '需要一点耐心：',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text: '每本压缩包都要联网读目录并抽样测量图片尺寸，'
                        '所以导入一个几十本的库通常要几分钟。'
                        '进度条会显示当前处理到第几本；'
                        '请保持应用在前台、耐心等待，中途退出会中断这一批导入。',
                  ),
                ],
              ),
            ),
          ),

          const Divider(height: 24),

          // ── 存储 ──
          _SectionHeader('存储'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清理缓存'),
            subtitle: Text(_cacheLabel(_cache)),
            trailing: _cacheClearing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: (_cache?.total ?? 0) == 0
                        ? null
                        : () => _clearCache(app),
                    child: const Text('清理'),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '只清理「看过的页、解压产物、封面」这些可以随时重建的数据。'
              '书架、阅读进度、网盘连接与密码都不会被删除。',
              style: TextStyle(
                  fontSize: 11, height: 1.5, color: theme.hintColor),
            ),
          ),

          const Divider(height: 24),

          // ── 在线库 ──
          _SectionHeader('在线库（WebDAV 网盘）'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: 12,
                  height: 1.55,
                  color: theme.hintColor,
                ),
                children: const [
                  TextSpan(
                    text: '任何标准 WebDAV 服务都能连：'
                        '私有云（飞牛、群晖、威联通、TrueNAS）与商用网盘'
                        '（坚果云、Nextcloud、Alist 等）。\n'
                        '连接后选一个目录，它下面',
                  ),
                  TextSpan(
                    text: '每个含图片的子文件夹',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: '都会成为在线库里的一本书；目录里的 zip/cbz 压缩包也算一本。'),
                ],
              ),
            ),
          ),

          // 「合集」结构识别（默认开启）
          SwitchListTile(
            secondary: const Icon(Icons.account_tree_outlined),
            title: const Text('识别「合集」结构'),
            subtitle: const Text(
              '默认开启。如果所选目录下那一层文件夹只是分类（自己没有放图片），'
              '会再往下找一层 —— 用于识别「漫画根目录 / 某某合集 / 第一话」。',
            ),
            value: app.deepScanLibrary,
            onChanged: (v) => app.setDeepScanLibrary(v),
          ),

          if (conns.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                '还没有添加任何网盘。',
                style: TextStyle(fontSize: 13, color: theme.hintColor),
              ),
            )
          else
            ...conns.map((c) => ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(c.displayLabel),
                  subtitle: Text(
                    c.baseUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _confirmRemove(app, c),
                  ),
                  onTap: () => _openLibrary(app, c),
                )),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('添加 WebDAV 库'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                  ),
                  onPressed: () => _openLibrary(app, null),
                ),
                const SizedBox(height: 8),
                if (app.lastImportSummary != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '上次导入：${app.lastImportSummary}',
                    style: const TextStyle(fontSize: 11, height: 1.5),
                  ),
                ),
              ],
              OutlinedButton.icon(
                  icon: const Icon(Icons.public, size: 18),
                  label: const Text('不在家时怎么连？（远程访问）'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                  ),
                  onPressed: _showRemoteAccessHelp,
                ),
              ],
            ),
          ),

          const Divider(height: 24),

          // ── 关于 ──
          _SectionHeader('关于'),
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('帮助文档'),
            subtitle: const Text(
              '完整使用教程：导入、网盘连接、合集识别、阅读设置、'
              '远程访问与常见问题',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () async {
              final ok = await openHelpDocs();
              if (!ok && context.mounted) {
                _snack('没能打开浏览器。可以手动访问：$kHelpUrl', isError: true);
              }
            },
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('inkScroll'),
            subtitle: Text('版本 0.7.0 · 本地与网盘漫画阅读器\n'
                '不收集任何数据；只有你主动连接网盘时才有网络请求'),
            isThreeLine: true,
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('缓存说明'),
            subtitle: const Text(
              '从网盘看过的页会自动缓存到本地，断网也能看已缓存的；'
              '删除某本在线书时缓存一并清除。',
              style: TextStyle(fontSize: 12),
            ),
            isThreeLine: true,
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------

  /// 「不在家时怎么连」指引。
  ///
  /// 这是用户最常问的问题，而且答案在 App 之外（路由器端口映射）。
  /// 与其让他去搜，不如在这里写清楚 —— 不需要装任何额外软件。
  Future<void> _showRemoteAccessHelp() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.public, size: 20),
            SizedBox(width: 8),
            Text('不在家时怎么连'),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '有两条路，取决于你家的网络怎么接的。先做第 1 步判断，再选走哪条。',
                style: TextStyle(fontSize: 13, height: 1.55),
              ),
              SizedBox(height: 14),
              _HelpStep(
                n: '1',
                title: '判断有没有公网 IP',
                body: '在能上网的电脑上搜「IP」，看查到的地址和路由器「WAN 口地址」是否一致。'
                    '一致 → 有公网 IP，走方案 A；'
                    '是 100.64.x.x 开头、或光猫后面还套了一层路由器 → 走方案 B。',
              ),
              _HelpStep(
                n: 'A',
                title: '有公网 IP：路由器端口映射',
                body: '主路由器 → 端口转发 / 虚拟服务器：'
                    '外部端口（如 50068）→ 内网 NAS 的 5006（TCP）。'
                    '再配个 DDNS 域名（飞牛自带），地址填 https://你的域名:50068。\n'
                    '注意：光猫和路由器双层 NAT 时，两层都要做映射才通。',
              ),
              _HelpStep(
                n: 'B',
                title: '没有公网 IP：用隧道穿透',
                body: 'chmlfrp / frp / Cloudflare Tunnel 这类内网穿透，'
                    '由 NAS 主动向外连接，能绕过双层 NAT 和运营商限制。\n'
                    '关键三点：端口类型选 TCP（保留 TLS 端到端）、'
                    '本地端口填 5006、加密和压缩都关掉。',
              ),
              _HelpStep(
                n: 'C',
                title: '在 App 里填最终地址',
                body: '把隧道给的外网地址或你的域名填进来，'
                    '和局域网地址并存两条连接，在家/在外各用一条。',
              ),
              SizedBox(height: 10),
              _HelpWarn(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  static String _themeLabel(ThemeMode m) => switch (m) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
      };

  Future<void> _pickTheme(AppState app) async {
    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: ThemeMode.values
              .map((m) => ListTile(
                    leading: Icon(
                      switch (m) {
                        ThemeMode.system => Icons.settings_suggest_outlined,
                        ThemeMode.light => Icons.light_mode_outlined,
                        ThemeMode.dark => Icons.dark_mode_outlined,
                      },
                    ),
                    title: Text(_themeLabel(m)),
                    trailing: app.settings.themeMode == m
                        ? const Icon(Icons.check, size: 20)
                        : null,
                    onTap: () => Navigator.of(ctx).pop(m),
                  ))
              .toList(),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await app.updateSettings(app.settings.copyWith(themeMode: picked));
  }

  Future<void> _confirmRemove(AppState app, WebDavConnection c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条网盘连接？'),
        content: Text(
          '${c.displayLabel}\n${c.baseUrl}\n\n'
          '只删除连接与保存的密码，已经导入到在线库的书不受影响'
          '（但下次打开会提示连接已删除）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await app.webdavConnections.remove(c.id);
    if (mounted) setState(() {});
  }

  /// 打开 NAS 浏览器并把选中的目录**批量**导入在线库
  Future<void> _openLibrary(AppState app, WebDavConnection? preset) async {
    final selection = await showWebDavBrowser(
      context: context,
      store: app.webdavConnections,
      presetConnection: preset,
      // 库模式：选中的目录会被展开成"多个含图片的子文件夹"
      libraryMode: true,
    );
    if (selection == null || !mounted) return;

    // ★ 必须 try/catch：之前漏了，网络异常会变成**未捕获的异步错误**，
    //   界面毫无反应，看起来就像"点了没效果"。
    WebDavLibraryResult result;
    try {
      result = await app.importWebDavLibrary(
        connection: selection.connection,
        folderUrl: selection.folderUrl,
        folderName: selection.folderName,
      );
    } on AppError catch (e) {
      if (!mounted) return;
      _snack(e.message, isError: true);
      return;
    } catch (e) {
      if (!mounted) return;
      _snack('添加失败：$e', isError: true);
      return;
    }

    if (!mounted) return;
    if (result.isEmpty) {
      _snack(
        '「${result.emptyFolder ?? selection.folderName}」里没有找到含图片的子文件夹。\n'
        '请选一个"漫画根目录"——它下面每一话是一个子文件夹。',
        isError: true,
      );
      return;
    }
    // 失败时把**第一条完整原因**显示出来 —— 用户需要知道为什么；
    // release 包没有日志，这也是定位问题的唯一线索。
    final failPart = result.failures.isEmpty
        ? ''
        : '\n\n失败 ${result.failures.length} 个，首个原因：\n${result.failures.first}';
    _snack(
      '已添加到在线库：${result.imported} 本$failPart',
      isError: result.imported == 0 && result.failures.isNotEmpty,
    );
    setState(() {});
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade700 : null,
        duration: Duration(seconds: isError ? 12 : 4),
        behavior: SnackBarBehavior.floating,
        action: isError
            ? SnackBarAction(
                label: '知道了',
                textColor: Colors.white,
                onPressed: () =>
                    ScaffoldMessenger.of(context).hideCurrentSnackBar(),
              )
            : null,
      ));
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// 远程访问指引里的一步
class _HelpStep extends StatelessWidget {
  const _HelpStep({required this.n, required this.title, required this.body});

  final String n;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              n,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: const TextStyle(fontSize: 12, height: 1.55),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 安全提醒 —— 把 WebDAV 暴露到公网是有风险的，必须说清楚
class _HelpWarn extends StatelessWidget {
  const _HelpWarn();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFC53D).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFB8860B)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '把网盘服务暴露到公网有风险。请务必：'
              '① 建一个只读的 WebDAV 账号给阅读器；'
              '② 用非标准外部端口；'
              '③ 保持 HTTPS（自签也行）。',
              style: TextStyle(fontSize: 12, height: 1.55),
            ),
          ),
        ],
      ),
    );
  }
}