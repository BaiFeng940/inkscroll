/// 全局应用状态：书架、设置、导入、文档装载。
///
/// 用 Provider + ChangeNotifier（见 DESIGN.md §1.4 的选型理由）：
///   - 阅读器状态天然是"长生命周期、频繁小幅变更的控制器"，ChangeNotifier 最贴合；
///   - 书架与设置是全局单例，直接 provide；
///   - 无代码生成、零额外概念 —— 这是"最容易实现"的路径。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../data/archive/tar_archive_source.dart';
import '../data/archive_extractor.dart';
import '../data/archive/zip_archive_source.dart';
import '../data/byte_source.dart';
import '../data/byte_store.dart';
import '../data/archive/archive_source.dart';
import '../data/importer.dart';
import '../data/models/book_meta.dart';
import '../data/models/reader_settings.dart';
import '../data/pdf/pdf_native.dart';
import '../data/prefs_store.dart';
import '../data/update_service.dart';
import '../data/webdav/webdav_connection.dart';
import '../importers/import_router.dart';
import '../importers/webdav_archive_importer.dart';
import '../importers/webdav_folder_importer.dart';
import '../reader/cover_generator.dart';
import '../reader/document.dart';
import '../reader/pdf_page_resolver.dart';
import '../reader/document_codec.dart';
import '../reader/page_cache.dart';
import '../reader/webdav_archive_resolver.dart';
import '../reader/webdav_page_resolver.dart';

class AppState extends ChangeNotifier {
  AppState(this._prefs);

  final PrefsStore _prefs;

  ByteStore? _store;
  ImportRouter? _router;

  /// 后台解压管理器：把压缩包解压到 app 缓存，让翻页变成直接读文件
  ExtractionManager? _extraction;

  /// NAS 连接表（凭据持久化在这里）
  WebDavConnectionStore? _webdavStore;

  WebDavConnectionStore get webdavConnections => _webdavStore!;

  ByteStore get store => _store!;
  ImportRouter get router => _router!;
  ExtractionManager get extraction => _extraction!;

  /// 阅读器需要直接读写进度，所以要把 PrefsStore 交给它
  PrefsStore get prefsForReader => _prefs;

  List<BookMeta> books = [];
  ReaderSettings settings = const ReaderSettings();
  bool ready = false;

  /// 当前导入进度（null 表示没有进行中的导入）
  ImportProgressState? importProgress;

  Future<void> bootstrap() async {
    _store = await ByteStore.open();
    // 隐私：确保导入的漫画不会被系统相册扫描到
    await _store!.ensureNoMedia();
    _router = ImportRouter(store: _store!);
    _extraction = ExtractionManager(store: _store!);
    _webdavStore = WebDavConnectionStore(_prefs.prefs);
    books = _prefs.loadBooks();
    settings = _prefs.loadSettings();
    deepScanLibrary = _prefs.loadDeepScan();
    ready = true;
    notifyListeners();

    // 给历史数据补封面（老版本导入的书没有 coverPath）。
    // 后台跑，不阻塞启动。
    ensureAllCovers();
  }

  // ------------------------------------------------------------------
  // WebDAV / NAS 导入
  // ------------------------------------------------------------------

  /// 从 NAS 的一个文件夹导入成书。
  ///
  /// **只列目录，不下载图片** —— 打开只需要一次 PROPFIND，
  /// 之后每页在阅读时按需拉取并落盘缓存。
  Future<BookMeta> importWebDav({
    required WebDavConnection connection,
    required String folderUrl,
    required String folderName,
  }) async {
    final pick = SourcePick(
      kind: SourcePickKind.webdav,
      displayName: folderName.isEmpty ? connection.rootName : folderName,
      sourceId: ByteStore.newBookId(),
      uri: Uri.tryParse(folderUrl),
      webdavConnectionId: connection.id,
      webdavFolderUrl: folderUrl,
      webdavFolderName: folderName,
    );

    try {
      final book = await _runImport(pick, password: null);
      await webdavConnections.touch(connection.id);
      return book;
    } finally {
      _setProgress(null, '');
    }
  }

