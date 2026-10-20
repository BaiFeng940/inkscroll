/// 阅读控制器：三种模式的统一状态机 + 进度 + 跳转 + 模式换算。
///
/// 性能要点（很重要）：
///   ★ 进度条的刷新与列表重建**必须解耦**。
///     滚动回调每帧都会触发，如果用 setState 重建整棵阅读器树会掉帧。
///     所以进度单独放在 [progressRatio]（ValueNotifier<double>），
///     滚动时只通知它；只有"文档结构变化"才走 ChangeNotifier。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/image_header.dart';
import '../data/models/book_meta.dart';
import '../data/models/reader_settings.dart';
import '../data/prefs_store.dart';
import '../ui/reader/gesture_arbiter.dart';
import 'document.dart';
import 'page_cache.dart';

enum ReaderStatus { loading, ready, failed }

class ReaderController extends ChangeNotifier {
  ReaderController({
    required this.book,
    required this.settings,
    required this.prefs,
    required this.resolver,
  }) {
    arbiter.addListener(_onArbiterChanged);
  }

  final BookMeta book;
  final PrefsStore prefs;
  final PageByteResolver resolver;

  /// 当前阅读设置。面板改动后由 UI 同步进来（点击区域等逻辑要用到）。
  ReaderSettings settings;

  // ------------------------------------------------------------------
  // 状态
  // ------------------------------------------------------------------
  ReaderStatus status = ReaderStatus.loading;
  Document? document;
  AppError? error;

  ReadingMode mode = ReadingMode.verticalContinuous;
  bool menuVisible = false;

  /// ★ 进度单独通知，避免滚动时重建整个阅读器
  final ValueNotifier<double> progressRatio = ValueNotifier<double>(0);
  final ValueNotifier<String> progressLabel = ValueNotifier<String>('0%');

  final GestureArbiter arbiter = GestureArbiter();
  final TapArbiter tapArbiter = TapArbiter();

  /// 外部注入的滚动控制（由 VerticalReader / HorizontalReader 注册）
  PageLayoutMetrics? metrics;
  ScrollController? verticalScroll;
  PageController? horizontalPager;

  ReadingProgress _progress = const ReadingProgress();
  ReadingProgress get progress => _progress;

  bool _disposed = false;
  Timer? _saveDebounce;

  /// 每个模式各自记住的位置
  final Map<ReadingMode, ReadingProgress> _perModeProgress = {};

  // ------------------------------------------------------------------
  // 生命周期
  // ------------------------------------------------------------------
  Future<void> loadDocument(Document Function() builder) async {
    status = ReaderStatus.loading;
    _safeNotify();

    try {
      // 文档构建可能是 CPU 密集的（大 zip 的中央目录 + 尺寸嗅探），
      // 已经在导入阶段做完，这里只是装配。
      document = builder();

      // 4) 恢复"每模式进度"里最合适的那一条
      _perModeProgress
        ..clear()
        ..addAll(await prefs.loadAllProgress(book.id));

      final saved = _perModeProgress[mode] ??
          (_perModeProgress.isEmpty
              ? const ReadingProgress()
              : _perModeProgress.values.first);
      _progress = saved;
      _updateProgressNotifier();

      status = ReaderStatus.ready;
    } on AppError catch (e) {
      error = e;
      status = ReaderStatus.failed;
    } catch (e, st) {
      error = GenericError('打开失败：$e', technicalDetail: st.toString());
      status = ReaderStatus.failed;
    }
    _safeNotify();
  }

  // ------------------------------------------------------------------
  // 度量注入
  // ------------------------------------------------------------------
  void attachMetrics(PageLayoutMetrics m) {
    metrics = m;
    _updateProgressNotifier();
  }

  void attachVerticalScroll(ScrollController c) {
    verticalScroll?.removeListener(_onVerticalScroll);
    verticalScroll = c;
    c.addListener(_onVerticalScroll);
  }

  void attachHorizontalPager(PageController c) {
    horizontalPager = c;
  }

