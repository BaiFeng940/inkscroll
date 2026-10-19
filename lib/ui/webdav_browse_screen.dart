/// NAS（WebDAV）连接与文件夹浏览界面。
///
/// ## 为什么用 WebDAV 而不是飞牛的私有 API
///
/// 飞牛 OS、群晖、威联通、Alist、Nextcloud、坚果云**都支持 WebDAV**。
/// 用通用协议的好处：
///   · 只写一次，全都能用；
///   · 不依赖厂商私有接口，对方升级也不会突然坏掉；
///   · 协议简单（PROPFIND 列目录 + GET 取文件），纯 Dart 可控。
///
/// ## 界面流程
///
///   ① 连接列表（没有则直接进表单）
///   ② 表单：地址 / 账号 / 密码 / 允许自签证书
///   ③ 文件夹浏览：面包屑 + 子目录列表
///   ④ 到有图片的目录 → 「导入此文件夹」
library;

import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../data/webdav/webdav_client.dart';
import '../data/webdav/webdav_connection.dart';
import '../importers/import_utils.dart';

/// 浏览结束后返回"要导入的文件夹"，由调用方执行导入
class WebDavFolderSelection {
  const WebDavFolderSelection({
    required this.connection,
    required this.folderUrl,
    required this.folderName,
  });

  final WebDavConnection connection;
  final String folderUrl;
  final String folderName;
}

Future<WebDavFolderSelection?> showWebDavBrowser({
  required BuildContext context,
  required WebDavConnectionStore store,
  WebDavConnection? presetConnection,
  bool libraryMode = false,
}) {
  return Navigator.of(context).push<WebDavFolderSelection>(
    MaterialPageRoute(
      builder: (_) => WebDavBrowseScreen(
        store: store,
        presetConnection: presetConnection,
        libraryMode: libraryMode,
      ),
    ),
  );
}

class WebDavBrowseScreen extends StatefulWidget {
  const WebDavBrowseScreen({
    super.key,
    required this.store,
    this.presetConnection,
    this.libraryMode = false,
  });

  final WebDavConnectionStore store;

  /// 从设置页点某条连接进来时，直接进它
  final WebDavConnection? presetConnection;

  /// 库模式：选中的目录会被展开成"多个含图片的子文件夹"批量导入
  final bool libraryMode;

  @override
  State<WebDavBrowseScreen> createState() => _WebDavBrowseScreenState();
}

class _WebDavBrowseScreenState extends State<WebDavBrowseScreen> {
  List<WebDavConnection> _connections = const [];
  WebDavConnection? _active;
  WebDavClient? _client;

  // 浏览栈：[(url, name)]，第一项是连接根目录
  final List<({String url, String name})> _stack = [];

  List<WebDavEntry> _entries = const [];
  bool _loading = false;
  bool _connecting = false;
  AppError? _error;

