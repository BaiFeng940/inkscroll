/// 手势仲裁器。
///
/// 要同时满足的手势：单指滚动、单指横向翻页、双指缩放、双击放大、单击分区。
/// 冲突点只有一个核心问题：**缩放到 >1 之后，拖动到底该平移图片还是滚动/翻页？**
///
/// 状态机（与 InteractiveViewer 的真实变换矩阵对齐）：
///
///   双指按下                → scaling：外层翻页让位
///   scale > 1 且未到水平边缘 → panningInside：外层让位
///   scale > 1 且已到水平边缘 → panningAtEdge：把权交还外层（翻页接管）
///   scale == 1             → idle：外层全权接管
///
/// ★ scale 的唯一事实来源是 InteractiveViewer 的 TransformationController
///   （真实矩阵）。旧实现自己累计"相对手势值"，每次捏合都从 1 重新起算，
///   与画面真实状态脱钩 —— 仲裁判定越用越错。
library;

import 'dart:async';

import 'package:flutter/material.dart';

enum GesturePhase {
  /// 未缩放，外层滚动/翻页全权负责
  idle,

  /// 双指缩放中
  scaling,

  /// 已放大且图片内部还有可平移余量
  panningInside,

  /// 已放大但已经拖到水平边缘 → 把权交还外层
  panningAtEdge,
}

/// 单击延迟 / 双击窗口 / 双击落点阈值的唯一事实来源。
///
/// 单击延迟必须 ≥ 双击窗口：双击的第二击到来时，挂起的单击还没兑现，
/// 双击判定先执行并取消它。旧实现延迟 220ms、窗口 300ms，两者错位 ——
/// 220~300ms 间隔的双击会先把菜单弹出来又立刻关掉，
/// 双击缩放在这个区间永远不可达。
class ReaderTiming {
  /// 单击确认延迟（等待可能的第二击）
  static const int singleTapDelayMs = 260;

  /// 双击判定窗口（两次点击的最大间隔，毫秒）
  static const int doubleTapWindowMs = 260;

  /// 两次点击的最大落点距离（逻辑像素）。平台触摸 slop 通常在 18~24，
  /// 旧值 48 太宽，慢速的两次独立点击容易被误判成双击。
  static const double doubleTapSlop = 36;
}

class GestureArbiter extends ChangeNotifier {
  GestureArbiter({double maxScale = 5.0, double snapThreshold = 1.08})
      : _maxScale = maxScale,
        _snapThreshold = snapThreshold;

  final double _maxScale;

  /// 接近 1 就吸附回 1（避免停在 1.02 这种尴尬状态）
  final double _snapThreshold;

  double _scale = 1.0;
  GesturePhase _phase = GesturePhase.idle;
  Offset _doubleTapPosition = Offset.zero;

  double get scale => _scale;
  GesturePhase get phase => _phase;
  Offset get doubleTapPosition => _doubleTapPosition;

  bool get isZoomed =>
      _phase == GesturePhase.scaling || _scale > _snapThreshold;

  /// ★ 外层滚动 / 翻页是否应该被禁用
  bool get lockOuterScroll =>
      _phase == GesturePhase.scaling || _phase == GesturePhase.panningInside;

  void rememberDoubleTapPosition(Offset p) => _doubleTapPosition = p;

  /// 手势开始。双指 → 进入缩放态；单指不改当前状态
  /// （已放大时保持平移态，外层继续锁定）。
  void onInteractionStart(ScaleStartDetails details) {
    if (details.pointerCount >= 2) {
      _phase = GesturePhase.scaling;
      notifyListeners();
    }
  }

  /// 手势更新。[transform] 是 InteractiveViewer 的真实矩阵。
  void onInteractionUpdate(
    ScaleUpdateDetails details, {
    required Matrix4 transform,
    required Size viewSize,
  }) {
    _scale = transform.getMaxScaleOnAxis().clamp(1.0, _maxScale);

    if (details.pointerCount >= 2) {
      _phase = GesturePhase.scaling;
      notifyListeners();
      return;
    }

    // 单指：只有已放大时才可能属于平移 / 边缘交接
    if (_scale > _snapThreshold) {
      final maxX = viewSize.width * (_scale - 1);
      final tx = transform.getTranslation().x;
      final atLeft = tx >= -0.5; // 内容贴到左边界（平移下限 0）
      final atRight = maxX <= 0.5 || tx <= -maxX + 0.5;
      final dx = details.focalPointDelta.dx;
      final dy = details.focalPointDelta.dy;
      final horizontalDrag = dx.abs() > dy.abs() * 1.2;
      _phase = (horizontalDrag && ((dx > 0 && atLeft) || (dx < 0 && atRight)))
          ? GesturePhase.panningAtEdge
          : GesturePhase.panningInside;
      notifyListeners();
    } else if (_phase != GesturePhase.idle) {
      _phase = GesturePhase.idle;
      notifyListeners();
    }
  }

  /// 手势结束。按真实矩阵决定停在哪个状态。
  void onInteractionEnd({required Matrix4 transform}) {
    _scale = transform.getMaxScaleOnAxis().clamp(1.0, _maxScale);
    _phase = _scale > _snapThreshold
        ? GesturePhase.panningInside
        : GesturePhase.idle;
    notifyListeners();
  }

  /// 程序化缩放（双击动画）开始：直接把状态切到目标值。
  void noteExternalZoom(double targetScale) {
    _scale = targetScale.clamp(1.0, _maxScale);
    _phase = _scale > _snapThreshold
        ? GesturePhase.panningInside
        : GesturePhase.idle;
    notifyListeners();
  }

  void resetZoom() {
    _scale = 1.0;
    _phase = GesturePhase.idle;
    notifyListeners();
  }
}

/// 单击 / 双击的仲裁。
///
/// 关键：`onTap` 一定先于 `onDoubleTap` 触发，所以单击必须延迟
/// [ReaderTiming.singleTapDelayMs]。太短 → 双击被误判成两次单击；
/// 太长 → 单击感觉有延迟。
class TapArbiter {
  TapArbiter({
    this.doubleTapDelay =
        const Duration(milliseconds: ReaderTiming.singleTapDelayMs),
  });

  final Duration doubleTapDelay;
  Timer? _timer;

  /// 当前挂起（尚未确认）的单击回调
  VoidCallback? _pending;

  /// 提交一次单击。若在 [doubleTapDelay] 内出现双击，回调会被取消。
  void submitSingleTap(VoidCallback onSingleTap) {
    _timer?.cancel();
    _pending = onSingleTap;
    _timer = Timer(doubleTapDelay, () {
      _pending = null;
      onSingleTap();
    });
  }

  /// **立刻执行**挂起的单击。
  ///
  /// 连续快速翻页时必须这样处理：用户点了 5 下"下一页"，
  /// 若每一下都只是覆盖挂起回调（旧的被 cancel），
  /// 最终只会翻 1 页 —— 实测就是这个症状。
  void flushPending() {
    final cb = _pending;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    cb?.call();
  }

  /// 双击发生时调用：取消挂起的单击
  void cancelPendingTap() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  void dispose() => _timer?.cancel();
}
