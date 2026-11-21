import 'package:flutter_test/flutter_test.dart';

import 'package:inkscroll/ui/reader/reader_screen.dart';

// 长页模式「页高跳变 → 滚动位置补偿」的核心判定。
// 这是「自动翻页 / 怎么划都闪回同一页」修复的回归测试：
// 补偿规则一旦被改错（比如对视口内的页也补、或忽略上方页的变矮），
// 这些用例会立即失败。
void main() {
  group('heightJumpCompensationDelta（RC1 补偿判定）', () {
    test('首次基线（无旧高度）不补偿', () {
      expect(
        ReaderScreen.heightJumpCompensationDelta(
            oldHeight: null, newHeight: 900, boxTop: -100),
        0.0,
      );
    });

    test('高度未变化不补偿', () {
      expect(
        ReaderScreen.heightJumpCompensationDelta(
            oldHeight: 900, newHeight: 900, boxTop: -100),
        0.0,
      );
    });

    test('页顶在视口内（boxTop ≥ 0）不补偿，避免把正在看的画面推走', () {
      expect(
        ReaderScreen.heightJumpCompensationDelta(
            oldHeight: 800, newHeight: 1200, boxTop: 0),
        0.0,
      );
      expect(
        ReaderScreen.heightJumpCompensationDelta(
            oldHeight: 800, newHeight: 1200, boxTop: 240),
        0.0,
      );
    });

    test('视口上方的页变高：补偿 +Δ', () {
      expect(
        ReaderScreen.heightJumpCompensationDelta(
            oldHeight: 800, newHeight: 1200, boxTop: -300),
        400,
      );
    });

    test('视口上方的页变矮：补偿 −Δ', () {
      expect(
        ReaderScreen.heightJumpCompensationDelta(
            oldHeight: 1200, newHeight: 800, boxTop: -300),
        -400,
      );
    });

    test('边界：boxTop 恰好为 0 不补偿，略小于 0 才补偿', () {
      expect(
        ReaderScreen.heightJumpCompensationDelta(
            oldHeight: 800, newHeight: 1000, boxTop: 0),
        0.0,
      );
      expect(
        ReaderScreen.heightJumpCompensationDelta(
            oldHeight: 800, newHeight: 1000, boxTop: -0.001),
        200,
      );
    });
  });
}