  /// **把 NAS 上一个文件夹下"所有含图片的子文件夹"批量导入在线库。**
  ///
  /// 这是「添加 WebDAV 库」的核心：用户只选一次目录，我们把里面
  /// 每一话 / 每一本都建成一本书，全部进「在线库」。
  ///
  /// 返回扫描到的目录数、成功导入数与失败信息。
  Future<WebDavLibraryResult> importWebDavLibrary({
    required WebDavConnection connection,
    required String folderUrl,
    required String folderName,
    void Function(int done, int total, String label)? onScanProgress,
    void Function(int done, int total, String label)? onImportProgress,
  }) async {
    final client = connection.createClient();
    List<WebDavComicCandidate> candidates;
    try {
      _setProgress(0, '正在扫描网盘目录…');
      candidates = await WebDavFolderImporter.scanLibrary(
        client,
        folderUrl,
        deepScan: deepScanLibrary,
        onProgress: (done, total, name) {
          _setProgress(
            total == 0 ? 0 : done / total * 0.4,
            '正在扫描 $done/$total：$name',
          );
          onScanProgress?.call(done, total, name);
        },
      );

      lastImportSummary = '扫描到 ${candidates.length} 个候选'
          '（压缩包 ${candidates.where((c) => c.isArchive).length}）';
      if (candidates.isEmpty) {
        _setProgress(null, '');
        return WebDavLibraryResult(
          scanned: 0,
          imported: 0,
          failures: const [],
          emptyFolder: folderName,
        );
      }

      // ── 去重：已经导入过的目录直接跳过 ──
      //
      // 之前重复点「添加为库」会把同一个目录再导一遍，产生一堆重复的书，
      // 用户还以为是加载慢。按 (连接, 目录地址) 判重。
      final existing = <String>{
        for (final b in books)
          if (b.source case WebDavSource(:final connectionId, :final folderUrl))
            '$connectionId|${folderUrl.replaceAll(RegExp(r'/+$'), '').toLowerCase()}',
      };
      String keyOf(String connId, String url) =>
          '$connId|${url.replaceAll(RegExp(r'/+$'), '').toLowerCase()}';

      final fresh = <WebDavComicCandidate>[];
      var skipped = 0;
      for (final c in candidates) {
        if (existing.contains(keyOf(connection.id, c.url))) {
          skipped++;
        } else {
          fresh.add(c);
        }
      }

      lastImportSummary = '$lastImportSummary；待导 ${fresh.length}，跳过 $skipped';
      if (fresh.isEmpty) {
        _setProgress(null, '');
        return WebDavLibraryResult(
          scanned: candidates.length,
          imported: 0,
          failures: const [],
          allAlreadyAdded: true,
          skipped: skipped,
        );
      }

      final imported = <BookMeta>[];
      final failures = <String>[];
      final pending = <BookMeta>[];

      // 整批期间不生成封面，结束后统一在后台补（见 _scheduleCover 注释）
      _deferCovers = true;
      try {
        // ── 并发导入 ──
        //
        // 之前是串行：一本 2~3 秒，170 本就要 7 分钟，用户全程干等。
        // 而每本书的耗时**几乎全是网络往返**（EOCD、中央目录、几张小图的
        // HTTP Range），本地 CPU 基本闲着 —— 串行动作等于把延迟累加。
        //
        // 用固定大小的 worker 池跑，结果按原始下标放回 slots，
        // 保证**书架顺序和目录顺序一致**（并发完成顺序不可控）。
        //
        // 并发度取 4：再高会被 HttpClient 的 maxConnectionsPerHost（6）
        // 排队，且更容易触碰网盘的软限流。每本书内部还有自己的抽样并发，
        // 因此实际同时在飞的请求约为 4 × 3 ≈ 12 个。
        final results = List<BookMeta?>.filled(fresh.length, null);
        final perSlotBatch = List<List<BookMeta>?>.filled(fresh.length, null);
        var nextIndex = 0;
        var finished = 0;

        Future<void> worker() async {
          while (true) {
            final i = nextIndex++;
            if (i >= fresh.length) return;
            final c = fresh[i];
            final localBatch = <BookMeta>[];
            try {
              if (c.isArchive) {
                // ★ 网盘上的压缩包：一本书 = 一个包。
                //   只读中央目录 + 少量样本，不解压整包。
                final bookId = ByteStore.newBookId();
                final doc = await WebDavArchiveImporter.buildDocument(
                  client: client,
                  connectionId: connection.id,
                  archiveUrl: c.url,
                  archiveName: c.name,
                  knownSize: c.archiveSize,
                );
                await DocumentCodec.save(store.bookDir(bookId), doc);
                final meta = BookMeta(
                  id: bookId,
                  title: c.name,
                  kind: BookKind.comic,
                  source: WebDavArchiveSource(
                    connectionId: connection.id,
                    archiveUrl: c.url,
                    archiveName: c.name,
                    archiveSize: c.archiveSize,
                  ),
                  pageCount: doc.pageCount,
                  chapterCount: doc.chapterCount,
                  importedAt: DateTime.now(),
                  description:
                      doc.warnings.isEmpty ? null : doc.warnings.join('\n'),
                );
                localBatch.add(meta);
                results[i] = meta;
              } else {
                // 直接建 Document，跳过单本导入的重复扫描。
                // ★ 复用同一条连接：每本新建 client 都要重做一次 TCP+TLS
                //   握手，走公网隧道时 100 本书能白白多花几十秒。
                final doc = await WebDavFolderImporter.buildFromCandidate(
                  connection: connection,
                  candidate: c,
                  client: client,
                );
                final pick = SourcePick(
                  kind: SourcePickKind.webdav,
                  displayName: c.name,
                  sourceId: ByteStore.newBookId(),
                  uri: Uri.tryParse(c.url),
                  webdavConnectionId: connection.id,
                  webdavFolderUrl: c.url,
                  webdavFolderName: c.name,
                );
                results[i] = await _persist(pick, doc, batch: localBatch);
              }
            } catch (e, st) {
              debugPrint('[import] ✗ ${c.name}: $e');
              debugPrint('[import]   stack: $st');
              failures.add('${c.name}: $e');
            }
            perSlotBatch[i] = localBatch;
            finished++;
            final label = '${c.name}（${c.pageCount} 页）';
            _setProgress(
              0.4 + 0.6 * (finished / fresh.length),
              '正在导入 $finished/${fresh.length}：$label',
            );
            onImportProgress?.call(finished, fresh.length, label);
          }
        }

        final workerCount = math.min(
          _archiveImportConcurrency,
          math.max(1, fresh.length),
        );
        await Future.wait(List.generate(workerCount, (_) => worker()));

        // 按目录顺序合并结果（并发完成顺序 ≠ 目录顺序）
        for (var i = 0; i < results.length; i++) {
          final meta = results[i];
          final batch = perSlotBatch[i];
          if (batch != null) pending.addAll(batch);
          if (meta != null) imported.add(meta);
        }
      } finally {
        _deferCovers = false;

        // ★ 一次写盘 + 一次刷新。逐本 upsertBook + notifyListeners
        //   在大库上是 O(n²) 的 JSON 编解码，导入后半段会明显卡。
        if (pending.isNotEmpty) {
          await _prefs.upsertBooks(pending);
        }
        books = _prefs.loadBooks();
        notifyListeners();

        lastImportSummary = '$lastImportSummary；成功 ${imported.length} 本'
            '，失败 ${failures.length} 个'
            '${failures.isEmpty ? '' : '（首个：${failures.first}）'}';
        // 整批结束后在后台顺序补封面（只补可见的，见 ensureAllCovers 注释）
        ensureAllCovers();
      }

      return WebDavLibraryResult(
        scanned: candidates.length,
        imported: imported.length,
        failures: failures,
        skipped: skipped,
      );
    } finally {
      // 整条连接在批量导入全程复用，最后统一关闭
      client.close();
    }
  }

