import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inkscroll/ui/reader/height_jump_compensator.dart';

// 长页阅读器「页高跳变 → 滚动位置补偿」状态机的端到端测试（P2-4）。
//
// 补偿逻辑涉及「Δ 累积 → 帧末合并 → 滚动中延后 → 滚动结束后补做」四段状态，
// 纯函数测试（reader_compensation_test.dart）覆盖不到，这里用真实
// ScrollController 挂到可滚动视图上，驱动完整链路。

/// 测试辅助：把 ScrollController 挂到真实可滚动视图，
/// 让 hasClients / position 可用（补偿逻辑依赖它们）。
class _Harness extends StatefulWidget {
  const _Harness({required this.controller, required this.childHeight});

  final ScrollController controller;
  final double childHeight;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          controller: widget.controller,
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: widget.childHeight)),
          ],
        ),
      ),
    );
  }
}

void main() {
  group('HeightJumpCompensator（页高跳变补偿状态机）', () {
    testWidgets('非滚动状态：flush 直接把 Δ 落到滚动位置', (tester) async {
      final sc = ScrollController();
      await tester.pumpWidget(_Harness(controller: sc, childHeight: 2000));
      await tester.pump();

      final comp = HeightJumpCompensator();
      comp.accumulate(100);
      expect(comp.flush(sc), isTrue);
      expect(sc.offset, closeTo(100, 1e-6));
      expect(comp.pendingDelta, isNull);
    });

    testWidgets('滚动中：不抢滚动，挂监听，滚动结束后补做', (tester) async {
      final sc = ScrollController();
      await tester.pumpWidget(_Harness(controller: sc, childHeight: 2000));
      await tester.pump();

      final comp = HeightJumpCompensator();
      // 模拟用户正在拖动 / 惯性滚动中
      sc.position.isScrollingNotifier.value = true;
      comp.accumulate(100);
      expect(comp.flush(sc), isFalse);
      expect(comp.hasScrollEndHook, isTrue);
      expect(comp.pendingDelta, closeTo(100, 1e-6));

      // 滚动结束（拖动松手、惯性耗尽）→ 监听器应补做补偿
      sc.position.isScrollingNotifier.value = false;
      await tester.pump();
      expect(sc.offset, closeTo(100, 1e-6));
      expect(comp.pendingDelta, isNull);
      expect(comp.hasScrollEndHook, isFalse);
    });

    testWidgets('同帧多页变化：Δ 合并成一次修正', (tester) async {
      final sc = ScrollController();
      await tester.pumpWidget(_Harness(controller: sc, childHeight: 2000));
      await tester.pump();

      final comp = HeightJumpCompensator();
      comp.accumulate(150);
      comp.accumulate(250);
      expect(comp.flush(sc), isTrue);
      expect(sc.offset, closeTo(400, 1e-6));
    });

    testWidgets('Δ 过小（<0.5px）不补偿，保留累积', (tester) async {
      final sc = ScrollController();
      await tester.pumpWidget(_Harness(controller: sc, childHeight: 2000));
      await tester.pump();

      final comp = HeightJumpCompensator();
      comp.accumulate(0.2);
      expect(comp.flush(sc), isFalse);
      expect(sc.offset, closeTo(0, 1e-6));
      expect(comp.pendingDelta, closeTo(0.2, 1e-6)); // 留待后续帧
    });

    testWidgets('补偿不会越过可滚动边界（末屏不甩底）', (tester) async {
      final sc = ScrollController();
      await tester.pumpWidget(_Harness(controller: sc, childHeight: 2000));
      await tester.pump();

      // 先滚到接近底部（留 100px 余量）
      final max = sc.position.maxScrollExtent;
      sc.jumpTo(max - 100);
      await tester.pump();

      final comp = HeightJumpCompensator();
      comp.accumulate(500); // 远超剩余
      expect(comp.flush(sc), isTrue);
      expect(sc.offset, closeTo(max, 1e-6)); // 停在边界，不越界
    });

    testWidgets('dispose 摘掉监听并清空 Δ', (tester) async {
      final sc = ScrollController();
      await tester.pumpWidget(_Harness(controller: sc, childHeight: 2000));
      await tester.pump();

      final comp = HeightJumpCompensator();
      sc.position.isScrollingNotifier.value = true;
      comp.accumulate(100);
      comp.flush(sc);
      expect(comp.hasScrollEndHook, isTrue);

      comp.dispose(sc.position);
      expect(comp.hasScrollEndHook, isFalse);
      expect(comp.pendingDelta, isNull);
    });
  });
}
