/// 单页图片渲染。
///
/// ## 血泪总结：前两轮为什么都错了
///
/// 前两轮我都在**用父级给定的盒子 + `fit` 去迁就图片**，结果两头不讨好：
///   - `BoxFit.fill`    → 拉伸变形（用户："高度被压缩"）
///   - `BoxFit.cover`   → 裁掉多出来的（用户："下面一部分被遮住"）
///   - `BoxFit.contain` → 留白（长页出现缝隙）
///
/// 根因：**只要父级高度与图片真实高度不一致，三种 fit 都必然出问题。**
///
/// ## 正确做法：撤掉高度约束，让图片自己决定高度
///
/// 只给宽度、不给高度：
///
/// ```dart
/// Image(image: provider, width: double.infinity)   // 注意：没有 height
/// ```
///
/// Flutter 会把图片缩放到**宽度撑满可用宽度**，高度按真实宽高比自动算出：
///
/// ```
/// 显示宽 = 可用宽
/// 显示高 = 可用宽 / (图片宽 / 图片高)
/// ```
///
/// 于是 **不拉伸、不裁剪、不留白** 三项同时成立，
/// 而且**完全不需要预先知道图片尺寸** —— 解码器自己知道。
///
/// ## 三种场景下的对齐规则（按用户要求实现）
///
/// | 场景 | 布局 | 效果 |
/// |---|---|---|
/// | 上下滑动（长页） | 不给 height，直接放进 SliverList | 宽撑满 + 顶部对齐；**下一张顶部 = 上一张底部**（天然无缝） |
/// | 左右翻页 | 撑满一屏 + `fitWidth` + `topCenter` | 宽撑满；**高度未超屏 → 自动居中**；**超屏 → 顶部对齐** |
///
/// 关键：`BoxFit.fitWidth` 在"容器高 > 图片高"时会**居中**内容，
/// 在"容器高 < 图片高"时会把内容**顶部对齐**并溢出 ——
/// 正好就是要的两条规则，不需要手写任何判断。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/errors.dart';
import '../../../core/image_header.dart';
import '../../../reader/document.dart';
import '../../../reader/page_cache.dart';

/// 页面在两种阅读模式下的渲染方式
enum PageLayoutMode {
  /// 长页模式（上下滑动）：只约束宽度，高度由图片真实比例决定
  intrinsic,

  /// 翻页模式（左右滑动/点击）：撑满一屏，fitWidth + topCenter
  fitViewport,
}

class PageImage extends StatefulWidget {
  const PageImage({
    super.key,
    required this.page,
    required this.resolver,
    this.layoutMode = PageLayoutMode.intrinsic,
    this.onDimensionResolved,
    this.knownHeight,
    this.onHeightResolved,
    this.maxRetries = 3,
  });

  final PageNode page;
  final PageByteResolver resolver;

  final PageLayoutMode layoutMode;

  /// 解码后回传真实尺寸。
  ///
  /// 注意：**渲染已经完全不需要它了**（布局由解码器驱动）。
  /// 它只用于修正"进度条/百分比跳转"的**估算**几何，
  /// 让百分比显示的误差尽快收敛。
  final void Function(ImageDimension dim)? onDimensionResolved;

  /// 已解码页的已知真实布局高度（长页模式占位用）。
  ///
  /// SliverList 回收重建时，占位若用嗅探估算比例，高度不一致会造成
  /// 「占位高 → 真实高」跳变；用这里传入的真实高度则无跳变。
  /// null = 该页还没解码过（退化到嗅探估算）。
  final double? knownHeight;

  /// 该页的布局高度确定或变化时回调（仅长页模式）。
  ///
  /// 首次测量 oldHeight 为 null（只是记录，不补偿）；
  /// 之后的 oldHeight → newHeight 变化正是「占位 ↔ 真实」的跳变时刻，
  /// UI 层用它做滚动位置补偿，让正在看的内容纹丝不动。
  /// boxTop 是页顶相对屏幕顶的 Y 坐标（沉浸式下 ≈ 视口顶）。
  final void Function(String pageId, double? oldHeight, double newHeight,
      double boxTop)? onHeightResolved;

  final int maxRetries;