  // ------------------------------------------------------------------
  // 书架
  // ------------------------------------------------------------------
  List<BookMeta> get recentBooks {
    final list = [...books]..sort((a, b) {
        final at = a.lastReadAt ?? a.importedAt;
        final bt = b.lastReadAt ?? b.importedAt;
        return bt.compareTo(at);
      });
    return list;
  }

  List<BookMeta> get favorites => books.where((b) => b.isFavorite).toList();

  /// 这本书是"在线库"（来自 NAS）还是"本地库"
  static bool isOnline(BookMeta b) =>
      b.source is WebDavSource || b.source is WebDavArchiveSource;

  /// 本地库：文件夹 / 压缩包 / 散图导入的书
  List<BookMeta> get localBooks {
    final list = books.where((b) => !isOnline(b)).toList()
      ..sort((a, b) {
        final at = a.lastReadAt ?? a.importedAt;
        final bt = b.lastReadAt ?? b.importedAt;
        return bt.compareTo(at);
      });
    return list;
  }

  /// 在线库：从 NAS（WebDAV）添加的书
  List<BookMeta> get onlineBooks {
    final list = books.where(isOnline).toList()
      ..sort((a, b) {
        final at = a.lastReadAt ?? a.importedAt;
        final bt = b.lastReadAt ?? b.importedAt;
        return bt.compareTo(at);
      });
    return list;
  }