  // ------------------------------------------------------------------
  // 滚动 / 翻页 → 进度
  // ------------------------------------------------------------------
  void _onVerticalScroll() {
    final c = verticalScroll;
    if (c == null || !c.hasClients) return;
    updateScrollOffset(c.offset);
  }

  /// 模式 ③：由像素位置反推进度
  void updateScrollOffset(double y) {
    final m = metrics;
    if (m == null || m.pageCount == 0) return;

    final pageIndex = m.pageAt(y);
    _progress = _progress.copyWith(
      pageIndex: pageIndex,
      pixelOffset: y,
      ratioInPage: m.ratioInPage(pageIndex, y),
      ratio: m.ratioAt(y),
      mode: mode,
      chapterIndex: document?.chapterOfPage(pageIndex)?.index ?? 0,
      charOffset: _charOffsetOfPage(pageIndex),
    );
    _updateProgressNotifier();
    _scheduleSave();
  }

  /// 模式 ①②：由当前页反推进度
  void updatePageIndex(int pageIndex) {
    final doc = document;
    if (doc == null || doc.pageCount == 0) return;

    final denom = doc.pageCount <= 1 ? 1 : doc.pageCount - 1;
    _progress = _progress.copyWith(
      pageIndex: pageIndex,
      pixelOffset: metrics?.topOf(pageIndex) ?? 0,
      ratioInPage: 0,
      ratio: (pageIndex / denom).clamp(0.0, 1.0),
      mode: mode,
      chapterIndex: doc.chapterOfPage(pageIndex)?.index ?? 0,
      charOffset: _charOffsetOfPage(pageIndex),
    );
    _updateProgressNotifier();
    _scheduleSave();
  }

  int? _charOffsetOfPage(int pageIndex) {
    final doc = document;
    if (doc == null) return null;
    final list = doc.pagesInOrder;
    if (pageIndex < 0 || pageIndex >= list.length) return null;
    final content = list[pageIndex].content;
    return content is TextPageContent ? content.pageStartCharOffset : null;
  }

