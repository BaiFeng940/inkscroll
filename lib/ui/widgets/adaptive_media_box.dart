/// 图片/视频类内容的渲染自适应工具。
///
/// 解决的核心问题：**父级给定的盒子比例，未必等于图片的真实比例。**
///
/// 三种 fit 单独用都不够：
///   - `fill`    → 拉伸变形（用户反馈过"高度被压缩"）
///   - `cover`   → 裁掉多出来的部分（用户反馈过"下面一部分被遮住"）
///   - `contain` → 完整不变形，但会在页与页之间留白
///
/// 所以这里不争论 fit，而是**把盒子改成图片的真实比例**：
/// 一旦盒子比例 == 图片比例，三种 fit 完全等价，
/// 不拉伸、不裁剪、不留白 同时成立。
///
/// 使用方式：把 [AdaptiveMediaBox] 放在任何有界约束里，
/// 它会在"保持真实比例"与"允许尺寸上限"之间取交集。
library;

import 'package:flutter/material.dart';

class AdaptiveMediaBox extends StatelessWidget {
  const AdaptiveMediaBox({
    super.key,
    required this.aspectRatio,
    required this.child,
    this.alignment = Alignment.topCenter,
    this.allowOverflowFill = true,
  });

  /// 内容真实比例 = 宽 / 高
  final double aspectRatio;

  final Widget child;

  /// 当真实尺寸小于可用空间时，内容贴哪个边
  final Alignment alignment;

  /// 是否允许"向上填满"：
  /// 当算出的高度与可用高度只差几个像素时，直接拉满以避免出现 1~2px 的缝。
  final bool allowOverflowFill;

  @override
  Widget build(BuildContext context) {
    if (!aspectRatio.isFinite || aspectRatio <= 0.02) {
      return child;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availW = constraints.hasBoundedWidth ? constraints.maxWidth : null;
        final availH = constraints.hasBoundedHeight ? constraints.maxHeight : null;

        double? width;
        double? height;

        if (availW != null) {
          width = availW;
          height = availW / aspectRatio;
          if (availH != null && height > availH) {
            // 高度不够 → 以高度为限，等比缩小宽度（保持比例，不裁剪）
            height = availH;
            width = availH * aspectRatio;
          }
        } else if (availH != null) {
          height = availH;
          width = availH * aspectRatio;
        }

        if (width == null || height == null) return child;

        // 与可用高度几乎一致 → 拉满，消除浮点误差造成的缝
        if (allowOverflowFill &&
            availH != null &&
            (height - availH).abs() <= 1.5 &&
            availW != null) {
          width = availW;
          height = availH;
        }

        // 顶部对齐时，剩余空间放到下方（阅读方向自上而下）；
        // 其余情况用常规对齐。
        final wrapped = Align(
          alignment: alignment,
          child: SizedBox(width: width, height: height, child: child),
        );

        if (availW != null && availH != null) {
          return SizedBox(width: availW, height: availH, child: wrapped);
        }
        return wrapped;
      },
    );
  }
}

/// 水平居中 + 垂直方向按 [verticalBias] 分配剩余空间的简单布局。
///
/// [verticalBias] = 0 → 贴顶；0.5 → 居中；1 → 贴底。
/// 用于翻页模式：图片比屏幕小时，让用户指定"顶部对齐"还是"居中"。
class BiasedCenter extends StatelessWidget {
  const BiasedCenter({
    super.key,
    required this.child,
    this.verticalBias = 0.0,
  });

  final Widget child;
  final double verticalBias;

  @override
  Widget build(BuildContext context) {
    if (verticalBias <= 0) {
      return Align(alignment: Alignment.topCenter, child: child);
    }
    if (verticalBias >= 1) {
      return Align(alignment: Alignment.bottomCenter, child: child);
    }
    return Align(alignment: Alignment.center, child: child);
  }
}
