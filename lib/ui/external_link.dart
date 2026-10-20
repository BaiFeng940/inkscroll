/// 用系统浏览器打开外部链接（设置里的「帮助文档」等）。
///
/// 走的是自带的 Kotlin 通道（`inkscroll/saf` 的 `openUrl`），
/// 不引入 `url_launcher` —— 我们只需要"打开一个 URL"这一个动作，
/// 为它加一个第三方依赖（连带版本解析和新平台实现）不划算。
library;

import 'package:flutter/services.dart';

import '../app_version.dart';

// 转出去，调用方只需要 `import 'external_link.dart'` 就能拿到帮助地址
export '../app_version.dart' show kHelpUrl;

const MethodChannel _channel = MethodChannel('inkscroll/saf');

/// 打开帮助文档。失败时静默 —— 不能因为打不开链接就弹错误打断用户。
Future<bool> openHelpDocs() => openExternalUrl(kHelpUrl);

Future<bool> openExternalUrl(String url) async {
  try {
    final ok = await _channel.invokeMethod<bool>('openUrl', {'url': url});
    return ok ?? true;
  } catch (_) {
    // 没有浏览器 / 调用失败：返回 false 让调用方决定是否提示
    return false;
  }
}
