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
            child: FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('添加 WebDAV 库'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
              onPressed: () => _openLibrary(app, null),
            ),
          ),

          const Divider(height: 24),

          // ── 关于 ──
          _SectionHeader('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('inkScroll'),
            subtitle: Text('版本 0.3.0 · 本地与 NAS 漫画阅读器\n'
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