  @override
  void initState() {
    super.initState();
    _connections = widget.store.all();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.presetConnection != null) {
        _openConnection(widget.presetConnection!);
      } else if (_connections.length == 1) {
        // 只有一条连接时直接进去，少一次点击
        _openConnection(_connections.first);
      }
    });
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 连接
  // ------------------------------------------------------------------

  Future<void> _openConnection(WebDavConnection conn) async {
    _client?.close();
    _client = conn.createClient();
    setState(() {
      _active = conn;
      _entries = const [];
      _error = null;
      _stack
        ..clear()
        ..add((url: conn.baseUrl, name: conn.rootName));
    });
    await _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    final client = _client;
    if (client == null || _stack.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await client.list(_stack.last.url);
      if (!mounted) return;
      setState(() {
        // 目录在前，文件在后；同类按名称自然排序
        final dirs = list.where((e) => e.isDirectory).toList()
          ..sort((a, b) => compareByOriginalName(a.name, b.name));
        final files = list.where((e) => !e.isDirectory).toList()
          ..sort((a, b) => compareByOriginalName(a.name, b.name));
        _entries = [...dirs, ...files];
        _loading = false;
      });
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = GenericError('读取目录失败：$e');
        _loading = false;
      });
    }
  }

  void _enter(WebDavEntry dir) {
    _stack.add((url: dir.url, name: dir.name));
    setState(() => _entries = const []);
    _loadCurrent();
  }

  void _goTo(int index) {
    if (index < 0 || index >= _stack.length - 1) return;
    _stack.removeRange(index + 1, _stack.length);
    setState(() => _entries = const []);
    _loadCurrent();
  }

  /// 当前目录下的图片
  List<WebDavEntry> get _images => _entries
      .where((e) => !e.isDirectory && _isImageName(e.name))
      .toList();

  /// 库模式：只要当前目录有图片**或有子文件夹**就允许导入
  bool get _canImport {
    if (widget.libraryMode) {
      return _images.isNotEmpty || _entries.any((e) => e.isDirectory);
    }
    return _images.isNotEmpty;
  }

  void _startAddConnection() {
    setState(() {
      _active = null;
      _client?.close();
      _client = null;
      _entries = const [];
      _error = null;
      _stack.clear();
    });
  }

  // ------------------------------------------------------------------
  // 构建
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final canPop = _active == null || Navigator.of(context).canPop();
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 浏览中按返回 → 回上一级目录
        if (_stack.length > 1) {
          _goTo(_stack.length - 2);
        } else {
          _startAddConnection();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_active == null ? '连接 WebDAV' : _active!.displayLabel),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (_active != null && _stack.length > 1) {
                _goTo(_stack.length - 2);
              } else if (_active != null) {
                _startAddConnection();
              } else {
                Navigator.of(context).maybePop();
              }
            },
          ),
          actions: [
            if (_active != null)
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _loadCurrent,
              ),
          ],
        ),
        body: _active == null ? _buildConnectionChooser() : _buildBrowser(),
        bottomNavigationBar: _active != null && _canImport
            ? _buildImportBar()
            : null,
      ),
    );
  }

  // ---- 连接选择 / 表单 ----

  Widget _buildConnectionChooser() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_connections.isNotEmpty) ...[
          const Text('选择一个 WebDAV 网盘', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ..._connections.map((c) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
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
                    onPressed: () => _confirmDelete(c),
                  ),
                  onTap: () => _openConnection(c),
                ),
              )),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 8),
        ],
        _ConnectionForm(onSubmit: _saveAndOpen, busy: _connecting),
      ],
    );
  }

  Future<void> _confirmDelete(WebDavConnection c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条连接？'),
        content: Text(
          '${c.displayLabel}\n${c.baseUrl}\n\n'
          '只删除连接与保存的密码，已经导入到书架的书不受影响。',
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
    await widget.store.remove(c.id);
    if (!mounted) return;
    setState(() => _connections = widget.store.all());
  }

  Future<void> _saveAndOpen(WebDavConnection draft) async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      // ★ 先自动识别 http/https，再验证。
      //
      //   之前直接拿用户输入的地址去请求，而 `_normalizeBase` 默认补 http://，
      //   碰到只开 HTTPS 的 NAS（比如飞牛 5006）会被服务器直接掐断，
      //   用户看到的是"连接不上服务器"——**完全误导**，实际是协议选错了。
      final probe = await WebDavClient.resolveBaseUrl(
        input: draft.baseUrl,
        username: draft.username.isEmpty ? null : draft.username,
        password: draft.password.isEmpty ? null : draft.password,
        allowSelfSigned: draft.allowSelfSigned,
      );

      final resolved = draft.copyWith(baseUrl: probe.baseUrl);
      final conn = resolved.copyWith(lastUsedAt: DateTime.now());
      await widget.store.upsert(conn);
      if (!mounted) return;
      setState(() {
        _connections = widget.store.all();
        _connecting = false;
      });
      if (probe.switched) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('已自动识别为 ${Uri.parse(probe.baseUrl).scheme}://'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ));
      }
      await _openConnection(conn);
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _connecting = false;
      });
      _showError(e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _connecting = false);
      _showError(GenericError('连接失败：$e'));
    }
  }

  void _showError(AppError e) {
    if (!mounted) return;
    // 把技术细节也显示出来（比如 "HTTP 401" / "Connection closed"）——
    // 只给一句"连接不上"用户无从下手。
    final detail = e.technicalDetail;
    final text = (detail == null || detail.trim().isEmpty)
        ? e.message
        : '${e.message}\n\n技术细节：$detail';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 14),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: '知道了',
          textColor: Colors.white,
          onPressed: () =>
              ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        ),
      ));
  }

  // ---- 浏览器 ----

  Widget _buildBrowser() {
    return Column(
      children: [
        _buildBreadcrumb(),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _buildEntryList()),
        if (_error != null) _buildErrorBanner(_error!),
      ],
    );
  }

  Widget _buildBreadcrumb() {
    return Container(
      height: 42,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _stack.length,
        itemBuilder: (context, i) {
          final isLast = i == _stack.length - 1;
          return Row(
            children: [
              if (i > 0)
                const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
              InkWell(
                onTap: isLast ? null : () => _goTo(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  child: Text(
                    _stack[i].name,
                    style: TextStyle(
                      fontSize: 13,
                      color: isLast
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEntryList() {
    if (_entries.isEmpty && !_loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_open, size: 40, color: Colors.grey),
              const SizedBox(height: 12),
              Text(
                _error != null ? '读取失败' : '这个文件夹是空的',
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 6),
              const Text(
                '进入放图片的子目录再导入',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final e = _entries[i];
        if (e.isDirectory) {
          return ListTile(
            leading: const Icon(Icons.folder, color: Color(0xFFE8B84B)),
            title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _enter(e),
          );
        }
        final isImg = _isImageName(e.name);
        return ListTile(
          dense: true,
          leading: Icon(
            isImg ? Icons.image_outlined : Icons.insert_drive_file_outlined,
            size: 20,
            color: isImg ? null : Colors.grey,
          ),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: e.size == null
              ? null
              : Text(_humanSize(e.size!), style: const TextStyle(fontSize: 11)),
        );
      },
    );
  }

  Widget _buildErrorBanner(AppError e) {
    return Container(
      width: double.infinity,
      color: Colors.red.withValues(alpha: 0.08),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              e.message,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportBar() {
    final count = _images.length;
    final dirCount = _entries.where((e) => e.isDirectory).length;
    final name = _stack.isEmpty ? '文件夹' : _stack.last.name;
    final lib = widget.libraryMode;

    // 库模式下即使当前目录没有图片也可以导入 ——
    // 真正要导入的是**子文件夹**里的内容。
    final subtitle = lib
        ? (count > 0 && dirCount > 0
            ? '本目录 $count 张图 + $dirCount 个子文件夹，全部会成为在线库里的书'
            : count > 0
                ? '本目录 $count 张图，会成为在线库里的一本书'
                : '会扫描这里的 $dirCount 个子文件夹，每个含图片的都成为一本书')
        : '导入后需要联网阅读，看过的页会自动缓存';

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    lib ? name : '$name · $count 张图片',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: Icon(
                lib ? Icons.library_add_outlined : Icons.download_for_offline_outlined,
                size: 18,
              ),
              label: Text(lib ? '添加为库' : '导入'),
              onPressed: () {
                final conn = _active;
                if (conn == null) return;
                Navigator.of(context).pop(WebDavFolderSelection(
                  connection: conn,
                  folderUrl: _stack.last.url,
                  folderName: _stack.last.name,
                ));
              },
            ),
          ],
        ),
      ),
    );
  }

  static bool _isImageName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = name.substring(dot).toLowerCase();
    return kImageExtensions.contains(ext) ||
        kUnsupportedImageExtensions.contains(ext);
  }

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

// ---------------------------------------------------------------------------
// 连接表单
// ---------------------------------------------------------------------------

class _ConnectionForm extends StatefulWidget {
  const _ConnectionForm({required this.onSubmit, required this.busy});

  final Future<void> Function(WebDavConnection draft) onSubmit;
  final bool busy;

  @override
  State<_ConnectionForm> createState() => _ConnectionFormState();
}

class _ConnectionFormState extends State<_ConnectionForm> {
  final _label = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _allowSelfSigned = false;
  bool _obscure = true;

  @override
  void dispose() {
    _label.dispose();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    widget.onSubmit(WebDavConnection(
      id: WebDavConnectionStore.newId(),
      label: _label.text.trim(),
      baseUrl: url,
      username: _user.text.trim(),
      password: _pass.text,
      allowSelfSigned: _allowSelfSigned,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '添加 WebDAV 网盘',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '任何标准 WebDAV 服务都能连：私有云（飞牛 / 群晖 / 威联通）'
          '与商用网盘（坚果云 / Nextcloud / Alist 等）。\n'
          '百度网盘、阿里云盘这类**不自带 WebDAV** 的网盘，'
          '需要先用 Alist 之类的网关转成 WebDAV 再连。',
          style: TextStyle(fontSize: 12, color: theme.hintColor, height: 1.5),
        ),
        const SizedBox(height: 16),

        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '服务器地址',
            hintText: '192.168.1.10:5006',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link),
            helperText: '飞牛 OS：设置 → 文件服务 → WebDAV（默认端口 5005 / 5006）'
                '\n只填 IP:端口 也可以，http/https 会自动识别',
            helperMaxLines: 3,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _label,
          decoration: const InputDecoration(
            labelText: '备注名（可选）',
            hintText: '家里的飞牛',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.label_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _user,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '用户名',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pass,
          obscureText: _obscure,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: '密码',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          value: _allowSelfSigned,
          onChanged: (v) => setState(() => _allowSelfSigned = v),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('允许自签名证书', style: TextStyle(fontSize: 13)),
          subtitle: const Text(
            '自建网盘的 HTTPS 多为自签证书。'
            '只在你自己信任的家庭网络里打开；局域网内直接用 http:// 更省事。',
            style: TextStyle(fontSize: 11),
          ),
        ),

        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lightbulb_outline,
                  size: 18, color: theme.hintColor),
              const SizedBox(width: 8),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.55,
                      color: theme.hintColor,
                    ),
                    children: const [
                      TextSpan(text: '建议单独建一个'),
                      TextSpan(
                        text: '只读',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: '的 WebDAV 账号给阅读器用。\n'
                            '这样就算密码泄露，对方也只能读到你指定的那个目录 —— '
                            '比任何加密都实用。',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            icon: widget.busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering),
            label: Text(widget.busy ? '正在连接…' : '测试并连接'),
            onPressed: widget.busy ? null : _submit,
          ),
        ),
      ],
    );
  }
}
