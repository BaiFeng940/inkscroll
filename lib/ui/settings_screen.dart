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
import '../state/app_state.dart';
import 'webdav_browse_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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

          // ── 在线库 ──
          _SectionHeader('在线库（NAS / WebDAV）'),
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
                    text: '支持飞牛 OS、群晖、威联通、Alist、Nextcloud 等所有 '
                        'WebDAV 服务。\n添加后选中一个目录，它下面',
                  ),
                  TextSpan(
                    text: '每个含图片的子文件夹',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: '都会成为在线库里的一本书。'),
                ],
              ),
            ),
          ),

          if (conns.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                '还没有添加任何 NAS。',
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
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('inkScroll'),
            subtitle: Text('版本 0.3.2 · 本地与 NAS 漫画阅读器\n'
                '不收集任何数据；只有你主动连接 NAS 时才有网络请求'),
            isThreeLine: true,
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('缓存说明'),
            subtitle: const Text(
              '从 NAS 看过的页会自动缓存到本地，断网也能看已缓存的；'
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
                '能做到，而且不需要装任何额外软件 —— '
                '只要家里的宽带分到了公网 IP，在路由器上做一次端口映射即可。',
                style: TextStyle(fontSize: 13, height: 1.55),
              ),
              SizedBox(height: 14),
              _HelpStep(
                n: '1',
                title: '确认有公网 IP',
                body: '在能上网的电脑上搜「IP」，看查到的地址和路由器「WAN 口地址」是否一致。'
                    '如果一致 → 有公网 IP；如果是 100.64.x.x 开头 → 运营商大内网，这条路不通。',
              ),
              _HelpStep(
                n: '2',
                title: '在路由器上做端口映射',
                body: '主路由器 → 端口转发 / 虚拟服务器：'
                    '外部端口（比如 50068）→ 内网 192.168.10.105:5006（TCP）。'
                    '建议用非标准的外部端口，减少被扫描。',
              ),
              _HelpStep(
                n: '3',
                title: '配一个 DDNS 域名',
                body: '家用宽带公网 IP 会变。飞牛 OS 自带 DDNS（设置 → 网络 → DDNS），'
                    '也可以。拿到形如 nas.example.com 的域名。',
              ),
              _HelpStep(
                n: '4',
                title: '在 App 里填域名',
                body: '地址填 https://你的域名:外部端口，'
                    '和局域网里填的地址并存两条连接，在家/在外各用一条。',
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
        title: const Text('删除这条 NAS 连接？'),
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
    final failPart = result.failures.isEmpty
        ? ''
        : '\n失败 ${result.failures.length} 个：${result.failures.take(2).join('; ')}';
    _snack('已添加到在线库：${result.imported} 本$failPart');
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
              '把 NAS 暴露到公网有风险。请务必：'
              '① 在 NAS 上建一个只读的 WebDAV 账号给阅读器；'
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