  @override
  State<PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<PageImage> {
  Uint8List? _bytes;
  Object? _error;
  bool _loading = false;
  int _attempt = 0;
  Timer? _retryTimer;
  bool _reportedDimension = false;

  /// 高度追踪的代际标记：页 id 变化时换新，迫使 [_HeightTracker]
  /// 重新从占位高度开始，不会把上一页的高度当成这一页的基线。
  Object _heightTrackerKey = Object();

  /// 解码宽度上限。
  ///
  /// ★ 这是性能与内存的关键开关，而且必须**固定不变**：
  ///   解码宽度一旦变化，Flutter 会把它当成新的 ImageProvider key 而**重新解码**。
  ///   所以只依赖设备的物理屏宽（横竖屏切换才会变），绝不依赖图片自身尺寸。
  ///
  /// 为什么必须限制：不限制就会按**原图分辨率**解码。
  ///   一张 3000×4000 的漫画页解码后占 3000×4000×4 ≈ 48MB，
  ///   缓存几张就把内存打满，进而疯狂 GC —— 表现就是"加载很慢、发烫"。
  ///   限制到屏幕物理宽（1080p 屏约 1080px）后，同一张图只占约 6MB。
  int _decodeWidth = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mq = MediaQuery.maybeOf(context);
    final dpr = mq?.devicePixelRatio ?? 1.0;
    final logical = mq?.size.width ?? 1080;
    final w = (logical * dpr).round().clamp(320, 2048);
    if (_decodeWidth != w) _decodeWidth = w;
  }

