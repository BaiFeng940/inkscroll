/// 散图导入前的**顺序调整**界面。
///
/// ## 为什么需要它
///
/// 用户反馈"通过手动选择图片导入的漫画排序有些问题"。根因是旧实现
/// 给文件加了 `00001_` 前缀、**按选择顺序**排列，把用户用文件名表达的
/// 顺序（`1.jpg`、`2.jpg`、`10.jpg`）覆盖掉了。
///
/// 现在默认按**文件名自然排序**，但现实里总有例外：
///   - 文件名毫无规律（相机默认的 `IMG_20240101_xxxx.jpg` 可能跨天乱序）
///   - 用户就是想要某个自定义顺序
///
/// 所以再给一个手动调整入口：列表 + 上下移动 + 置顶，外加"恢复按文件名排序"。
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../importers/import_utils.dart';

/// 返回调整后的顺序；用户取消时返回 null
Future<List<String>?> showImageOrderSheet({
  required BuildContext context,
  required List<String> paths,
  String title = '调整顺序',
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ImageOrderSheet(paths: paths, title: title),
  );
}

class _ImageOrderSheet extends StatefulWidget {
  const _ImageOrderSheet({required this.paths, required this.title});

  final List<String> paths;
  final String title;

  @override
  State<_ImageOrderSheet> createState() => _ImageOrderSheetState();
}

class _ImageOrderSheetState extends State<_ImageOrderSheet> {
  late List<String> _order;
  int _lastMoved = -1;

  @override
  void initState() {
    super.initState();
    _order = [...widget.paths];
  }

  static String _name(String path) => p.basename(path);

  /// 恢复"按文件名自然排序"
  void _applyNaturalSort() {
    setState(() {
      _order.sort((a, b) => compareByOriginalName(_name(a), _name(b)));
      _lastMoved = -1;
    });
    _toast('已按文件名自然排序（2 排在 10 前面）');
  }

  /// 恢复"最初选择的顺序"
  void _applyOriginalOrder() {
    setState(() {
      _order = [...widget.paths];
      _lastMoved = -1;
    });
    _toast('已恢复为最初选择的顺序');
  }

  void _move(int from, int delta) {
    final to = from + delta;
    if (to < 0 || to >= _order.length) return;
    setState(() {
      final item = _order.removeAt(from);
      _order.insert(to, item);
      _lastMoved = to;
    });
  }

  void _moveToTop(int from) {
    if (from == 0) return;
    setState(() {
      final item = _order.removeAt(from);
      _order.insert(0, item);
      _lastMoved = 0;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF1E1E1E) : Colors.white;
    final fg = dark ? Colors.white : Colors.black87;

    return SafeArea(
      child: Container(
        color: bg,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: Column(
          children: [
            // 顶部标题 + 关闭
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: TextStyle(
                            color: fg,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '共 ${_order.length} 张 · 顺序即阅读顺序',
                          style: TextStyle(
                            color: fg.withValues(alpha: 0.55),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: fg.withValues(alpha: 0.7)),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // 快捷操作
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.sort, size: 16),
                    label: const Text('按文件名排序', style: TextStyle(fontSize: 12)),
                    onPressed: _applyNaturalSort,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.restore, size: 16),
                    label: const Text('选择顺序', style: TextStyle(fontSize: 12)),
                    onPressed: _applyOriginalOrder,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Divider(height: 1, color: fg.withValues(alpha: 0.12)),

            // 列表
            Expanded(
              child: ListView.builder(
                itemCount: _order.length,
                itemExtent: 52,
                itemBuilder: (context, i) {
                  final path = _order[i];
                  final highlighted = i == _lastMoved;
                  return Container(
                    color: highlighted
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                        : null,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        // 序号
                        SizedBox(
                          width: 40,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              color: fg.withValues(alpha: 0.5),
                              fontSize: 12,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            _name(path),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: fg, fontSize: 13),
                          ),
                        ),
                        _IconBtn(
                          icon: Icons.vertical_align_top,
                          tooltip: '移到最前',
                          onTap: i == 0 ? null : () => _moveToTop(i),
                          fg: fg,
                        ),
                        _IconBtn(
                          icon: Icons.keyboard_arrow_up,
                          tooltip: '上移',
                          onTap: i == 0 ? null : () => _move(i, -1),
                          fg: fg,
                        ),
                        _IconBtn(
                          icon: Icons.keyboard_arrow_down,
                          tooltip: '下移',
                          onTap: i == _order.length - 1 ? null : () => _move(i, 1),
                          fg: fg,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            Divider(height: 1, color: fg.withValues(alpha: 0.12)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '提示：也可以用「按文件名排序」一键整理',
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.45),
                        fontSize: 11,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_order),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.fg,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 20,
            color: fg.withValues(alpha: enabled ? 0.75 : 0.2),
          ),
        ),
      ),
    );
  }
}
