import 'package:flutter/widgets.dart';

/// 长页模式「页高跳变 → 滚动位置补偿」的状态机。
///
/// 背景：长页布局中，占位高度（嗅探估算）在图片解码后会被真实高度替换。
/// 视口**上方**的页变高/变矮会把视口内内容整体推走 —— 滚动偏移是绝对像素，
/// SliverList 不会自动跟随，于是用户正在看的内容凭空移动（"闪回""自动翻页"）。
///
/// 补偿规则（见 [ReaderScreen.heightJumpCompensationDelta]）：
/// - 页顶仍在视口上方（boxTop < 0）才补 Δ（高度差）；
/// - 页顶在视口内/下方（boxTop ≥ 0）不补，避免把正在看的画面推走。
///
/// 为什么要独立成类：
/// 1. 补偿链路涉及「Δ 累积 → 帧末合并 → 滚动中延后 → 滚动结束后补做」
///    四段状态，纯函数测试覆盖不到；
/// 2. 拆出来后可以在 widget 测试里直接驱动，不需要真的解码图片。
class HeightJumpCompensator {
  /// 累积中的补偿位移（像素）。null 表示没有待补偿的量。
  double? pendingDelta;

  /// 滚动结束监听是否已挂（同一段滚动期间只挂一次，Δ 持续累积）。
  bool _scrollEndHooked = false;
  VoidCallback? _scrollEndListener;

  /// 累积一段补偿量。
  void accumulate(double delta) {
    pendingDelta = (pendingDelta ?? 0.0) + delta;
  }

  /// 帧末执行：把累积的 Δ 一次性落到滚动位置上。
  ///
  /// 返回是否真的做了补偿。滚动中（用户手指拖动或惯性滚动）**不丢弃**：
  /// 挂一个「滚动结束」监听，等拖动结束 / 惯性耗尽后由 [onScrollEnded] 补做。
  bool flush(ScrollController sc) {
    final d = pendingDelta;
    if (d == null || d.abs() < 0.5) return false;
    if (!sc.hasClients) return false;
    final pos = sc.position;

    if (pos.isScrollingNotifier.value) {
      // 保留 Δ，等滚动结束再补（页高稳定后不再有回调，丢了就永久丢失）。
      hookScrollEnd(pos, sc);
      return false;
    }

    pendingDelta = null;
    final target = (pos.pixels + d).clamp(0.0, pos.maxScrollExtent);
    sc.jumpTo(target);
    return true;
  }

  /// 挂上「滚动结束」监听，等滚动停下来后补做被搁置的补偿。
  void hookScrollEnd(ScrollPosition pos, ScrollController sc) {
    if (_scrollEndHooked) return;
    _scrollEndHooked = true;
    void listener() {
      if (pos.isScrollingNotifier.value) return; // 还在滚，继续等
      detachScrollEnd(pos);
      onScrollEnded(sc);
    }

    _scrollEndListener = listener;
    pos.isScrollingNotifier.addListener(listener);
  }

  /// 滚动结束后的补偿落地（由 [hookScrollEnd] 的监听器调用）。
  bool onScrollEnded(ScrollController sc) {
    final d = pendingDelta;
    if (d == null || d.abs() < 0.5) return false;
    if (!sc.hasClients) return false;
    pendingDelta = null;
    final p = sc.position;
    final target = (p.pixels + d).clamp(0.0, p.maxScrollExtent);
    sc.jumpTo(target);
    return true;
  }

  /// 摘掉滚动结束监听（阅读器退出时必须调用，避免回调打到已销毁的 controller）。
  void detachScrollEnd(ScrollPosition pos) {
    final l = _scrollEndListener;
    _scrollEndListener = null;
    _scrollEndHooked = false;
    if (l != null) pos.isScrollingNotifier.removeListener(l);
  }

  /// 是否挂着滚动结束监听（测试用）。
  bool get hasScrollEndHook => _scrollEndHooked;

  /// 释放：摘监听并清空累积。
  void dispose(ScrollPosition? pos) {
    if (pos != null) detachScrollEnd(pos);
    pendingDelta = null;
  }
}