  @override
  void didUpdateWidget(covariant PageImage old) {
    super.didUpdateWidget(old);
    if (old.page.id != widget.page.id) {
      _attempt = 0;
      _error = null;
      _bytes = null;
      _reportedDimension = false;
      _heightTrackerKey = Object(); // 页换了：高度追踪从零开始
      _load();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    if (widget.page.content is! ImageContent) return;

    _loading = true;
    try {
      // 传 PageNode 而不是 bytes —— 字节的获取与缓存全部由 resolver 负责
      final bytes = await widget.resolver.imageBytes(widget.page);

      // ★ 真实尺寸回填必须**先于** mounted 检查：页在字节到达前被滑出
      //   缓存窗口而销毁是常态（快速甩动 + NAS 延迟）。销毁后如果跳过
      //   回填，这一页的真实比例就永远丢了 —— 下次进入缓存窗口又是
      //   中位数估算占位 → 再解码 → 再跳变 → 再补偿，无限重复。
      //   这正是「读到一半画面反复闪回（4↔3 来回跳）」的放大器
      //   （0.15.3 嗅探降档后占位误差更大，触发更频繁）。回填走的是
      //   controller 回调，生命周期长于本 widget，安全。
      if (!_reportedDimension) {
        _reportedDimension = true;
        final dim = ImageHeaderParser.tryParse(bytes);
        if (dim != null && dim.aspectRatio.isFinite && dim.aspectRatio > 0.02) {
          widget.onDimensionResolved?.call(dim);
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _bytes = bytes;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      _loading = false;
      _attempt++;
      if (_attempt <= widget.maxRetries) {
        // 指数退避：150 / 300 / 600ms
        final delay = Duration(milliseconds: 150 * (1 << (_attempt - 1)));
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () {
          if (mounted) _load();
        });
      } else {
        setState(() => _error = e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ErrorPlaceholder(
        error: _error!,
        onRetry: () {
          _attempt = 0;
          _error = null;
          _load();
        },
      );
    }

    final bytes = _bytes;
    if (bytes == null) {
      // ★★ 关键性能点：占位必须**撑满估算高度**，不能是零高度。
      //
      //   长页模式用的是变高的 `SliverList`。如果占位高度是 0、
      //   图片解码后才变成 1600，那么**每一次加载都会让下方所有项重排**
      //   （`RenderSliverList` 必须重新布局），滚动时就是持续的卡顿。
      //
      //   而导入阶段已经嗅探出了每页的 `aspectRatio`（只读文件头，
      //   精度足够），所以占位直接用 `AspectRatio` 撑出同样的高度 ——
      //   图片加载完成后高度**完全一致**，没有任何重排。
      //
      //   万一嗅探值不准（罕见），`onDimensionResolved` 会在真实解码后
      //   回填并重建度量，误差只会出现一次，不会持续抖动。
      if (widget.layoutMode == PageLayoutMode.fitViewport) {
        return const SizedBox.expand(child: _LoadingPlaceholder());
      }
      if (widget.knownHeight != null &&
          widget.knownHeight!.isFinite &&
          widget.knownHeight! > 0) {
        // 解码过的页：占位直接用真实高度，回收重建零跳变。
        // （比嗅探估算更准，必须排在 AspectRatio 之前。）
        return SizedBox(
            height: widget.knownHeight, child: const _LoadingPlaceholder());
      }
      final ar = widget.page.aspectRatio;
      if (ar != null && ar.isFinite && ar > 0.02 && ar < 50) {
        return AspectRatio(
          aspectRatio: ar,
          child: const _LoadingPlaceholder(),
        );
      }
      // 连估算值都没有（极少见）→ 给一个保守的高占位，避免零高度重排。
      // 旧实现直接放 _LoadingPlaceholder（22px 高的窄条 spinner），
      // 恰好复现了它想避免的"解码后高度跳变"。
      return const SizedBox(height: 240, child: _LoadingPlaceholder());
    }

    // ★ 显式构造 ImageProvider，并用 [ResizeImage] 限制解码宽度。
    //
    //   两个方面都很关键：
    //
    //   1) `MemoryImage` 的 `==` 按**字节内容**比较 →
    //      Flutter 的 ImageCache 能跨重建复用**已解码的 ui.Image**。
    //      否则每次 setState / 每帧都可能重新解码一张大图（几十毫秒），
    //      这正是"加载很慢"的重要来源。
    //
    //   2) 不限制解码宽度就会按**原图分辨率**解码：
    //      3000×4000 的漫画页解码后占 3000×4000×4 ≈ 48MB，
    //      缓存几张就把内存打满，引发疯狂 GC（表现为卡顿 + 发烫）。
    //      限制到屏幕物理宽后，同一张图只占约 6MB。
    //
    //   注意 `allowUpscaling: true`：低分辨率条漫在宽屏上也要能撑满宽度，
    //   否则用户看到的就是"没有铺满屏幕"。
    final ImageProvider provider = _decodeWidth > 0
        ? ResizeImage(
            MemoryImage(bytes),
            width: _decodeWidth,
            policy: ResizeImagePolicy.fit,
            allowUpscaling: true,
          )
        : MemoryImage(bytes);

    // ★ 只给 width，**不给 height**。
    //   `fitWidth` 在不受高度约束时等价于"按宽度等比缩放"：
    //   显示宽 = 可用宽，显示高 = 可用宽 / 真实比例 → 不拉伸、不裁剪、不留白。
    final image = Image(
      image: provider,
      width: double.infinity,
      fit: BoxFit.fitWidth,
      alignment: Alignment.topCenter,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      // ★★ 闪回 bug 的根修：字节就位 ≠ 解码就绪。
      //   `Image` 在首帧解码完成前 RenderImage 是 **0 高**，长页模式下
      //   这一页会在 SliverList 里塔缩成 0px —— 正在看的内容整体位移，
      //   页码翻转；解码完成后页高恢复、内容又位移回去；页被窗口边缘
      //   回收重建时再次塔缩……于是「第4页→第3页→第4页」无限循环。
      //   旧占位链只保护了 bytes==null 阶段，没保护「bytes!=null 但
      //   未解码」这个窗口（NAS 延迟 + 大图解码时长达几百毫秒）。
      //   首帧未就绪时按已知比例占位，页高永不为 0。
      frameBuilder: (ctx, child, frame, wasSync) {
        if (frame != null) return child;
        final ar = widget.page.aspectRatio;
        if (ar != null && ar.isFinite && ar > 0.02 && ar < 50) {
          return AspectRatio(
              aspectRatio: ar, child: const _LoadingPlaceholder());
        }
        return const SizedBox(height: 240, child: _LoadingPlaceholder());
      },
      errorBuilder: (ctx, err, st) => _ErrorPlaceholder(
        error: GenericError('图片解码失败：$err'),
        onRetry: null,
      ),
    );

    // 长页模式：直接给出图片，高度由解码器按真实比例决定。
    // 翻页模式：外层用 [PageViewportFrame] 做「未超屏居中 / 超屏顶部对齐」。
    final Widget content = widget.layoutMode == PageLayoutMode.fitViewport
        ? PageViewportFrame(child: image)
        : image;

    // 页面内容渐入：解码完成 0 → 1（200ms），替代"突然出现"。
    // key 绑定页 id：换页时占位 → 图片是新元素，动画重新走一遍；
    // 同一页的重建（setState / 父级 rebuild）不会重启动画。
    final Widget result = TweenAnimationBuilder<double>(
      key: ValueKey(widget.page.id),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (ctx, v, child) => Opacity(opacity: v, child: child),
      child: content,
    );

    // 长页模式：追踪本页布局高度（含占位 → 真实的跳变），供 UI 层做
    // 滚动位置补偿；翻页模式页高固定一屏，没有这个需求。
    if (widget.layoutMode != PageLayoutMode.intrinsic) return result;
    return _HeightTracker(
      generation: _heightTrackerKey,
      onHeight: (oldH, newH, boxTop) =>
          widget.onHeightResolved?.call(widget.page.id, oldH, newH, boxTop),
      child: result,
    );
  }
}

/// 左右翻页用的"一屏框"：宽度撑满，垂直方向按规则对齐。
///
/// 规则（用户明确要求）：
///   - 图片高度**未超屏** → 垂直居中
///   - 图片高度**超屏**   → 顶部对齐（其余部分由 InteractiveViewer 平移查看）
///
/// 实现：`SingleChildScrollView` 只负责"撑满一屏"与"内容超高时可滚动"，
/// 然后用 `ConstrainedBox(minHeight: viewportHeight)` + `Center` 实现居中。
/// 内容超高时 `minHeight` 不产生约束效果，`Center` 退化为自然高度 → 顶部对齐。
///
/// 滚动用 `NeverScrollableScrollPhysics`：翻页模式下的平移交给外层
/// `InteractiveViewer`（双击/双指缩放后可用），避免两套滚动手势打架。
class PageViewportFrame extends StatelessWidget {
  const PageViewportFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedHeight) return child;
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: child),
          ),
        );
      },
    );
  }
}