  // ------------------------------------------------------------------
  // 跳转（进度条拖动 / 页码跳转 / 章节跳转）
  // ------------------------------------------------------------------
  /// 跳到归一化百分比。三种模式都支持。
  void jumpToRatio(double r, {bool animate = false}) {
    final doc = document;
    if (doc == null) return;

    if (mode.isVertical) {
      final m = metrics;
      final c = verticalScroll;
      if (m == null || c == null || !c.hasClients) return;
      final target = m.offsetForRatio(r).clamp(0.0, c.position.maxScrollExtent);
      if (animate) {
        c.animateTo(target,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      } else {
        c.jumpTo(target);
      }
    } else {
      final target = (r * (doc.pageCount - 1)).round();
      jumpToPage(target, animate: animate);
    }
    // 跳转时重置缩放，避免"跳到新位置但还带着旧缩放"
    arbiter.resetZoom();
  }

  void jumpToPage(int pageIndex, {bool animate = false}) {
    final doc = document;
    if (doc == null) return;
    final target = pageIndex.clamp(0, doc.pageCount - 1);

    if (mode.isVertical) {
      final m = metrics;
      final c = verticalScroll;
      if (m != null && c != null && c.hasClients) {
        final y = m.topOf(target).clamp(0.0, c.position.maxScrollExtent);
        if (animate) {
          c.animateTo(y,
              duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
        } else {
          c.jumpTo(y);
        }
      }
    } else {
      final p = horizontalPager;
      if (p != null && p.hasClients) {
        if (animate) {
          p.animateToPage(target,
              duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
        } else {
          p.jumpToPage(target);
        }
      }
    }
    updatePageIndex(target);
  }

  /// 跳到归一化百分比，并在跳完之后做**收敛式修正**。
  ///
  /// 为什么需要修正：长页布局现在由图片真实比例驱动（不再预先固定每页高度），
  /// 所以 `metrics` 里的页面高度是**估算值**，`maxScrollExtent` 也是估算的。
  /// 按估算值直接跳，可能落到目标附近但不在目标上。
  ///
  /// 修正方式：跳完一帧后看"目标比例对应的真实内容"离我们还有多远，
  /// 用同样的比例关系再跳一次。两三轮就能收敛。
  void jumpToRatioConverging(
    double ratio, {
    int attempts = 3,
    bool animate = false,
  }) {
    final c = verticalScroll;
    if (!mode.isVertical || c == null || !c.hasClients) {
      // 翻页模式是精确的（页号可直接定位），不需要修正
      jumpToRatio(ratio, animate: animate);
      return;
    }

    final r = ratio.clamp(0.0, 1.0);
    _converge(r, attempts, animate);
  }

  void _converge(double targetRatio, int attemptsLeft, bool animate) {
    final c = verticalScroll;
    final m = metrics;
    if (c == null || m == null || !c.hasClients) return;

    final maxExtent = c.position.maxScrollExtent;
    final targetOffset = (targetRatio * maxExtent).clamp(0.0, maxExtent);

    if (animate && attemptsLeft == 3) {
      c.animateTo(targetOffset,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
    } else {
      c.jumpTo(targetOffset);
    }
    updateScrollOffset(targetOffset);

    if (attemptsLeft <= 0) return;

    // 等一帧让新位置布局完成，再根据"实际落点"修正
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      final c2 = verticalScroll;
      if (c2 == null || !c2.hasClients) return;
      final newMax = c2.position.maxScrollExtent;
      if (newMax <= 0) return;

      // 布局后 maxScrollExtent 会变化（真实高度逐渐取代估算）→ 用新值再对一次
      final nowRatio = c2.offset / newMax;
      if ((nowRatio - targetRatio).abs() < 0.005) return; // 已经足够准
      _converge(targetRatio, attemptsLeft - 1, false);
    });
  }

  void goToChapter(int chapterIndex) {
    final doc = document;
    if (doc == null || chapterIndex < 0 || chapterIndex >= doc.chapterCount) return;
    final chapter = doc.chapters[chapterIndex];
    if (chapter.pageIds.isEmpty) return;
    final pageIndex = doc.indexOfPage(chapter.pageIds.first);
    jumpToPage(pageIndex);
  }

  void nextPage() {
    final doc = document;
    if (doc == null) return;
    _turnTo((_progress.pageIndex + 1).clamp(0, doc.pageCount - 1));
  }

  void prevPage() {
    _turnTo(_progress.pageIndex - 1);
  }

  /// 上一次翻页的时间，用来判断"是否在连续快速翻页"
  DateTime? _lastTurnAt;

  /// 翻页跳转。
  ///
  /// **连续快速翻页时必须直接跳，不能叠加动画。**
  /// 每次 `animateToPage` 都要 220ms；用户连点 5 下就会有 5 个动画
  /// 互相打断，位置在动画途中反复被重设，表现就是"卡住 / 停不到目标页"。
  /// 所以间隔很短时退化成瞬时跳转，保证每次点击都**切实前进一页**。
  void _turnTo(int target) {
    final doc = document;
    if (doc == null) return;
    final clamped = target.clamp(0, doc.pageCount - 1);
    final now = DateTime.now();
    final rapid = _lastTurnAt != null &&
        now.difference(_lastTurnAt!).inMilliseconds < 260;
    _lastTurnAt = now;
    jumpToPage(clamped, animate: !rapid);
  }

  /// 进度条拖动中的**实时预览**：只移动视图，不做动画、不写进度。
  ///
  /// 用瞬时跳转（`jumpTo` / `jumpToPage`）而不是动画 —— 拖动时每帧都
  /// 要更新，动画会互相打断且明显滞后。
  void previewRatio(double r) {
    final doc = document;
    if (doc == null) return;
    final clamped = r.clamp(0.0, 1.0);
    if (mode.isVertical) {
      final m = metrics;
      final c = verticalScroll;
      if (m == null || c == null || !c.hasClients) return;
      final target =
          m.offsetForRatio(clamped).clamp(0.0, c.position.maxScrollExtent);
      c.jumpTo(target);
    } else {
      final p = horizontalPager;
      if (p == null || !p.hasClients) return;
      final target = (clamped * (doc.pageCount - 1)).round();
      p.jumpToPage(target.clamp(0, doc.pageCount - 1));
      updatePageIndex(target.clamp(0, doc.pageCount - 1));
    }
  }

  int get currentPageIndex => _progress.pageIndex;
  int get pageCount => document?.pageCount ?? 0;

  // ------------------------------------------------------------------
  // 模式切换：位置换算
  // ------------------------------------------------------------------
  /// 换模式时把"当前页 + 页内比例"作为锚点，在新模式里还原到同一位置。
  ///
  /// 统一货币是 (pageIndex, ratioInPage)：
  ///   - 页模式只用到 pageIndex
  ///   - 长图模式两者都用
  /// 不用全局百分比做锚点，因为各页高度按比例变化时全书比例会漂移。
  void switchMode(ReadingMode newMode) {
    if (newMode == mode) return;

    // 1) 记下当前模式的精确位置
    _perModeProgress[mode] = _progress;

    // 2) 换算锚点
    final anchorPage = _progress.pageIndex;
    final anchorRatioInPage = _progress.ratioInPage;

    mode = newMode;
    arbiter.resetZoom();
    _safeNotify();

    // 3) 等新的布局建立后再还原位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final restored = _perModeProgress[newMode] ??
          _progress.copyWith(mode: newMode, pageIndex: anchorPage, ratioInPage: anchorRatioInPage);

      if (newMode.isVertical) {
        final m = metrics;
        final c = verticalScroll;
        if (m != null && c != null && c.hasClients) {
          final y = m
              .pixelFor(restored.pageIndex, restored.ratioInPage)
              .clamp(0.0, c.position.maxScrollExtent);
          c.jumpTo(y);
          updateScrollOffset(y);
        }
      } else {
        final p = horizontalPager;
        if (p != null && p.hasClients) {
          p.jumpToPage(restored.pageIndex.clamp(0, pageCount - 1));
          updatePageIndex(restored.pageIndex);
        }
      }
    });

    _scheduleSave();
  }

