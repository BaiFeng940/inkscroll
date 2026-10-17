/// 书架 / 最近阅读 / 收藏 / 搜索 + 导入入口。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/errors.dart';
import '../data/byte_store.dart';
import '../data/importer.dart';
import '../data/models/book_meta.dart';
import '../data/saf_folder.dart';
import '../importers/import_utils.dart';
import '../state/app_state.dart';
import 'image_order_sheet.dart';
import 'prepare_screen.dart';
import 'reader/reader_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _tabs.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 导入：来源选择 → 路由 → 导入 → 处理密码 → 进入阅读器
  // ------------------------------------------------------------------
  Future<void> _showImportSheet() async {
    final app = context.read<AppState>();
    final choice = await showModalBottomSheet<_ImportChoice>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('导入内容',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
            ),
            ..._ImportChoice.values.map((c) => ListTile(
                  leading: Icon(c.icon),
                  title: Text(c.title),
                  subtitle: Text(c.subtitle, style: const TextStyle(fontSize: 12)),
                  onTap: () => Navigator.of(ctx).pop(c),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (choice == null || !mounted) return;

    SourcePick? pick;
    switch (choice) {
      case _ImportChoice.folder:
        pick = await _pickFolder(app);
        if (pick == null) return;

      case _ImportChoice.archive:
        final res = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: false,
        );
        final path = res?.files.single.path;
        if (path == null) return;
        pick = SourcePick(
          kind: SourcePickKind.file,
          displayName: p.basenameWithoutExtension(path),
          sourceId: ByteStore.newBookId(),
          path: path,
          sizeBytes: res?.files.single.size,
        );

      case _ImportChoice.images:
        final res = await FilePicker.platform.pickFiles(
          type: FileType.image,
          allowMultiple: true,
        );
        final picked =
            res?.files.map((f) => f.path).whereType<String>().toList() ?? const [];
        if (picked.isEmpty) return;

        // ★ 先把顺序给用户看一眼 —— 默认已按文件名自然排序，
        //   用户可以上下移动微调。这样"排序不对"就不再需要猜。
        if (!mounted) return;
        final sorted = [...picked]..sort(
            (a, b) => compareByOriginalName(p.basename(a), p.basename(b)));
        final adjusted = await showImageOrderSheet(
          context: context,
          paths: sorted,
          title: '确认阅读顺序',
        );
        if (adjusted == null || adjusted.isEmpty) return;

        // 判断用户是否真的调过顺序（没调就仍走自动排序，语义更清晰）
        final unchanged = adjusted.length == sorted.length &&
            List.generate(adjusted.length, (i) => adjusted[i] == sorted[i])
                .every((x) => x);

        pick = SourcePick(
          kind: SourcePickKind.files,
          displayName: adjusted.length == 1
              ? p.basenameWithoutExtension(adjusted.first)
              : '图片集（${adjusted.length} 张）',
          sourceId: ByteStore.newBookId(),
          paths: adjusted,
          manuallyOrdered: !unchanged,
        );

      case _ImportChoice.url:
        final url = await _askForText(
          title: '输入网页链接',
          hint: 'https://example.com/article',
        );
        if (url == null || url.trim().isEmpty) return;
        pick = SourcePick(
          kind: SourcePickKind.url,
          displayName: Uri.tryParse(url)?.host ?? '网页',
          sourceId: ByteStore.newBookId(),
          uri: Uri.tryParse(url.trim()),
        );
    }

    if (!mounted) return;
    await _runImport(app, pick);
  }

  /// 选择文件夹。
  ///
  /// ★ Android 走**自研的 SAF 插件**（`lib/data/saf_folder.dart` +
  ///   `SafFolderPlugin.kt`），不再用 `file_picker.getDirectoryPath()`。
  ///
  ///   原因（实测确认）：`getDirectoryPath()` 在 Android 11+ 上不可用 ——
  ///     · 系统不允许把存储根 / `Download` 授权给应用（界面直接显示
  ///       "Can't use this folder / To protect your privacy…"）；
  ///     · `file_picker` 的 `content://` → 路径转换被
  ///       `if (Build.VERSION.SDK_INT < R)` 包住，Android 11+ 直接返回 null。
  ///   两者叠加的结果就是"选了文件夹却什么都没发生"。
  ///
  ///   自研 SAF 不试图转路径，而是**直接读内容**并复制进应用目录，
  ///   顺便让后续阅读变成纯本地文件 I/O。
  Future<SourcePick?> _pickFolder(AppState app) async {
    final bookId = ByteStore.newBookId();

    if (SafFolder.isSupported) {
      final destDir = app.store.folderPathFor(bookId);
      final result = await SafFolder.pickAndCopy(
        destDir: destDir,
        extensions: kImportableExtensions.toList(),
      );

      if (result.cancelled) return null;
      if (result.errorMessage != null) {
        _snack('选择文件夹失败：${result.errorMessage}', isError: true);
        return null;
      }
      if (result.copied == 0) {
        _snack(
          '这个文件夹里没有可读取的图片或文本'
          '${result.total > 0 ? '（共扫描到 ${result.total} 个文件，都不受支持）' : ''}',
          isError: true,
        );
        return null;
      }
      if (result.skipped > 0) {
        _snack('已导入 ${result.copied} 个文件，跳过 ${result.skipped} 个不支持的文件');
      }

      return SourcePick(
        kind: SourcePickKind.folder,
        displayName: result.folderName.isEmpty ? '文件夹' : result.folderName,
        sourceId: bookId,
        path: destDir,
        alreadyLocal: true,
      );
    }

    // 非 Android（桌面 / iOS）：沿用插件提供的目录路径
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || dir.isEmpty) return null;
    return SourcePick(
      kind: SourcePickKind.folder,
      displayName: p.basename(dir),
      sourceId: bookId,
      path: dir,
    );
  }

  Future<void> _runImport(AppState app, SourcePick pick) async {
    try {
      final meta = await app.importFrom(pick);
      if (!mounted) return;
      _snack('导入成功：${meta.title}（${meta.pageCount} 页）');
      await _openBook(meta);
    } on PasswordPromptNeeded catch (e) {
      if (!mounted) return;
      final pwd = await _askForText(
        title: '压缩包已加密',
        hint: '请输入密码',
        message: e.attempt > 1 ? '上次输入的密码不正确，请重试' : null,
      );
      if (pwd == null || pwd.isEmpty) return;
      try {
        final meta = await app.importWithPassword(pick, pwd);
        if (!mounted) return;
        _snack('导入成功：${meta.title}');
        await _openBook(meta);
      } on AppError catch (err) {
        if (!mounted) return;
        _snack(err.message, isError: true);
      }
    } on AppError catch (e) {
      if (!mounted) return;
      _snack(e.message, isError: true);
    } catch (e) {
      if (!mounted) return;
      _snack('导入失败：$e', isError: true);
    }
  }

  Future<void> _openBook(BookMeta book) async {
    final app = context.read<AppState>();

    // ★ 首次打开压缩包：先把解压做完再进阅读器。
    //
    // 为什么不等"边读边解压"：DEFLATE 在主 isolate 上跑，
    // 边读边解压 = 每次翻页都在主线程解压，用户体感就是"很慢、卡"。
    // 预先解压之后每页都是直接文件 I/O（几毫秒），代价只是第一次等一次。
    if (app.needsPrepare(book) && mounted) {
      final proceed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PrepareScreen(
            title: book.title,
            run: (onProgress) => app.prepareBook(book, onProgress: onProgress),
          ),
        ),
      );
      // proceed == null 表示用户按返回键退出
      if (proceed != true || !mounted) {
        if (mounted) await app.refreshBooks();
        return;
      }
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          book: book,
          settings: app.settings,
          prefs: app.prefsForReader,
          resolveDocument: () => app.buildDocument(book),
          extraction: app.extraction,
          store: app.store,
          onSettingsChanged: (s) {
            // 设置变更要落盘：更新全局设置 + 记住这本书用的模式
            unawaited(app.updateSettings(s));
            unawaited(app.rememberModeForBook(book.id, s.mode));
          },
        ),
      ),
    );
    if (mounted) await app.refreshBooks();
  }

  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    if (!app.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('inkScroll'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '全部'),
            Tab(text: '最近'),
            Tab(text: '收藏'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => setState(() {
              _query = _query.isEmpty ? ' ' : '';
              _searchController.text = '';
              _query = '';
            }),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: '搜索书名',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _BookGrid(books: app.search(_query), onOpen: _openBook, onChanged: () => app.refreshBooks(), onDelete: _confirmDelete),
                _BookGrid(books: app.recentBooks, onOpen: _openBook, onChanged: () => app.refreshBooks(), onDelete: _confirmDelete),
                _BookGrid(books: _filter(app.favorites, _query), onOpen: _openBook, onChanged: () => app.refreshBooks(), onDelete: _confirmDelete),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showImportSheet,
        icon: const Icon(Icons.add),
        label: const Text('导入'),
      ),
    );
  }

  List<BookMeta> _filter(List<BookMeta> list, String q) {
    if (q.trim().isEmpty) return list;
    final lower = q.toLowerCase();
    return list.where((b) => b.title.toLowerCase().contains(lower)).toList();
  }

  Future<void> _confirmDelete(BookMeta book) async {
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定要删除「${book.title}」吗？\n'
            '本地导入的文件也会一并删除，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await app.deleteBook(book.id);
      if (mounted) _snack('已删除');
    }
  }

  Future<String?> _askForText({
    required String title,
    required String hint,
    String? message,
  }) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message != null) ...[
              Text(message, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              const SizedBox(height: 10),
            ],
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: hint),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('确定')),
        ],
      ),
    );
  }

  void _snack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : null,
        duration: Duration(seconds: isError ? 6 : 3),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _BookGrid extends StatelessWidget {
  const _BookGrid({
    required this.books,
    required this.onOpen,
    required this.onChanged,
    required this.onDelete,
  });

  final List<BookMeta> books;
  final Future<void> Function(BookMeta) onOpen;
  final Future<void> Function() onChanged;
  final Future<void> Function(BookMeta) onDelete;

  @override
  Widget build(BuildContext context) {
    if (books.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '书架还是空的。\n点右下角「导入」添加内容。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 170,
        childAspectRatio: 0.62,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: books.length,
      itemBuilder: (ctx, i) => _BookCard(
        book: books[i],
        onOpen: onOpen,
        onChanged: onChanged,
        onDelete: onDelete,
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.onOpen,
    required this.onChanged,
    required this.onDelete,
  });

  final BookMeta book;
  final Future<void> Function(BookMeta) onOpen;
  final Future<void> Function() onChanged;
  final Future<void> Function(BookMeta) onDelete;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => onOpen(book),
      onLongPress: () => _showActions(context, app),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _Thumbnail(book: book, app: app),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          Text(
            '${book.pageCount} 页 · ${_kindLabel(book.kind)}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  String _kindLabel(BookKind kind) => switch (kind) {
        BookKind.comic => '漫画',
        BookKind.novel => '小说',
        BookKind.mixed => '混合',
        BookKind.pdf => 'PDF',
        BookKind.web => '网页',
        BookKind.doc => '文档',
      };

  Future<void> _showActions(BuildContext context, AppState app) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: Icon(book.isFavorite ? Icons.star : Icons.star_border),
              title: Text(book.isFavorite ? '取消收藏' : '收藏'),
              onTap: () => Navigator.of(ctx).pop('favorite'),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('详情'),
              onTap: () => Navigator.of(ctx).pop('info'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('删除', style: TextStyle(color: Colors.redAccent)),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );

    if (action == null) return;

    // showModalBottomSheet 是 async gap：之后再用 context 必须先确认还挂载着
    if (!context.mounted) return;

    switch (action) {
      case 'rename':
        if (!context.mounted) return;
        final controller = TextEditingController(text: book.title);
        final name = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('重命名'),
            content: TextField(controller: controller, autofocus: true),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(controller.text),
                  child: const Text('保存')),
            ],
          ),
        );
        if (name != null && name.trim().isNotEmpty) {
          await app.rename(book.id, name.trim());
          await onChanged();
        }
      case 'favorite':
        await app.toggleFavorite(book.id);
        await onChanged();
      case 'info':
        final size = await app.store.sizeOfBook(book.id);
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(book.title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('页数：${book.pageCount}'),
                Text('章节：${book.chapterCount}'),
                Text('类型：${_kindLabel(book.kind)}'),
                Text('占用：${ByteStore.humanSize(size)}'),
                Text('导入时间：${_fmt(book.importedAt)}'),
                Text('最近阅读：${book.lastReadAt == null ? '从未' : _fmt(book.lastReadAt!)}'),
                if (book.description != null) ...[
                  const SizedBox(height: 8),
                  Text(book.description!, style: const TextStyle(fontSize: 12)),
                ],
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(), child: const Text('关闭')),
            ],
          ),
        );
      case 'delete':
        await onDelete(book);
    }
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// 封面缩略图。没有封面时显示一个按书名哈希配色的占位。
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.book, required this.app});

  final BookMeta book;
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final cover = book.coverPath;
    if (cover != null && File(cover).existsSync()) {
      return Image.file(File(cover), fit: BoxFit.cover, cacheWidth: 360);
    }
    // 占位封面：书名首字 + 哈希配色
    final hash = book.title.hashCode;
    final hue = (hash % 360).abs().toDouble();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue, 0.35, 0.32).toColor(),
            HSLColor.fromAHSL(1, (hue + 40) % 360, 0.35, 0.18).toColor(),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Text(
          book.title.characters.firstOrNull ?? '?',
          style: const TextStyle(
              fontSize: 34, color: Colors.white70, fontWeight: FontWeight.w200),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
enum _ImportChoice {
  folder,
  archive,
  images,
  url;

  String get title => switch (this) {
        _ImportChoice.folder => '选择文件夹',
        _ImportChoice.archive => '选择压缩包',
        _ImportChoice.images => '选择图片（可多选）',
        _ImportChoice.url => '输入网页链接',
      };

  String get subtitle => switch (this) {
        _ImportChoice.folder => '文件夹内图片自动成章，文本自动分章分页',
        _ImportChoice.archive => '支持 zip / tar；rar / 7z 需先转换',
        _ImportChoice.images => '直接按选择顺序生成一本漫画',
        _ImportChoice.url => '抓取网页正文（需要接入 dio + html，见代码注释）',
      };

  IconData get icon => switch (this) {
        _ImportChoice.folder => Icons.folder_open,
        _ImportChoice.archive => Icons.archive_outlined,
        _ImportChoice.images => Icons.image_outlined,
        _ImportChoice.url => Icons.link,
      };
}
