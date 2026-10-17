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
      if (!mounted) {
        return;
      }
      setState(() {
        _bytes = bytes;
        _error = null;
        _loading = false;
      });

      // 顺手把真实尺寸报给上层，用于收敛百分比估算。
      // 纯头部字节解析，成本极低，且只做一次。
      if (!_reportedDimension) {
        _reportedDimension = true;
        final dim = ImageHeaderParser.tryParse(bytes);
        if (dim != null && dim.aspectRatio.isFinite && dim.aspectRatio > 0.02) {
          widget.onDimensionResolved?.call(dim);
        }
      }
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
      final ar = widget.page.aspectRatio;
      if (ar != null && ar.isFinite && ar > 0.02 && ar < 50) {
        return AspectRatio(
          aspectRatio: ar,
          child: const _LoadingPlaceholder(),
        );
      }
      // 连估算值都没有（极少见）→ 给一个保守的高占位，避免零高度重排
      return const _LoadingPlaceholder();
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
      errorBuilder: (ctx, err, st) => _ErrorPlaceholder(
        error: GenericError('图片解码失败：$err'),
        onRetry: null,
      ),
    );

    // 长页模式：直接给出图片，高度由解码器按真实比例决定。
    // 翻页模式：外层用 [PageViewportFrame] 做「未超屏居中 / 超屏顶部对齐」。
    if (widget.layoutMode == PageLayoutMode.fitViewport) {
      return PageViewportFrame(child: image);
    }
    return image;
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
              const Icon(Icons.broken_image_outlined, color: Colors.white38, size: 36),
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

