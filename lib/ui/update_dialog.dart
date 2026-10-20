/// 更新提示弹窗。
///
/// 放在同一个地方给「启动自动检查」和「设置里手动检查」复用，
/// 避免两处各写一份对话框、文案逐渐不一致。
library;

import 'package:flutter/material.dart';

import '../app_version.dart';
import '../data/update_service.dart';
import 'external_link.dart';

/// 有更新时弹窗；返回 true 表示用户选择了"去下载"。
///
/// [manual] 为 true 表示是用户主动点的检查 —— 这种情况下即使没有更新
/// 也要给反馈，否则用户会以为按钮坏了。
Future<bool> showUpdateDialog(
  BuildContext context, {
  required UpdateCheckResult result,
  required bool manual,
  Future<void> Function(String version)? onSkip,
}) async {
  if (!result.hasUpdate) {
    if (!manual) return false;
    // 手动检查：明确告诉结果
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('已是最新版本'),
          content: Text(
            result.latest == null
                ? '暂时无法获取版本信息（网络或镜像不可用）。\n当前版本 $kAppVersion。'
                : '当前版本 $kAppVersion，已是最新。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('好'),
            ),
          ],
        ),
      );
    }
    return false;
  }

  final notes = (result.notes ?? '').trim();
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('发现新版本 ${result.latest}'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前版本 $kAppVersion',
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
            if (result.sourceName != null)
              Text('来源：${result.sourceName}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                notes.length > 600 ? '${notes.substring(0, 600)}…' : notes,
                style: const TextStyle(fontSize: 13, height: 1.55),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (onSkip != null && result.latest != null)
          TextButton(
            onPressed: () async {
              await onSkip(result.latest!.toString());
              if (ctx.mounted) Navigator.of(ctx).pop(false);
            },
            child: const Text('跳过此版本'),
          ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('去下载'),
        ),
      ],
    ),
  );

  if (go == true && result.downloadUrl != null) {
    final ok = await openExternalUrl(result.downloadUrl!);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('没能打开浏览器。可手动访问：${result.downloadUrl}'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
  return go == true;
}