  // ------------------------------------------------------------------
  // 菜单 / 手势
  // ------------------------------------------------------------------
  void toggleMenu() {
    menuVisible = !menuVisible;
    _safeNotify();
  }

  void hideMenu() {
    if (!menuVisible) return;
    menuVisible = false;
    _safeNotify();
  }

  /// 单击分区：左 = 上一页，右 = 下一页，中 = 菜单
  ///
  /// 上一次点击的时间与位置，用来自己判定双击。
  ///
  /// 为什么不交给 `GestureDetector` 的 `onDoubleTap`：
  /// 它会在 pointer-down 就抢占手势竞技场，既拖累拖动（滚动失效），
  /// 又把**连续快速点击**吞成双击 —— 用户连点"下一页"只前进 1 页。
  /// 自己判定只多几行，却同时解决这两个问题。
  DateTime? _lastTapAt;
  Offset? _lastTapPos;

  /// 判断两次点击是否构成"双击"的距离阈值（逻辑像素）
  static const double _doubleTapSlop = 48;

  /// 必须经过 [TapArbiter] 延迟，否则双击会被先判成两次单击。
  void handleSingleTap(Offset localPosition, Size viewportSize) {
    if (menuVisible) {
      hideMenu();
      return;
    }

    final x = localPosition.dx;
    final leftZoneEnd = viewportSize.width * settings.tapZoneLeft;
    final rightZoneStart = viewportSize.width * (1 - settings.tapZoneRight);
    final inSideZone = x < leftZoneEnd || x > rightZoneStart;

    // ── 侧边区（翻页区）：**每一次点击都必须翻页** ──
    //
    // 这里绝不做双击判定。原因很实际：用户想快速翻页时会对着右边缘
    // 连点，落点几乎相同、间隔又很短 —— 从手势上看和"双击"一模一样。
    // 若在这里做双击仲裁，连点 5 下只会翻 1~3 页（实测就是这个症状）。
    // 双击缩放只在中间区域才有意义。
    if (inSideZone) {
      _lastTapAt = null;
      _lastTapPos = null;
      // 先把上一次还没兑现的点击执行掉，再执行这一次 —— 一按一页，不丢事件
      tapArbiter.flushPending();
      _turnForZone(x, leftZoneEnd, rightZoneStart);
      return;
    }

    // ── 中间区域：时间 + 落点判双击（缩放），单击呼出菜单 ──
    final now = DateTime.now();
    final gap = _lastTapAt == null ? null : now.difference(_lastTapAt!);
    final nearSame = _lastTapPos != null &&
        (localPosition - _lastTapPos!).distance <= _doubleTapSlop;
    final isDoubleTap = gap != null && gap.inMilliseconds < 300 && nearSame;

    if (isDoubleTap) {
      _lastTapAt = null;
      _lastTapPos = null;
      handleDoubleTap(localPosition);
      return;
    }

    _lastTapAt = now;
    _lastTapPos = localPosition;
    tapArbiter.submitSingleTap(toggleMenu);
  }

