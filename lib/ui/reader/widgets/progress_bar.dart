/// 阅读进度条。
///
/// 两个关键设计：
///
/// 1) **直接监听 ValueNotifier，不走 setState 整树重建**
///    滚动回调每帧触发；若进度条刷新触发阅读器重建，必然掉帧。
///
/// 2) **拖动时不真正滚动，松手才跳转**
///    如果 onChanged 里直接 jumpTo，长列表会疯狂重建，
///    而且松手后位置会被滚动回调覆盖，体验很差。
///    这里 onChanged 只更新气泡预览，onChangeEnd 才 animateTo。
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
                    onChangeStart: (v) => setState(() => _preview = v),
                    // 拖动中 → 只更新气泡，不真正滚动
                    onChanged: (v) => setState(() => _preview = v),
                    // 松手 → 真正跳转，并退出预览模式。
                    // 长页模式用收敛式跳转：maxScrollExtent 是估算值，
                    // 直接跳会有偏差，跳完再按实际布局修正两轮。
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
