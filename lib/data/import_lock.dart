/// 批量导入期间的「后台保持」：持有 CPU 唤醒锁 + Wi-Fi 高性能锁。
///
/// 不加这个的话，用户把应用切到后台或息屏后，Android 会降频 CPU、
/// 让 Wi-Fi 进省电模式，几十本压缩包的导入会明显变慢甚至被系统掐断。
///
/// 锁带 30 分钟超时（见 SafFolderPlugin.kt），即使释放没被调到也不会一直耗电。
library;

import 'package:flutter/services.dart';

const MethodChannel _ch = MethodChannel('inkscroll/saf');

/// 获取锁。失败返回 false —— 不该因为拿不到锁就让导入失败。
Future<bool> acquireImportLock() async {
  try {
    return await _ch.invokeMethod<bool>('acquireImportLock') ?? false;
  } catch (_) {
    return false;
  }
}

Future<void> releaseImportLock() async {
  try {
    await _ch.invokeMethod<void>('releaseImportLock');
  } catch (_) {
    // 释放失败无所谓：原生侧有超时兜底
  }
}