  /// 按落点执行"上一页 / 下一页"
  void _turnForZone(double x, double leftZoneEnd, double rightZoneStart) {
    if (x < leftZoneEnd) {
      if (_progress.pageIndex > 0) {
        prevPage();
      } else {
        goToChapter((document?.chapterOfPage(0)?.index ?? 0) - 1);
      }
    } else if (x > rightZoneStart) {
      if (_progress.pageIndex < pageCount - 1) {
        nextPage();
      }
    }
  }

  void handleDoubleTap(Offset localPosition) {
    tapArbiter.cancelPendingTap();
    arbiter.rememberDoubleTapPosition(localPosition);
    arbiter.toggleZoom();
  }

  void _onArbiterChanged() {
    _progress = _progress.copyWith(zoom: arbiter.scale);
    _safeNotify();
  }

  // ------------------------------------------------------------------
  // 尺寸回填（只影响进度估算，不影响渲染）
  // ------------------------------------------------------------------
  //
  // 渲染已经完全由图片真实比例驱动（见 page_image.dart），
  // 所以这里的回填**只用于让"进度条 / 百分比跳转"的估算几何更快收敛**。
  //
  // ★ 必须节流：每一页解码都会回调一次，如果每次都全量重建度量
  //   （O(n) 且 pagesInOrder 本身也是 O(n) 重组），
  //   滚动一屏就会触发十几次 O(n) 重建 —— 这是实打实的卡顿来源。
  //   这里改成"累积到缓冲 + 每帧最多重建一次 + 300ms 静默后补一次"。

  final Map<String, double> _aspectOverrides = {};
  double? _pendingViewportWidth;
  bool _rebuildScheduled = false;
  Timer? _rebuildDebounce;

  /// 记录真实比例（不立即重建度量）
  bool backfillAspect(String pageId, ImageDimension dim) {
    final doc = document;
    if (doc == null) return false;

    final page = doc.pages[pageId];
    if (page == null) return false;

    final newAspect = dim.aspectRatio;
    if (!newAspect.isFinite || newAspect <= 0.02 || newAspect > 50) return false;

    // 偏差小于 0.5% 就不动，避免无意义的抖动
    final existing = _aspectOverrides[pageId] ?? page.aspectRatio;
    if (existing != null && ((existing - newAspect).abs() / newAspect) <= 0.005) {
      return false;
    }

    _aspectOverrides[pageId] = newAspect;
    doc.pages[pageId] = page.copyWith(aspectRatio: newAspect);
    return true;
  }

