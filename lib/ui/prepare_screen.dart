/// 阅读前准备界面：首次打开压缩包时的解压等待页。
///
/// ## 为什么愿意让用户等这一下
///
/// DEFLATE 解压是 CPU 密集操作，在 Dart 里跑在**主 isolate** 上。
/// 之前是"边读边后台解压"，结果每次翻页都要在主线程解压几十~几百 KB ——
/// 用户看到的就是"翻页很慢、会卡"。
///
/// 把解压提前做完之后，每页都是**直接文件 I/O**（几毫秒），
/// 而且能吃到操作系统的页缓存。代价只是**第一次**打开要等一次；
/// 解压产物落盘持久化，第二次打开是秒开。
///
/// 这个页面存在的意义就是：**让这一次等待变得可预期、可取消**，
/// 而不是让用户对着卡顿的翻页猜发生了什么。
library;

import 'package:flutter/material.dart';

import '../data/archive_extractor.dart';
import '../data/byte_store.dart';

class PrepareScreen extends StatefulWidget {
  const PrepareScreen({
    super.key,
    required this.title,
    required this.run,
  });

  final String title;

  /// 执行准备；返回 null 表示成功，返回字符串表示给用户看的提示
  final Future<String?> Function(void Function(ExtractProgress) onProgress) run;

  @override
  State<PrepareScreen> createState() => _PrepareScreenState();
}

class _PrepareScreenState extends State<PrepareScreen> {
  ExtractProgress? _progress;
  String? _notice;
  bool _finished = false;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final notice = await widget.run((p) {
      if (mounted) setState(() => _progress = p);
    });
    if (!mounted) return;
    setState(() {
      _notice = notice;
      _finished = true;
    });
    // 成功就自动进入阅读；有提示则停一下让用户看到原因
    if (notice == null && !_cancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final ratio = (p != null && p.total > 0) ? p.ratio : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 28),

                if (!_finished) ...[
                  SizedBox(
                    width: 220,
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 3,
                      backgroundColor: Colors.white12,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '首次打开需要解压到缓存\n'
                    '之后翻页会明显更快（直接读文件）',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                  if (p != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      '${p.done}/${p.total}'
                      '${p.bytesWritten > 0 ? ' · 已写入 ${ByteStore.humanSize(p.bytesWritten)}' : ''}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    if (p.currentEntry != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        p.currentEntry!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white24, fontSize: 11),
                      ),
                    ],
                  ],
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: () {
                      _cancelled = true;
                      Navigator.of(context).pop(false);
                    },
                    child: const Text(
                      '跳过解压，直接阅读',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ),
                ] else ...[
                  Icon(
                    _notice == null ? Icons.check_circle_outline : Icons.info_outline,
                    color: _notice == null ? Colors.greenAccent : Colors.orangeAccent,
                    size: 40,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _notice ?? '解压完成',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _notice == null ? Colors.white70 : Colors.orangeAccent,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('开始阅读'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
