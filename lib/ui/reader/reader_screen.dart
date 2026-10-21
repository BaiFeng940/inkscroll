/// 阅读器主界面：三种阅读模式 + 手势仲裁 + 进度条。
///
/// 结构上的两个关键决定：
///
/// 1) **进度通知与列表重建解耦**
///    滚动回调每帧都会触发。如果进度条刷新走 setState 重建整棵树，必然掉帧。
///    所以进度条直接监听 controller.progressRatio（ValueNotifier<double>），
///    列表只订阅文档结构变化。见 DESIGN.md §3.3.1。
///
/// 2) **长图模式的 items 只构建可见区域**
///    CustomScrollView + SliverList.builder，且每一项的高度由 PageLayoutMetrics
///    预先给定 —— 于是 SliverList 不需要测量未构建项，maxScrollExtent 也能算准。
///    见 DESIGN.md §3.2.2。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../core/image_header.dart';
import '../../data/archive_extractor.dart';
import '../../data/byte_store.dart';
import '../../data/models/book_meta.dart';
import '../../data/models/reader_settings.dart';
import '../../data/prefs_store.dart';
import '../../reader/document.dart';
import '../../reader/page_cache.dart';
import '../../reader/reader_controller.dart';
import 'widgets/page_image.dart';
import 'widgets/progress_bar.dart';
import 'widgets/text_page_view.dart';
import '../settings_sheet.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.book,
    required this.settings,
    required this.prefs,
    required this.resolveDocument,
    required this.onSettingsChanged,
    this.extraction,
    this.store,
  });

  final BookMeta book;
  final ReaderSettings settings;
  final PrefsStore prefs;

  /// 解压缓存管理器（压缩包来源才有；用于设置面板展示进度/清理）
  final ExtractionManager? extraction;
  final ByteStore? store;

  /// 由 AppState 提供的装载函数（含 resolver）
  final Future<({Document document, PageByteResolver resolver})> Function() resolveDocument;

  final ValueChanged<ReaderSettings> onSettingsChanged;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  ReaderController? _controller;
  Object? _fatalError;
  bool _loading = true;

  final ScrollController _verticalScroll = ScrollController();
  PageController? _horizontalPager;

  @override
  void initState() {
    super.initState();
    // 阅读时进入沉浸式（隐藏状态栏 / 导航栏）。
    // 之前这一步被写在 dispose() 里 —— 那是反的：离开阅读器才隐藏系统栏。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final resolved = await widget.resolveDocument();

      final controller = ReaderController(
        book: widget.book,
        settings: widget.settings,
        prefs: widget.prefs,
        resolver: resolved.resolver,
      );

      // 默认模式：这本书上次用过的 > 用户在设置里指定的 > 按内容自动判断
      final remembered = widget.settings.lastModePerBook[widget.book.id];
      controller.mode = remembered ??
          widget.settings.defaultMode ??
          _defaultModeFor(resolved.document);

      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });


      await controller.loadDocument(() => resolved.document);

      if (!mounted) return;
      controller.attachVerticalScroll(_verticalScroll);
      setState(() {});

      // 首帧之后再做一次位置恢复（此时 SliverList 已经有了 layout）
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreProgress());
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _fatalError = e is AppError
            ? e
            : GenericError('打开失败：$e', technicalDetail: st.toString());
        _loading = false;
      });
    }
  }

  ReadingMode _defaultModeFor(Document doc) {
    switch (doc.hint) {
      case DocumentLayoutHint.webtoonPreferred:
        return ReadingMode.verticalContinuous;
      case DocumentLayoutHint.pagePreferred:
        return ReadingMode.horizontal;
      case DocumentLayoutHint.continuousPreferred:
        return ReadingMode.verticalContinuous;
    }
  }

  void _restoreProgress() {
    final c = _controller;
    if (c == null || c.document == null) return;

    final width = MediaQuery.sizeOf(context).width;
    c.rebuildMetricsIfNeeded(width);

    if (c.mode.isVertical) {
      final m = c.metrics;
      if (m == null || !_verticalScroll.hasClients) return;
      final y = m
          .pixelFor(c.progress.pageIndex, c.progress.ratioInPage)
          .clamp(0.0, _verticalScroll.position.maxScrollExtent);
      _verticalScroll.jumpTo(y);
      c.updateScrollOffset(y);
    } else {
      final p = _horizontalPager;
      if (p != null && p.hasClients) {
        p.jumpToPage(c.progress.pageIndex.clamp(0, c.pageCount - 1));
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _verticalScroll.dispose();
    _horizontalPager?.dispose();
    // 离开阅读器时恢复正常系统栏（进入时设的 immersive 在这里还原）
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 视口尺寸变化
  //
  // ★★ 血的教训：**build 期间绝不能做任何会改状态的事。**
  //
  //   之前我把 `rebuildMetricsIfNeeded()` 放在 LayoutBuilder 的 builder 里，
  //   它内部会 `notifyListeners()`；而外层 `AnimatedBuilder(animation: c)`
  //   正在 build —— 于是每一帧都触发一次重建：
  //
  //     LayoutBuilder.build → 改 metrics + notifyListeners
  //       → AnimatedBuilder 重建 → LayoutBuilder.build → …
  //
  //   实测症状：`Skipped 136 frames`、单帧 2.58 秒、主线程事件循环被占满，
  //   导致 `await` 的续体**永远轮不到执行** —— 图片字节已经读出来了
  //   （日志能看到 resolver 命中缓存、返回 60047B），但
  //   `setState` 那一步迟迟不执行，界面永远停在 loading。
  //
  //   现在：build 只读尺寸；度量重建只在**打开书 / 跳转 / 尺寸真的变了**时
  //   由显式调用触发，且不在 build 路径上。
  // ------------------------------------------------------------------
  Size? _lastViewport;

  /// 记录视口尺寸。**只做记录，不做重建** —— 可以安全地在 build 里调用。
  void _recordViewport(Size size) {
    final last = _lastViewport;
    if (last != null &&
        (last.width - size.width).abs() < 0.5 &&
        (last.height - size.height).abs() < 0.5) {
      return;
    }
    _lastViewport = size;
    // 真正的重建推迟到帧末，脱离 build 路径
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = _controller;
      if (c == null) return;
      c.rebuildMetricsIfNeeded(size.width);
    });
  }

  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_fatalError != null) {
      return _ReaderErrorScreen(
        error: _fatalError is AppError
            ? _fatalError! as AppError
            : GenericError(''),
        onBack: () => Navigator.of(context).maybePop(),
      );
    }

    final c = _controller!;
    final doc = c.document!;

    return ChangeNotifierProvider<ReaderController>.value(
      value: c,
      // 监听 controller 以便：
      //   - 菜单显隐时调整进度条位置
      //   - 设置变更（背景/字号/亮度）立即生效
      // 注意：**滚动进度不走这里**（它只通知 progressRatio 这个 ValueNotifier），
      //       否则每帧都会重建整棵树。见 DESIGN.md §3.3.1。
      child: AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          final s = c.settings;
          return Scaffold(
            backgroundColor: s.background.color,
            body: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                // 尺寸变化（横竖屏切换 / 分屏拖拽）时重算度量。
                // 在这里同步重建 metrics；位置恢复放在 post-frame 回调里。
                _recordViewport(size);

                return Stack(
                  children: [
                    Positioned.fill(child: _buildReader(c, doc, size)),

                    // 菜单（点击中间显示/隐藏）
                    if (c.menuVisible)
                      _ReaderMenuOverlay(
                        controller: c,
                        document: doc,
                        settings: s,
                        onClose: c.hideMenu,
                        onSettingsChanged: _applySettings,
                        onModeChanged: (mode) {
                          _applySettings(s.copyWith(mode: mode));
                          c.switchMode(mode);
                        },
                        extraction: widget.extraction,
                        bookId: widget.book.id,
                        store: widget.store,
                      ),

                    // 进度条：直接监听 ValueNotifier，与列表重建解耦
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: c.menuVisible ? 72 : 0,
                      child: ReaderProgressBar(controller: c),
                    ),


                    // 亮度遮罩（不改系统亮度，只在阅读器内压暗）
                    if (s.screenBrightness < 1.0)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: Colors.black.withValues(
                              alpha: (1.0 - s.screenBrightness).clamp(0.0, 0.85),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// 设置变更：本地立即生效，同步给 controller（点击区域等要用），并上报落盘
  void _applySettings(ReaderSettings next) {
    _controller?.settings = next;

    widget.onSettingsChanged(next);
  }

  // ------------------------------------------------------------------
  Widget _buildReader(ReaderController c, Document doc, Size viewport) {
    final settings = c.settings;

    // 手势分层（★ 这里踩过一个很隐蔽的坑）：
    //
    //   `GestureDetector` 一旦注册了 `onDoubleTap`，框架会启用
    //   DoubleTapGestureRecognizer，它**在 pointer down 时就抢占手势竞技场**
    //   并一直等到确认"没有第二次点击"才放手。
    //   结果就是：滚动的 Drag 识别器在竞技场里输掉 ——
    //   **上下滑动完全失效**（单击、菜单还能用，所以很容易误判成"滚坏了"）。
    //
    //   实测症状就是：点在页面上能呼出菜单，但怎么滑都纹丝不动。
    //
    //   解决：上下滑动模式**不注册双击**（该模式本来就不需要双击缩放，
    //   缩放由 InteractiveViewer 只在翻页模式处理）。
    //   翻页模式保留双击缩放。
    final content = c.mode.isVertical
        ? _buildVertical(c, doc, settings)
        : _buildHorizontal(c, doc, settings);

    if (c.mode.isVertical) {
      return GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTapUp: (d) => c.handleSingleTap(d.localPosition, viewport),
        child: content,
      );
    }

    // 翻页模式：**不再注册 onDoubleTap**。
    //
    // 框架的 DoubleTapGestureRecognizer 会在 pointer-down 就抢占竞技场，
    // 有两个副作用：
    //   ① 拖动手势被拖累（历史上导致过"上下滑动完全失效"）；
    //   ② 把连续快速点击吞成双击 —— 用户连点"下一页"只翻 1 页。
    // 现在双击改由 `ReaderController.handleSingleTap` 自己按
    // 时间 + 落点判定，处理更可控。
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (d) => c.handleSingleTap(d.localPosition, viewport),
      child: content,
    );
  }

  // ------------------------------------------------------------------
  // 模式 ③：上下滑动 —— 纵向虚拟长页
  //
  // ★ 布局方式（这是前两轮出错的根源，现已修正）：
  //   **不给每一页任何高度约束**，让图片自己决定高度。
  //
  //   只给宽度、不给高度时，Flutter 会把图片缩放到"宽度撑满可用宽度"，
  //   高度按真实宽高比自动算出 → 不拉伸、不裁剪、不留白。
  //   下一张的顶部自然就是上一张的底部，天然无缝。
  //
  //   代价：SliverList 无法预知未构建项的高度，`maxScrollExtent` 是估算值。
  //   解决办法：进度条/百分比跳转仍用 PageMetrics 的**估算几何**，
  //   并在每页解码后把真实比例喂回去（onDimensionResolved），
  //   使估算随阅读收敛；跳转时再按"下落到的实际页码"做一次修正。
  // ------------------------------------------------------------------
  Widget _buildVertical(ReaderController c, Document doc, ReaderSettings settings) {
    final pages = doc.pagesInOrder;

    // 估算几何：仅用于进度显示与百分比跳转（不参与渲染）。
    //
    // ★ 这里**绝不**同步调用 rebuildMetricsIfNeeded —— 它内部会
    //   `notifyListeners()`，而外层 AnimatedBuilder 正在 build，
    //   会形成渲染死循环（实测表现：加载圈缩小、日志 "Skipped 127 frames"、
    //   图片永远加载不出来）。重建统一由 [_recordViewport] 在帧末触发。


    return AnimatedBuilder(
      animation: c.arbiter,
      builder: (context, _) {
        return CustomScrollView(
          controller: _verticalScroll,
          // ★ 预取窗口：上下各 1.5 屏。
          //   ScrollCacheExtent.viewport(1.5) 的语义正是"viewport 主轴长度的 1.5 倍"，
          //   比手写像素换算更准确，也会随横竖屏自动变化。
          scrollCacheExtent: const ScrollCacheExtent.viewport(1.5),
          physics: c.arbiter.lockOuterScroll
              ? const NeverScrollableScrollPhysics()
              : const ClampingScrollPhysics(),
          slivers: [
            SliverList.builder(
              itemCount: pages.length,
              itemBuilder: (context, i) {
                final page = pages[i];
                // 注意这里**没有 SizedBox(height: ...)** —— 这是关键。
                return RepaintBoundary(
                  // RepaintBoundary：一页重绘不牵连其他页
                  child: page.isText
                      ? TextPageView(page: page, settings: settings)
                      : PageImage(
                          page: page,
                          resolver: c.resolver,
                          layoutMode: PageLayoutMode.intrinsic,
                          onDimensionResolved: (dim) =>
                              _onDimensionResolved(c, page.id, dim),
                        ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  /// 页面真实尺寸已知 → 只用于**收敛进度估算**。
  ///
  /// ★ 这里**故意不做滚动位置修正**。
  ///
  ///   原因：长页布局现在由图片真实比例驱动（`SliverList` 用内在高度），
  ///   滚动偏移是绝对的像素值，页面高度变化**不会**让当前内容移位 ——
  ///   已滚过的位置自然稳定。
  ///
  ///   之前那套"回填比例 → 重建度量 → 按锚点 jumpTo"在这里是有害的：
  ///   jumpTo 用的是**估算**度量，反而会把稳稳的滚动位置推偏，
  ///   表现就是"读到一半突然跳一下"。
  ///
  ///   只在用户**主动跳转**（进度条拖动）时才需要修正，
  ///   那条路径由 [ReaderController.jumpToRatioConverging] 负责。
  void _onDimensionResolved(ReaderController c, String pageId, ImageDimension dim) {
    if (!c.backfillAspect(pageId, dim)) return;
    final width = _lastViewport?.width ?? MediaQuery.maybeSizeOf(context)?.width ?? 1080;
    // 合并到下一帧、并做 300ms 防抖，避免每解码一页就全量重算
    c.scheduleMetricsRebuild(width);
  }

  // ------------------------------------------------------------------
  // 模式 ① ②：左右翻页（共用一个 PageView，差异在手势层）
  // ------------------------------------------------------------------
  Widget _buildHorizontal(ReaderController c, Document doc, ReaderSettings settings) {
    final pages = doc.pagesInOrder;

    _horizontalPager ??= PageController(initialPage: c.progress.pageIndex);
    c.attachHorizontalPager(_horizontalPager!);

    return AnimatedBuilder(
      animation: c.arbiter,
      builder: (context, _) {
        return InteractiveViewer(
          // 缩放到 >1 时，翻页必须让位给平移
          panEnabled: c.arbiter.isZoomed,
          scaleEnabled: true,
          minScale: 1.0,
          maxScale: 5.0,
          // ★ 允许无限平移的边界，配合仲裁器实现"边缘交接"
          boundaryMargin: const EdgeInsets.all(double.infinity),
          onInteractionStart: (d) => c.arbiter.onScaleStart(
            ScaleStartDetails(
              focalPoint: d.focalPoint,
              localFocalPoint: d.localFocalPoint,
              pointerCount: d.pointerCount,
            ),
          ),
          onInteractionUpdate: (d) => c.arbiter.onScaleUpdate(
            ScaleUpdateDetails(
              focalPoint: d.focalPoint,
              localFocalPoint: d.localFocalPoint,
              scale: d.scale,
              horizontalScale: d.horizontalScale,
              verticalScale: d.verticalScale,
              rotation: d.rotation,
              pointerCount: d.pointerCount,
              focalPointDelta: d.focalPointDelta,
            ),
            imageSize: MediaQuery.sizeOf(context),
            viewSize: MediaQuery.sizeOf(context),
          ),
          onInteractionEnd: (d) => c.arbiter.onScaleEnd(
            ScaleEndDetails(velocity: d.velocity, pointerCount: d.pointerCount),
          ),
          child: PageView.builder(
            controller: _horizontalPager,
            // ★ 缩放中禁止翻页，否则缩放拖拽会被误判成翻页
            physics: c.arbiter.lockOuterScroll
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemCount: pages.length,
            onPageChanged: c.updatePageIndex,
            itemBuilder: (context, i) {
              final page = pages[i];
              return RepaintBoundary(
                child: page.isText
                    ? TextPageView(page: page, settings: settings)
                    : PageImage(
                        page: page,
                        resolver: c.resolver,
                        // 翻页模式：宽度撑满一屏；
                        //   图片高度未超屏 → 自动居中（用户要求"居中显示"）
                        //   图片高度超屏   → 顶部对齐，可由 InteractiveViewer 平移
                        layoutMode: PageLayoutMode.fitViewport,
                        onDimensionResolved: (dim) =>
                            _onDimensionResolved(c, page.id, dim),
                      ),
              );
            },
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 打开失败
// ---------------------------------------------------------------------------
class _ReaderErrorScreen extends StatelessWidget {
  const _ReaderErrorScreen({required this.error, required this.onBack});

  final AppError error;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white38, size: 48),
              const SizedBox(height: 16),
              Text(
                error.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onBack, child: const Text('返回书架')),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 菜单浮层
// ---------------------------------------------------------------------------
class _ReaderMenuOverlay extends StatelessWidget {
  const _ReaderMenuOverlay({
    required this.controller,
    required this.document,
    required this.settings,
    required this.onClose,
    required this.onSettingsChanged,
    required this.onModeChanged,
    this.extraction,
    this.bookId,
    this.store,
  });

  final ReaderController controller;
  final Document document;
  final ReaderSettings settings;
  final VoidCallback onClose;
  final ValueChanged<ReaderSettings> onSettingsChanged;
  final ValueChanged<ReadingMode> onModeChanged;

  /// 解压缓存管理入口（压缩包来源才有）
  final ExtractionManager? extraction;
  final String? bookId;
  final ByteStore? store;

  @override
  Widget build(BuildContext context) {
    // 分层结构（避免"点按钮同时关闭菜单"的手势冲突）：
    //   底层：半透明遮罩 —— **只负责变暗，不拦截手势**
    //   上层：顶栏 / 底栏（在自己的区域内吃掉手势）
    //
    // ★ 遮罩原来是 `HitTestBehavior.opaque` + `onTap: onClose`，
    //   结果菜单一浮出，底下的翻页手势全被吃掉：想"边调设置边翻页看看效果"
    //   完全做不到。现在改成 IgnorePointer，点击/拖动照常落在阅读区上，
    //   关菜单交给 handleSingleTap 判断（中间区关，两侧区翻页）。
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.18)),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                // —— 顶部栏 ——
                Container(
                  color: Colors.black.withValues(alpha: 0.86),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              document.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600),
                            ),
                            AnimatedBuilder(
                              animation: controller.progressLabel,
                              builder: (ctx, _) => Text(
                                controller.progressLabel.value,
                                style: const TextStyle(
                                    color: Colors.white60, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '阅读设置',
                        icon: const Icon(Icons.tune, color: Colors.white),
                        onPressed: () {
                          onClose();
                          showSettingsSheet(
                            context: context,
                            settings: settings,
                            onChanged: onSettingsChanged,
                            onModeChanged: onModeChanged,
                            document: document,
                            controller: controller,
                            extraction: extraction,
                            bookId: bookId,
                            store: store,
                          );
                        },
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // —— 底部：模式快捷切换 ——
                Container(
                  color: Colors.black.withValues(alpha: 0.82),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: ReadingMode.values.map((mode) {
                      final selected = controller.mode == mode;
                      return Expanded(
                        child: InkWell(
                          onTap: () => onModeChanged(mode),
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  mode.icon,
                                  color: selected ? Colors.white : Colors.white38,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  mode.label,
                                  style: TextStyle(
                                    color: selected ? Colors.white : Colors.white38,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