  void rebuildMetricsIfNeeded(double viewportWidth) {
    final doc = document;
    if (doc == null) return;
    if (metrics != null && metrics!.sameWidth(viewportWidth)) return;
    metrics = PageLayoutMetrics.build(
      pages: doc.pagesInOrder,
      viewportWidth: viewportWidth,
    );
    _updateProgressNotifier();
  }

  /// 回填后请求重建：合并到下一帧，并再做一次防抖重建。
  void scheduleMetricsRebuild(double viewportWidth) {
    _pendingViewportWidth = viewportWidth;

    if (!_rebuildScheduled) {
      _rebuildScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _rebuildScheduled = false;
        _applyMetricsRebuild();
      });
    }

    // 停止回填 300ms 后再对一次总高，避免"边滚边算"永远差一点
    _rebuildDebounce?.cancel();
    _rebuildDebounce = Timer(const Duration(milliseconds: 300), () {
      _applyMetricsRebuild();
    });
  }

  void _applyMetricsRebuild() {
    if (_disposed) return;
    final doc = document;
    final w = _pendingViewportWidth;
    if (doc == null || w == null || w <= 0) return;
    metrics = PageLayoutMetrics.build(pages: doc.pagesInOrder, viewportWidth: w);
    _updateProgressNotifier();
  }

  // ------------------------------------------------------------------
  // 进度通知（解耦）
  //
  // ★ 节流（对 120Hz 高刷尤其重要）：
  //   这个函数在滚动时**每帧**都会被调用。120Hz 下就是每秒 120 次。
  //   如果每次都写 ValueNotifier，进度条就会每帧重建一次 ——
  //   单看不贵，但和图片解码、列表布局抢同一个 UI 线程，
  //   在高刷屏上会直接吃掉掉帧预算（每帧只有 8.3ms）。
  //
  //   所以只有当"用户能看到的数字"真的变了才通知：
  //   页码变化，或百分比变化超过 0.1%。
  int _lastNotifiedPage = -2;
  int _lastNotifiedTenthPct = -2;
  int _lastNotifiedPageCount = -1;

  void _updateProgressNotifier() {
    final r = _progress.ratio.clamp(0.0, 1.0);
    final doc = document;
    final pageCount = doc?.pageCount ?? 0;
    final tenthPct = (r * 1000).round();

    if (_progress.pageIndex == _lastNotifiedPage &&
        tenthPct == _lastNotifiedTenthPct &&
        pageCount == _lastNotifiedPageCount) {
      return; // 显示值没变，不必打扰 UI
    }
    _lastNotifiedPage = _progress.pageIndex;
    _lastNotifiedTenthPct = tenthPct;
    _lastNotifiedPageCount = pageCount;

    progressRatio.value = r;
    if (pageCount > 0) {
      progressLabel.value =
          '${_progress.pageIndex + 1}/$pageCount  ·  ${(r * 100).toStringAsFixed(1)}%';
    } else {
      progressLabel.value = '${(r * 100).toStringAsFixed(1)}%';
    }
  }

  // ------------------------------------------------------------------
  // 保存（防抖）
  // ------------------------------------------------------------------
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(saveNow());
    });
  }

  Future<void> saveNow() async {
    if (_disposed) return;
    try {
      _perModeProgress[mode] =
          _progress.copyWith(updatedAt: DateTime.now(), mode: mode);
      await prefs.saveAllProgress(book.id, _perModeProgress);
      await prefs.touchBook(book.id);
    } catch (_) {
      // 进度保存失败不应该影响阅读
    }
  }

  // ------------------------------------------------------------------
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveDebounce?.cancel();
    // ★ 退出前强制保存一次（不能只依赖防抖计时器）
    unawaited(saveNow());
    verticalScroll?.removeListener(_onVerticalScroll);
    arbiter.removeListener(_onArbiterChanged);
    arbiter.dispose();
    tapArbiter.dispose();
    progressRatio.dispose();
    progressLabel.dispose();
    resolver.dispose();
    super.dispose();
  }
}