class _LoadingPlaceholder extends StatelessWidget {
  const _LoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF141414),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _ErrorPlaceholder extends StatelessWidget {
  const _ErrorPlaceholder({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is AppError ? (error as AppError).message : '$error';
    return ColoredBox(
      color: const Color(0xFF1A1A1A),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined,
                  color: Colors.white38, size: 36),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                TextButton(onPressed: onRetry, child: const Text('点击重试')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 长页模式下追踪本页布局高度的变化。
///
/// ## 为什么需要它
///
/// 长页模式（上下滑动）用 `SliverList`，每页**没有固定高度**：
/// 占位阶段用导入时嗅探的 aspectRatio，解码后换成图片真实比例。
/// 两者不一致时，页高会在解码那一刻跳变。
///
/// 跳变的后果不是「这一页变高变矮」这么简单：
/// 视口**上方**的页一旦变高，视口内所有内容被整体顶走 —— 用户正在看的内容
/// 凭空移动；而 Flutter 的滚动位置是绝对像素值，SliverList 不会替你补偿。
/// 表现就是：画面自己往前翻 / 怎么划都闪回同一页。
///
/// ## 它做什么
///
/// 每帧布局后量一次自身高度与页面顶部位置：
///   - 第一次：oldHeight = null，只建立基线（无跳变，UI 层只记录不补偿）；
///   - 之后：oldHeight → newHeight 就是一次真实的「占位 ↔ 真实」跳变，
///     通过 [onHeight] 交给 UI 层做滚动位置补偿。
///
/// 回调在帧末（postFrame）触发，回调内可以安全地做 jumpTo。
class _HeightTracker extends StatefulWidget {
  const _HeightTracker({
    required this.generation,
    required this.onHeight,
    required this.child,
  });

  /// 页代际标记：变化即表示换页，基线重新开始。
  final Object generation;

  final void Function(
      double? oldHeight, double newHeight, double boxTop) onHeight;

  final Widget child;

  @override
  State<_HeightTracker> createState() => _HeightTrackerState();
}

class _HeightTrackerState extends State<_HeightTracker> {
  double? _lastHeight;

  @override
  void didUpdateWidget(covariant _HeightTracker old) {
    super.didUpdateWidget(old);
    if (!identical(old.generation, widget.generation)) {
      _lastHeight = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _MeasuredSize(
      onSize: (size, boxTop) {
        final h = size.height;
        if (!h.isFinite || h <= 0) return;
        final old = _lastHeight;
        if (old == null) {
          _lastHeight = h;
          // 首次基线：此时可能还是占位高度，不记录不补偿。
          widget.onHeight(null, h, boxTop);
          return;
        }
        if ((old - h).abs() < 0.5) return;
        _lastHeight = h;
        widget.onHeight(old, h, boxTop);
      },
      child: widget.child,
    );
  }
}

/// 测量子控件的尺寸与页面顶部位置，变化时在帧末回调。
class _MeasuredSize extends SingleChildRenderObjectWidget {
  const _MeasuredSize({required this.onSize, required super.child});

  final void Function(Size size, double boxTopDy) onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasuredSize(onSize);

  @override
  void updateRenderObject(
      BuildContext context, _RenderMeasuredSize renderObject) {
    renderObject.onSize = onSize;
  }
}

class _RenderMeasuredSize extends RenderProxyBox {
  _RenderMeasuredSize(this.onSize);

  void Function(Size size, double boxTopDy) onSize;

  Size _lastReported = Size.zero;
  bool _scheduled = false;

  @override
  void performLayout() {
    super.performLayout();
    if (_lastReported == size) return;
    _lastReported = size;
    if (_scheduled) return;
    _scheduled = true;
    // 布局阶段不能直接回调（回调里可能 jumpTo）→ 推到帧末。
    // 回调里读的是当时的 size / 位置，一帧内多次变化自动合并。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!attached || !hasSize) return;
      onSize(size, localToGlobal(Offset.zero).dy);
    });
  }
}