  List<BookMeta> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return recentBooks;
    // 书名搜索。数据量到几千本时换成 drift + FTS5。
    return recentBooks.where((b) => b.title.toLowerCase().contains(q)).toList();
  }

  /// 在"某个库"里搜索（空查询返回该库全部，最近读的在前面）
  List<BookMeta> searchIn(List<BookMeta> pool, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return pool;
    return pool.where((b) => b.title.toLowerCase().contains(q)).toList();
  }

  Future<void> toggleFavorite(String bookId) async {
    await _prefs.toggleFavorite(bookId);
    books = _prefs.loadBooks();
    notifyListeners();
  }

  Future<void> rename(String bookId, String newTitle) async {
    await _prefs.renameBook(bookId, newTitle);
    books = _prefs.loadBooks();
    notifyListeners();
  }

  Future<void> deleteBook(String bookId) async {
    await _prefs.deleteBook(bookId);
    await _store?.deleteBook(bookId);
    books = _prefs.loadBooks();
    notifyListeners();
  }

  /// 批量设置收藏状态。
  ///
  /// 一次只读一次写（走 `_prefs.upsertBooks`），而不是在循环里反复
  /// `toggleFavorite` —— 那样每本都会重写整个书架 JSON，选 50 本
  /// 就是 50 次全量写入，明显卡顿。
  Future<void> setFavoriteMany(Iterable<String> bookIds, bool value) async {
    final ids = bookIds.toSet();
    if (ids.isEmpty) return;
    final all = _prefs.loadBooks();
    final updated = <BookMeta>[];
    for (final b in all) {
      if (ids.contains(b.id) && b.isFavorite != value) {
        b.isFavorite = value;
        updated.add(b);
      }
    }
    if (updated.isEmpty) return;
    await _prefs.saveBooks(all);
    books = _prefs.loadBooks();
    notifyListeners();
  }

  /// 批量删除。逐本删目录，但书架 JSON 只重读一次。
  Future<int> deleteBooks(Iterable<String> bookIds) async {
    final ids = bookIds.toList();
    if (ids.isEmpty) return 0;
    var removed = 0;
    for (final id in ids) {
      try {
        await _prefs.deleteBook(id);
        await _store?.deleteBook(id);
        _coverQueue.remove(id);
        removed++;
      } catch (_) {
        // 单本失败不影响其他
      }
    }
    books = _prefs.loadBooks();
    notifyListeners();
    return removed;
  }

  /// 重建 PDF 文档（document.json 丢失或损坏时）。
  ///
  /// 只重新读页数/尺寸，**不渲染任何页面** —— 和首次导入走同一段逻辑。
  Future<Document> _rebuildPdfDocument(BookMeta book) async {
    final dir = store.bookDir(book.id);
    final files = Directory(dir)
        .listSync(recursive: false)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.pdf'))
        .toList();
    if (files.isEmpty) {
      throw const GenericError('找不到这本书的 PDF 文件，请删除后重新导入。');
    }
    final path = files.first.path;
    final info = await const PdfNative().open(path);
    final pages = <String, PageNode>{};
    final ids = <String>[];
    for (var i = 0; i < info.pageCount; i++) {
      final id = 'p$i';
      pages[id] = PageNode(
        id: id,
        kind: PageKind.pdfPage,
        content: ImageContent(
          ref: PdfPageRef(path: path, pageIndex: i),
          intrinsicWidth: info.widths.length > i ? info.widths[i] : null,
          intrinsicHeight: info.heights.length > i ? info.heights[i] : null,
          mimeType: 'image/png',
        ),
        aspectRatio: info.aspectOf(i),
        title: '第 ${i + 1} 页',
      );
      ids.add(id);
    }
    final rebuilt = Document(
      id: 'doc-${book.id}',
      bookId: book.id,
      title: book.title,
      kind: DocumentKind.pdf,
      chapters: [Chapter(index: 0, title: book.title, pageIds: ids)],
      pages: pages,
      unit: ReadingUnit.page,
      hint: DocumentLayoutHint.pagePreferred,
    );
    await DocumentCodec.save(dir, rebuilt);
    return rebuilt;
  }

  Future<void> refreshBooks() async {
    books = _prefs.loadBooks();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // 检查更新
  // ------------------------------------------------------------------

  /// 上次检查更新的时间（面板展示用）
  DateTime? lastUpdateCheck;
  final UpdateService _updateService = UpdateService();

  /// 是否允许「打开应用时自动检查」。
  ///
  /// 一天最多一次：检查更新会走外网，每次启动都请求既慢又没必要。
  bool get shouldAutoCheckUpdate {
    final last = lastUpdateCheck;
    if (last == null) return true;
    return DateTime.now().difference(last) > const Duration(hours: 24);
  }

  /// 用户点过「跳过这个版本」的版本号
  String? get skippedVersion => _prefs.loadSkippedVersion();

  Future<void> skipVersion(String v) async {
    await _prefs.saveSkippedVersion(v);
  }

  /// 检查更新。`manual` 时忽略「已跳过」标记（用户主动点的就要看到结果）。
  Future<UpdateCheckResult> checkUpdate({bool manual = false}) async {
    final r = await _updateService.check();
    if (r.checked) {
      lastUpdateCheck = DateTime.now();
      await _prefs.saveLastUpdateCheck(lastUpdateCheck!);
      notifyListeners();
    }
    if (!manual && r.hasUpdate && r.latest != null) {
      if (_prefs.loadSkippedVersion() == r.latest!.toString()) {
        return UpdateCheckResult(
          hasUpdate: false,
          latest: r.latest,
          sourceName: r.sourceName,
        );
      }
    }
    return r;
  }

  @override
  void dispose() {
    _updateService.close();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 设置
  // ------------------------------------------------------------------
  Future<void> updateSettings(ReaderSettings next) async {
    settings = next;
    notifyListeners();
    await _prefs.saveSettings(next);
  }

  Future<void> rememberModeForBook(String bookId, ReadingMode mode) async {
    if (settings.lastModePerBook[bookId] == mode) return;
    final map = Map<String, ReadingMode>.from(settings.lastModePerBook);
    map[bookId] = mode;
    await updateSettings(settings.copyWith(lastModePerBook: map));
  }

  // ------------------------------------------------------------------
  // 导入
  // ------------------------------------------------------------------

  /// 导入并落盘。成功返回 BookMeta；失败抛 [AppError]；
  /// 需要密码抛 [PasswordPromptNeeded]（由 UI 弹框后调 [importWithPassword]）。
  Future<BookMeta> importFrom(SourcePick pick) async {
    try {
      return await _runImport(pick, password: null);
    } finally {
      _setProgress(null, '');
    }
  }

  /// 带密码重试
  Future<BookMeta> importWithPassword(SourcePick pick, String password) async {
    try {
      return await _runImport(pick, password: password);
    } finally {
      _setProgress(null, '');
    }
  }

  Future<BookMeta> _runImport(SourcePick pick, {required String? password}) async {
    // ★ WebDAV 不走 router：router 探的是**本地文件**（读头部判断格式），
    //   而 NAS 上的内容还没下载，无从探测。直接交给专用导入器。
    final Importer importer;
    if (pick.kind == SourcePickKind.webdav) {
      // 注意：连接必须从 pick 上的 connectionId **查出来传进去**。
      // 漏传的话导入器只会返回"缺少 NAS 连接信息"，表现就成了
      // "点了导入什么都没发生"（错误提示一闪而过，很容易漏看）。
      final conn = webdavConnections.byId(pick.webdavConnectionId ?? '');
      if (conn == null) {
        throw const GenericError(
          '找不到这条网盘连接。\n请在「从网盘导入」里重新选择一次。',
        );
      }
      importer = WebDavFolderImporter(connection: conn);
    } else {
      final routed = await router.route(pick);
      if (routed.earlyFailure != null) throw routed.earlyFailure!;
      final r = routed.importer;
      if (r == null) throw const ImportEmptyError();
      importer = r;
    }

    _setProgress(0, '准备导入…');

    final ctx = ImportContext(
      pick: pick,
      password: password,
      passwordAttempt: password == null ? 1 : 2,
      onProgress: _setProgress,
    );

    ImportOutcome outcome;
    try {
      outcome = await importer.run(ctx);
    } on AppError {
      rethrow;
    } catch (e, st) {
      throw GenericError('导入失败：$e', technicalDetail: st.toString());
    }

    switch (outcome) {
      case ImportedDocument(:final document):
        return await _persist(pick, document);

      case NeedPassword(:final attempt):
        // ── 密码字典自动尝试 ──
        //
        // 字典默认为空 —— 空字典等于**不启用**，不会做任何猜测。
        // 逐个试，成功就把密码写进这本书的 source（之后翻页要用）。
        if (password == null && zipPasswords.isNotEmpty) {
          for (final guess in zipPasswords) {
            _setProgress(0.1, '正在用字典中的密码尝试…');
            try {
              final retry = await importer.run(
                ctx.withPassword(guess),
              );
              if (retry is ImportedDocument) {
                debugPrint('[import] 字典命中：$guess');
                return await _persist(
                  pick,
                  retry.document,
                  archivePassword: guess,
                );
              }
            } catch (_) {
              // 这个密码不对，继续试下一个
            }
          }
        }
        throw PasswordPromptNeeded(attempt: attempt);

      case ImportFailure(:final error):
        throw error;
    }
  }

  /// 持久化一本书。
  ///
  /// [batch] 非空时表示"正在批量导入"：只把元数据追加到该列表，
  /// 由调用方在整批结束后一次性写盘并刷新 UI —— 逐本写盘 + 逐本
  /// notifyListeners 会让大库导入越到后面越卡。
  Future<BookMeta> _persist(
    SourcePick pick,
    Document doc, {
    List<BookMeta>? batch,
    String? archivePassword,
  }) async {
    final bookId = pick.sourceId;

    // ★ 把算好的 Document 落盘：下次打开就是一次 JSON 解析（秒开），
    //   而不是重新读中央目录 + 重新嗅探几千张图的尺寸。
    await DocumentCodec.save(store.bookDir(bookId), doc);

    final meta = BookMeta(
      id: bookId,
      title: pick.displayName,
      kind: switch (doc.kind) {
        DocumentKind.comic => BookKind.comic,
        DocumentKind.novel => BookKind.novel,
        DocumentKind.pdf => BookKind.pdf,
        DocumentKind.web => BookKind.web,
        DocumentKind.doc => BookKind.doc,
      },
      source: _sourceFor(pick),
      pageCount: doc.pageCount,
      chapterCount: doc.chapterCount,
      importedAt: DateTime.now(),
      description: doc.warnings.isEmpty ? null : doc.warnings.join('\n'),
    );

    if (batch != null) {
      batch.add(meta);
      return meta;
    }

    await _prefs.upsertBook(meta);
    books = _prefs.loadBooks();
    notifyListeners();
    return meta;
  }

  // ------------------------------------------------------------------
  // 封面
  // ------------------------------------------------------------------

  /// 队列：待生成封面的书 id
  final Set<String> _coverQueue = <String>{};
  bool _coverWorkerRunning = false;

  /// 批量导入期间推迟封面生成
  bool _deferCovers = false;

  /// 压缩包密码字典（默认空 = 不启用自动尝试）
  List<String> zipPasswords = const [];

  Future<void> addZipPassword(String pw) async {
    final v = pw.trim();
    if (v.isEmpty) return;
    if (zipPasswords.contains(v)) return;
    zipPasswords = [...zipPasswords, v];
    await _prefs.saveZipPasswords(zipPasswords);
    notifyListeners();
  }

  Future<void> removeZipPassword(String pw) async {
    zipPasswords = zipPasswords.where((e) => e != pw).toList();
    await _prefs.saveZipPasswords(zipPasswords);
    notifyListeners();
  }

  /// 是否启用「合集」深度扫描（识别 根目录/合集/第一话 这种结构）
  bool deepScanLibrary = true;

  Future<void> setDeepScanLibrary(bool value) async {
    deepScanLibrary = value;
    await _prefs.saveDeepScan(value);
    notifyListeners();
  }

  /// 最近一次「添加为库」的结果摘要（设置页直接显示）。
  ///
  /// release 包拿不到日志，把结果留在界面上是唯一可靠的诊断手段 ——
  /// 也让用户自己能看到"为什么没导进来"。
  String? lastImportSummary;

  /// 批量导入网盘压缩包时的并发度。
  ///
  /// 每本书的耗时几乎全是网络往返（EOCD、中央目录、几张样本图的 Range），
  /// 串行等于把延迟直接累加 —— 170 本 × 2.5 s ≈ 7 分钟。
  /// 也不能开太高：HttpClient 的 maxConnectionsPerHost 是 6，
  /// 而且每本书内部还有自己的抽样并发（4 路），4×4=16 已接近上限。
  static const int _archiveImportConcurrency = 4;

  /// 后台**顺序**生成缺失的封面。
  ///
  /// 顺序而不是并发：在线库的书每本要多一次网络请求，
  /// 并发会把 NAS / 网盘打满，反而更慢，还可能触发限流。
  Future<void> _drainCovers() async {
    if (_coverWorkerRunning) return;
    _coverWorkerRunning = true;
    try {
      while (_coverQueue.isNotEmpty) {
        final id = _coverQueue.first;
        _coverQueue.remove(id);
        BookMeta? book;
        for (final b in books) {
          if (b.id == id) {
            book = b;
            break;
          }
        }
        if (book == null) continue;
        if (book.coverPath != null && File(book.coverPath!).existsSync()) {
          continue;
        }
        await ensureCover(book);
      }
    } finally {
      _coverWorkerRunning = false;
    }
  }

  /// 确保这本书有封面（取自第一张图片），生成后落盘并刷新书架。
  ///
  /// 这是**按需**入口：书架的卡片可见时才会调用。
  /// 在线库的书要为此下载一页完整图片，所以绝不能一次性给全库排队
  /// （几百本 = 几百次整图下载，表现就是"打开 App 卡半天"）。
  void requestCover(BookMeta book) {
    if (book.coverPath != null && File(book.coverPath!).existsSync()) return;
    _coverQueue.add(book.id);
    // 批量导入期间只入队不执行 —— 否则每本插一次整图下载，
    // 导入本身会慢好几倍。整批结束后由 ensureAllCovers 统一放行。
    if (_deferCovers) return;
    unawaited(_drainCovers());
  }
  ///
  /// 任何失败都**静默忽略** —— 封面只是锦上添花，
  /// 不能因为某本书第一页读不出来就影响书架显示或导入结果。
  Future<void> ensureCover(BookMeta book) async {
    final existing = book.coverPath;
    if (existing != null && File(existing).existsSync()) return;

    try {
      final built = await buildDocument(book);
      try {
        final path = await CoverGenerator.create(
          resolver: built.resolver,
          document: built.document,
          bookDirPath: store.bookDir(book.id),
        );
        if (path != null) {
          await _prefs.setCover(book.id, path);
          books = _prefs.loadBooks();
          notifyListeners();
        }
      } finally {
        await built.resolver.dispose();
      }
    } catch (_) {
      // 封面失败不影响阅读，静默跳过
    }
  }

  // ------------------------------------------------------------------
  // 缓存统计与清理
  // ------------------------------------------------------------------

  /// 统计可清理的缓存占用。
  ///
  /// 只算**纯缓存**：
  ///   · `netcache/`  —— 从网盘拉下来的页（删了下次重拉）
  ///   · `extracted/` —— 本地压缩包的解压产物（删了回退到直接读 zip）
  ///   · `cover.png`  —— 封面缩略图（删了会重新生成）
  ///
  /// **不含** `document.json`（删了要重扫目录）和 SharedPreferences
  /// （书架与网盘连接都在里面）—— 这也是"清缓存不会断开连接"的原因。
  Future<CacheStats> cacheStats() async {
    var net = 0;
    var extracted = 0;
    var covers = 0;
    for (final b in books) {
      net += await _dirSize(store.webdavCacheDirFor(b.id));
      extracted += await _dirSize(store.extractedDirFor(b.id));
      final cover = b.coverPath;
      if (cover != null) {
        try {
          final f = File(cover);
          if (await f.exists()) covers += await f.length();
        } catch (_) {}
      }
    }
    return CacheStats(
      webdavBytes: net,
      extractedBytes: extracted,
      coverBytes: covers,
    );
  }

  /// 清理全部缓存。**不动**书架、网盘连接、阅读进度。
  Future<void> clearCache() async {
    for (final b in books) {
      await _deleteDir(store.webdavCacheDirFor(b.id));
      await _deleteDir(store.extractedDirFor(b.id));
    }
    // 封面的内存态也要一起清，否则界面还显示旧图
    for (final b in books) {
      b.coverPath = null;
    }
    _coverQueue.clear();
    await _prefs.saveBooks(books);
    books = _prefs.loadBooks();
    notifyListeners();
    // 可见的卡片会重新请求封面
    ensureAllCovers();
  }

  Future<int> _dirSize(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _deleteDir(String path) async {
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 单个目录删不掉（正被读）不影响其它
    }
  }

  /// 曾经在启动时给整个书架排队补封面，已废除。
  /// 在线库的书生成封面要**下载一整张原图**。几百本的书架就是几百次
  /// 整图下载，用户感知是"打开 App 卡半天"，比没有封面糟糕得多。
  /// 现在改为由书架卡片在**可见时**调用 [requestCover] 按需触发。
  void ensureAllCovers() {
    // 现在也仍然有用：只补**本地库**的（读本地文件，代价很低），
    // 在线库的交给可见性触发。
    for (final b in books) {
      if (b.coverPath != null && File(b.coverPath!).existsSync()) continue;
      if (isOnline(b)) continue;
      _coverQueue.add(b.id);
    }
    unawaited(_drainCovers());
  }

  BookSource _sourceFor(SourcePick pick) {
    switch (pick.kind) {
      case SourcePickKind.folder:
        return FolderSource(store.folderPathFor(pick.sourceId));
      case SourcePickKind.files:
        // 散图的实际路径不放在这里：导入时已经复制进私有目录，
        // 打开时直接扫 store.folderPathFor(bookId)。见 _rebuildFileDocument。
        return const LooseFilesSource([]);
      case SourcePickKind.webdav:
        return WebDavSource(
          connectionId: pick.webdavConnectionId ?? '',
          folderUrl: pick.webdavFolderUrl ?? '',
          folderName: pick.webdavFolderName ?? pick.displayName,
        );
      case SourcePickKind.file:
      case SourcePickKind.url:
        return ArchiveSourceSpec(
          path: store.archivePathFor(
              pick.sourceId, p.basename(pick.path ?? 'book.zip')),
        );
    }
  }

  // ------------------------------------------------------------------
  // 文档装载：从 document.json 读，读不到就重新解析
  // ------------------------------------------------------------------
  Future<({Document document, PageByteResolver resolver})> buildDocument(
    BookMeta book,
  ) async {
    final dir = store.bookDir(book.id);

    // ① 快路径：直接读 JSON
    final cached = await DocumentCodec.load(dir);

    // PDF 走独立解析器：它的"字节"不是读出来的，而是原生渲染出来的。
    // 放在 switch 之前判断，避免给 PDF 也装一个读文件的解析器
    // （那样会在第一页就报"不是图片"）。
    if (book.kind == BookKind.pdf) {
      final doc = cached ?? await _rebuildPdfDocument(book);
      final pdfPath = doc.pagesInOrder
          .map((p) => p.content)
          .whereType<ImageContent>()
          .map((c) => c.ref)
          .whereType<PdfPageRef>()
          .map((r) => r.path)
          .firstOrNull;
      if (pdfPath == null) {
        throw const GenericError('这本 PDF 的页面信息已损坏，请删除后重新导入。');
      }
      return (
        document: doc,
        resolver: PdfPageResolver(pdfPath: pdfPath),
      );
    }

    // ② 无论走哪条路，都需要一个 resolver 指向真实字节
    switch (book.source) {
      case FolderSource():
      case LooseFilesSource():
        final doc = cached ?? await _rebuildFileDocument(book);
        return (document: doc, resolver: FilePageByteResolver());

      case WebDavSource(:final connectionId, :final folderUrl, :final folderName):
        final conn = webdavConnections.byId(connectionId);
        if (conn == null) {
          throw const GenericError(
            '这条网盘连接已被删除。\n'
            '请重新添加网盘后再次导入这本书。',
          );
        }
        final doc = cached ??
            await WebDavFolderImporter.buildDocument(
              connection: conn,
              folderUrl: folderUrl,
              folderName: folderName,
            );
        return (
          document: doc,
          resolver: WebDavPageByteResolver(
            client: conn.createClient(),
            cacheDir: Directory(store.webdavCacheDirFor(book.id)),
            pageList: doc.pagesInOrder,
          ),
        );

      case WebDavArchiveSource(
          :final connectionId,
          :final archiveUrl,
          :final archiveName,
          :final archiveSize
        ):
        final conn = webdavConnections.byId(connectionId);
        if (conn == null) {
          throw const GenericError(
            '这条网盘连接已被删除。\n'
            '请重新添加网盘后再次导入这本书。',
          );
        }
        final doc = cached ??
            await WebDavArchiveImporter.buildDocument(
              client: conn.createClient(),
              connectionId: connectionId,
              archiveUrl: archiveUrl,
              archiveName: archiveName,
              knownSize: archiveSize,
            );
        return (
          document: doc,
          resolver: WebDavArchivePageResolver(
            client: conn.createClient(),
            archiveUrl: archiveUrl,
            archiveSize: archiveSize,
            cacheDir: Directory(store.webdavCacheDirFor(book.id)),
            pages: doc.pagesInOrder,
          ),
        );

      case ArchiveSourceSpec(:final path):
        final src = await FileByteSource.open(path);
        final ArchiveSource source = await _openArchive(src, path);
        final doc = cached ?? await _rebuildArchiveDocument(book, source, path);

        // 解压已经在 prepareBook() 里提前完成（见那里的注释）。
        // resolver 仍会**优先读解压产物、缺失则回退到 zip**，
        // 所以即使解压没做完或被跳过，阅读也不会出错。
        return (
          document: doc,
          resolver: ArchivePageByteResolver(
            source: source,
            extractedDir: store.extractedDirFor(book.id),
          ),
        );
    }
  }

  Future<ArchiveSource> _openArchive(
    RandomAccessByteSource src,
    String path, {
    String? password,
  }) async {
    if (path.toLowerCase().endsWith('.tar')) {
      final t = TarArchiveSource(src);
      await t.open();
      return t;
    }
    final z = ZipArchiveSource(src, password: password);
    await z.open();
    return z;
  }

  // ------------------------------------------------------------------
  // 阅读前准备：把压缩包解压到 app 缓存
  // ------------------------------------------------------------------
  //
  // 为什么把解压**提前到打开之前**，而不是像之前那样"边读边后台解压"：
  //
  //   DEFLATE 解压是 CPU 密集操作，在 Dart 里跑在**主 isolate** 上。
  //   边读边解压意味着每次翻页都要在主线程解压几十~几百 KB，
  //   用户看到的就是"翻页很慢、会卡"。
  //
  //   先把解压做完，之后每页都是**直接文件 I/O**（几毫秒），
  //   而且文件内容能吃到操作系统的页缓存。
  //
  //   代价是首次打开要等一次解压 → 所以配一个**带进度的等待界面**，
  //   而且解压结果落盘持久化，只有第一次打开需要等。
  bool needsPrepare(BookMeta book) {
    // PDF 没有"解压"这回事 —— 页面是按需由原生渲染器生成的。
    // 不加这一条的话，PDF 打开时会先弹一个"首次打开需要解压到缓存"的准备页，
    // 用户点进去还得再点一次才能看书，非常莫名。
    if (book.kind == BookKind.pdf) return false;
    if (book.source is! ArchiveSourceSpec) return false; // 文件夹/散图无需解压
    final marker = File(p.join(store.extractedDirFor(book.id), '.complete'));
    return !marker.existsSync();
  }

  /// 执行解压。返回 null 表示成功（或已回退为按需读取）；
  /// 返回字符串表示给用户看的提示（失败原因 / 跳过原因）。
  Future<String?> prepareBook(
    BookMeta book, {
    required void Function(ExtractProgress progress) onProgress,
  }) async {
    if (book.source is! ArchiveSourceSpec) return null;
    final spec = book.source as ArchiveSourceSpec;

    final src = await FileByteSource.open(spec.path);
    ArchiveSource source;
    try {
      source = await _openArchive(src, spec.path);
    } catch (e) {
      await src.close();
      return '打开压缩包失败：$e';
    }

    try {
      if (!_extraction!.extractor.shouldExtract(source)) {
        final total = source.totalUncompressedBytes;
        return total > 0
            ? '解压后约 ${ByteStore.humanSize(total)}，超过缓存上限，'
                '已改为按需读取（首次翻页稍慢，之后流畅）'
            : '该压缩包无需解压';
      }

      // 走 ExtractionManager 而不是直接调 extractor：
      // 这样进度会同时推给设置面板里的解压卡片，两边状态一致。
      final result = await _extraction!.extractWithProgress(
        bookId: book.id,
        source: source,
        onProgress: onProgress,
      );
      if (result.ok) return null;
      return result.skippedReason ?? '已部分解压（不影响阅读）';
    } catch (e) {
      return '解压失败：$e（已回退为按需读取，不影响阅读）';
    } finally {
      // 这个 source 只为解压而开，用完即关。
      // 阅读时会由 buildDocument 重新打开一个。
      await source.close();
    }
  }

  /// 慢路径（缓存缺失/版本不符时）：重新构建 Document。
  ///
  /// 内容已经在私有目录里了，所以走的是"从本地目录重建"，
  /// 不做任何复制，也不访问原始来源。
  Future<Document> _rebuildFileDocument(BookMeta book) async {
    final root = switch (book.source) {
      FolderSource(:final path) => path,
      LooseFilesSource() => store.folderPathFor(book.id),
      _ => throw const GenericError('来源类型不匹配'),
    };

    final dir = Directory(root);
    if (!await dir.exists()) {
      throw GenericError(
        '内容目录不存在：$root。请重新导入这本书。',
        action: ErrorAction.chooseAnother,
      );
    }

    final files = <File>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File && _isImagePath(e.path)) files.add(e);
    }
    files.sort((a, b) => _natural(a.path, b.path));

    final pages = <String, PageNode>{};
    final pageIds = <String>[];
    for (final f in files) {
      final id = 'f:${p.relative(f.path, from: root)}';
      pages[id] = PageNode(
        id: id,
        kind: PageKind.image,
        content: ImageContent(ref: LooseFileRef(f.path)),
      );
      pageIds.add(id);
    }
    if (pageIds.isEmpty) throw const ImportEmptyError();

    final doc = Document(
      id: 'doc_${book.id}',
      bookId: book.id,
      title: book.title,
      kind: DocumentKind.comic,
      chapters: [Chapter(index: 0, title: '正文', pageIds: pageIds)],
      pages: pages,
      hint: DocumentLayoutHint.webtoonPreferred,
      warnings: const ['页面尺寸未预分析，滚动时自动测量。'],
    );
    await DocumentCodec.save(store.bookDir(book.id), doc);
    return doc;
  }

  Future<Document> _rebuildArchiveDocument(
    BookMeta book,
    ArchiveSource source,
    String archivePath,
  ) async {
    final images =
        source.entries.where((e) => !e.isDirectory && _isImagePath(e.entryPath)).toList()
          ..sort((a, b) => _natural(a.entryPath, b.entryPath));

    if (images.isEmpty) throw const ImportEmptyError();

    final groups = <String, List<ArchiveEntryInfo>>{};
    for (final e in images) {
      groups.putIfAbsent(e.parentDir, () => []).add(e);
    }

    final pages = <String, PageNode>{};
    final chapters = <Chapter>[];
    int ci = 0;
    for (final dirKey in groups.keys.toList()..sort(_natural)) {
      final list = groups[dirKey]!..sort((a, b) => _natural(a.entryPath, b.entryPath));
      final pageIds = <String>[];
      for (final e in list) {
        final id = 'p:${e.entryPath}';
        pages[id] = PageNode(
          id: id,
          kind: PageKind.image,
          content: ImageContent(
            ref: ArchiveEntryRef(
              archivePath: archivePath,
              entryPath: e.entryPath,
              uncompressedSize: e.uncompressedSize,
            ),
          ),
        );
        pageIds.add(id);
      }
      chapters.add(Chapter(
        index: ci,
        title: dirKey.isEmpty ? '正文' : p.basename(dirKey),
        pageIds: pageIds,
      ));
      ci++;
    }

    final doc = Document(
      id: 'doc_${book.id}',
      bookId: book.id,
      title: book.title,
      kind: DocumentKind.comic,
      chapters: chapters,
      pages: pages,
      hint: DocumentLayoutHint.webtoonPreferred,
      warnings: const ['页面尺寸未预分析，滚动时自动测量。'],
    );
    await DocumentCodec.save(store.bookDir(book.id), doc);
    return doc;
  }

  static bool _isImagePath(String path) {
    final ext = p.extension(path).toLowerCase();
    return const {
      '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.avif', '.heic', '.jfif'
    }.contains(ext);
  }

  static int _natural(String a, String b) {
    // 逐段自然排序：'第1话/10.jpg' 与 '第10话/1.jpg' 不会错位
    final pa = a.replaceAll('\\', '/').split('/');
    final pb = b.replaceAll('\\', '/').split('/');
    for (int i = 0; i < pa.length && i < pb.length; i++) {
      final c = _cmpNatural(pa[i], pb[i]);
      if (c != 0) return c;
    }
    return pa.length - pb.length;
  }

  static int _cmpNatural(String a, String b) {
    int i = 0, j = 0;
    while (i < a.length && j < b.length) {
      final ca = a.codeUnitAt(i), cb = b.codeUnitAt(j);
      final da = ca >= 0x30 && ca <= 0x39;
      final db = cb >= 0x30 && cb <= 0x39;
      if (da && db) {
        int si = i, sj = j;
        while (i < a.length && a.codeUnitAt(i) >= 0x30 && a.codeUnitAt(i) <= 0x39) {
          i++;
        }
        while (j < b.length && b.codeUnitAt(j) >= 0x30 && b.codeUnitAt(j) <= 0x39) {
          j++;
        }
        final na = a.substring(si, i).replaceFirst(RegExp(r'^0+(?=\d)'), '');
        final nb = b.substring(sj, j).replaceFirst(RegExp(r'^0+(?=\d)'), '');
        if (na.length != nb.length) return na.length - nb.length;
        final c = na.compareTo(nb);
        if (c != 0) return c;
      } else {
        final c = ca.compareTo(cb);
        if (c != 0) return c;
        i++;
        j++;
      }
    }
    return (a.length - i) - (b.length - j);
  }

  void _setProgress(double? ratio, String label) {
    if (ratio == null) {
      importProgress = null;
    } else {
      importProgress = ImportProgressState(ratio, label);
    }
    notifyListeners();
  }
}

