/// 阅读进度条。
///
/// 两个关键设计：
///
/// 1) **直接监听 ValueNotifier，不走 setState 整树重建**
///    滚动回调每帧触发；若进度条刷新触发阅读器重建，必然掉帧。
///
/// 2) **拖动时实时预览内容（节流），松手后精确收敛**
///    只在 onChanged 里更新数字，用户根本看不出会停在哪一页；
///    但每帧都让长列表滚动又会掉帧。折中是每 ~70ms 真正移动一次。
///    松手时用 `jumpToRatioConverging`：长页的 maxScrollExtent 是估算值，
///    要跳完再按实际布局修正两轮才准。
library;

import 'package:flutter/material.dart';

import '../../../reader/reader_controller.dart';

class ReaderProgressBar extends StatefulWidget {
  const ReaderProgressBar({super.key, required this.controller});

  final ReaderController controller;

  @override
  State<ReaderProgressBar> createState() => _ReaderProgressBarState();
}

class _ReaderProgressBarState extends State<ReaderProgressBar> {
  /// 拖动中的预览值；为 null 表示当前显示真实进度
  double? _preview;

  /// 上一次预览跳转的时间 —— 用来节流。
  ///
  /// 拖动时 `onChanged` 触发非常密集（每帧都可能），每次都让长列表
  /// 滚动会掉帧；但完全不预览又只能"松手才看到结果"。
  /// 折中：**每 ~70ms 实际移动一次视图**，肉眼是连贯的，代价可控。
  DateTime? _lastPreviewAt;

  static const _previewInterval = Duration(milliseconds: 70);

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return ValueListenableBuilder<double>(
      valueListenable: c.progressRatio,
      builder: (context, ratio, _) {
        final value = (_preview ?? ratio).clamp(0.0, 1.0);
        final label = _preview == null
            ? _labelFor(ratio)
            : _labelFor(_preview!);

        return Container(
          color: Colors.black.withValues(alpha: 0.45),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          height: 34,
          child: Row(
            children: [
              SizedBox(
                width: 74,
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: value,
                    // 拖动开始 → 进入预览模式，暂停进度回写
                    onChangeStart: (v) {
                      _lastPreviewAt = null;
                      setState(() => _preview = v);
                    },
                    // 拖动中 → **实时预览内容**（节流），用户能直接看到
                    // 松手后会停在哪一页，而不是只有数字在变。
                    onChanged: (v) {
                      setState(() => _preview = v);
                      final now = DateTime.now();
                      if (_lastPreviewAt == null ||
                          now.difference(_lastPreviewAt!) >= _previewInterval) {
                        _lastPreviewAt = now;
                        c.previewRatio(v);
                      }
                    },
                    // 松手 → 精确定位（长页模式用收敛式跳转：
                    // maxScrollExtent 是估算值，跳完要按实际布局修正两轮）
                    onChangeEnd: (v) {
                      c.jumpToRatioConverging(v, animate: true);
                      setState(() => _preview = null);
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${(value * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _labelFor(double ratio) {
    final c = widget.controller;
    final total = c.pageCount;
    if (total <= 0) return '--/--';
    // 用比例反推页码，拖动时能实时看到"会跳到第几页"
    final page = ((ratio * (total - 1)).round() + 1).clamp(1, total);
    return '$page/$total';
  }
}
