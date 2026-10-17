/// 手势仲裁器。
///
/// 要同时满足的手势：单指滚动、单指横向翻页、双指缩放、双击放大、单击分区。
/// 冲突点只有一个核心问题：**缩放到 >1 之后，拖动到底该平移图片还是滚动/翻页？**
///
/// 采用的规则（对应方案 B：每页独立缩放 + 边缘交接）：
///
///   多指(≥2) 按下        → 缩放态：外层滚动/翻页全部让位（lockOuterScroll = true）
///   scale > 1 且未到边缘  → 平移态：外层让位
///   scale > 1 且已到边缘  → 交接态：外层接管，手感自然续接
///   scale == 1           → 空闲态：外层全权接管
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

  /// 已放大但已经拖到图片边缘（或该方向没有余量）→ 把权交还外层
  panningAtEdge,
}

class GestureArbiter extends ChangeNotifier {
  GestureArbiter({double maxScale = 5.0, double snapThreshold = 1.08})
      : _maxScale = maxScale,
        _snapThreshold = snapThreshold;

  final double _maxScale;

  /// 接近 1 就吸附回 1（避免停在 1.02 这种尴尬状态）
  final double _snapThreshold;

  double _scale = 1.0;
  Offset _pan = Offset.zero;
  GesturePhase _phase = GesturePhase.idle;
  Offset _doubleTapPosition = Offset.zero;

  double get scale => _scale;
  Offset get pan => _pan;
  GesturePhase get phase => _phase;
  bool get isZoomed => _scale > _snapThreshold;
  Offset get doubleTapPosition => _doubleTapPosition;

  /// ★ 外层滚动 / 翻页是否应该被禁用
  bool get lockOuterScroll =>
      _phase == GesturePhase.scaling || _phase == GesturePhase.panningInside;

  void rememberDoubleTapPosition(Offset p) => _doubleTapPosition = p;

  void onScaleStart(ScaleStartDetails details, {Size? imageSize, Size? viewSize}) {
    if (details.pointerCount >= 2) {
      _phase = GesturePhase.scaling;
    }
    notifyListeners();
  }

  void onScaleUpdate(
    ScaleUpdateDetails details, {
    required Size imageSize,
    required Size viewSize,
  }) {
    _scale = details.scale.clamp(1.0, _maxScale);
    _pan = details.focalPointDelta;

    if (_scale > _snapThreshold) {
      final atEdge = isAtEdge(details.focalPointDelta, imageSize, viewSize);
      _phase = atEdge ? GesturePhase.panningAtEdge : GesturePhase.panningInside;
    } else {
      _phase = GesturePhase.idle;
    }
    notifyListeners();
  }

  void onScaleEnd(ScaleEndDetails details) {
    if (_scale < _snapThreshold) {
      _scale = 1.0;
      _phase = GesturePhase.idle;
    } else {
      _phase = GesturePhase.panningInside;
    }
    notifyListeners();
  }

  /// 双击：放大到 2x 或还原
  void toggleZoom() {
    if (_scale > _snapThreshold) {
      resetZoom();
    } else {
      _scale = 2.0;
      _phase = GesturePhase.panningInside;
      notifyListeners();
    }
  }

  void resetZoom() {
    _scale = 1.0;
    _pan = Offset.zero;
    _phase = GesturePhase.idle;
    notifyListeners();
  }

  /// 判断这次拖动是否已经"拖到边缘"。
  ///
  /// 简单而有效的判据：放大后图片在某个方向上还有溢出（可以平移），
  /// 那么往"没有溢出"的方向拖就已经到边缘了 —— 此时应把拖动交给外层，
  /// 用户才能继续滚到下一页；如果两个方向都没有溢出，直接算是到边缘。
  bool isAtEdge(Offset delta, Size imageSize, Size viewSize) {
    final scaledW = imageSize.width * _scale;
    final scaledH = imageSize.height * _scale;
    final overflowX = scaledW - viewSize.width;
    final overflowY = scaledH - viewSize.height;

    final hasX = overflowX > 1.0;
    final hasY = overflowY > 1.0;
    if (!hasX && !hasY) return true;

    // 纵向还有余量，且用户是纵向拖动 → 让内层平移
    if (hasY && delta.dy.abs() >= delta.dx.abs()) return false;
    // 横向还有余量，且用户是横向拖动 → 让内层平移
    if (hasX && delta.dx.abs() > delta.dy.abs()) return false;

    return true;
  }
}

/// 单击 / 双击 / 长按的仲裁。
///
/// 关键：`onTap` 一定先于 `onDoubleTap` 触发，所以单击必须延迟 220ms。
/// 太短 → 双击被误判成两次单击；太长 → 单击感觉有延迟。
class TapArbiter {
  TapArbiter({this.doubleTapDelay = const Duration(milliseconds: 220)});

  final Duration doubleTapDelay;
  Timer? _timer;

  /// 提交一次单击。若在 [doubleTapDelay] 内出现双击，回调会被取消。
  void submitSingleTap(VoidCallback onSingleTap) {
    _timer?.cancel();
    _timer = Timer(doubleTapDelay, onSingleTap);
  }

  /// 双击发生时调用：取消挂起的单击
  void cancelPendingTap() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => _timer?.cancel();
}
