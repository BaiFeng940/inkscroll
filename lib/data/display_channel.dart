/// 显示相关的原生通道：屏幕常亮 + 刷新率档位。
///
/// 常亮走原生 FLAG_KEEP_SCREEN_ON 而不引 wakelock_plus：
/// 只为一个 window flag 加一个插件不值（依赖纪律），原生侧 6 行。
/// 旧版本 keepScreenOn 设置项只存值、无任何调用点，从不生效 —— 这里补上。
library;

import 'package:flutter/services.dart';

class DisplayChannel {
  const DisplayChannel._();

  static const MethodChannel _ch = MethodChannel('inkscroll/display');

  /// 阅读时保持屏幕常亮。失败静默 —— 不影响阅读本身。
  static Future<void> setKeepScreenOn(bool on) async {
    try {
      await _ch.invokeMethod<void>('setKeepScreenOn', {'on': on});
    } catch (_) {
      // 桌面端 / 通道未注册时静默
    }
  }

  /// 设置高刷档位：sixty（60 帧）/ max（最高帧率）
  /// （见 ReaderSettings.highRefreshMode）。
  ///
  /// 旧实现写死"≤120Hz 的最大档"，144Hz 设备被压到 60Hz；现在交给用户选。
  static Future<void> setRefreshMode(String mode) async {
    try {
      await _ch.invokeMethod<void>('setRefreshMode', {'mode': mode});
    } catch (_) {
      // 同上
    }
  }
}