class ImportProgressState {
  const ImportProgressState(this.ratio, this.label);
  final double ratio;
  final String label;
}

/// 需要 UI 输入密码（不是错误，是一个正常的分支）
class PasswordPromptNeeded implements Exception {
  const PasswordPromptNeeded({required this.attempt});
  final int attempt;
}
/// 「添加 WebDAV 库」的批量导入结果
class WebDavLibraryResult {
  const WebDavLibraryResult({
    required this.scanned,
    required this.imported,
    required this.failures,
    this.emptyFolder,
    this.skipped = 0,
    this.allAlreadyAdded = false,
  });

  /// 扫描到多少个含图片的文件夹
  final int scanned;

  /// 成功导入多少本
  final int imported;

  /// 失败明细（书名: 原因）
  final List<String> failures;

  /// 非空表示"扫描到 0 个目录"，值是用户选的那个文件夹名
  final String? emptyFolder;

  /// 因为"已经在库里"而跳过的数量
  final int skipped;

  /// 扫到的全部都已经在库里了（不是空目录，也不是失败）
  final bool allAlreadyAdded;

  bool get isEmpty => scanned == 0;
}

/// 可清理缓存的构成
class CacheStats {
  const CacheStats({
    required this.webdavBytes,
    required this.extractedBytes,
    required this.coverBytes,
  });

  /// 网盘页缓存（netcache/）
  final int webdavBytes;

  /// 本地压缩包解压产物（extracted/）
  final int extractedBytes;

  /// 封面缩略图
  final int coverBytes;

  int get total => webdavBytes + extractedBytes + coverBytes;

  static String human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}