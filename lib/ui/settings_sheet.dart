/// 阅读器内部设置面板（模式 / 背景 / 字号 / 行距 / 边距 / 点击区域 / 亮度 / 章节跳转）。
library;

import 'package:flutter/material.dart';

import '../data/archive_extractor.dart';
import '../data/byte_store.dart';
import '../data/models/reader_settings.dart';
import '../reader/document.dart';
import '../reader/reader_controller.dart';

Future<void> showSettingsSheet({
  required BuildContext context,
  required ReaderSettings settings,
  required ValueChanged<ReaderSettings> onChanged,
  required ValueChanged<ReadingMode> onModeChanged,
  required Document document,
  required ReaderController controller,
  ExtractionManager? extraction,
  String? bookId,
  ByteStore? store,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    isScrollControlled: true,
    builder: (ctx) => _SettingsSheet(
      settings: settings,
      onChanged: onChanged,
      onModeChanged: onModeChanged,
      document: document,
      controller: controller,
      extraction: extraction,
      bookId: bookId,
      store: store,
    ),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.settings,
    required this.onChanged,
    required this.onModeChanged,
    required this.document,
    required this.controller,
    this.extraction,
    this.bookId,
    this.store,
  });

  final ReaderSettings settings;
  final ValueChanged<ReaderSettings> onChanged;
  final ValueChanged<ReadingMode> onModeChanged;
  final Document document;
  final ReaderController controller;

  /// 解压缓存管理（可选；只有压缩包来源的书才有）
  final ExtractionManager? extraction;
  final String? bookId;
  final ByteStore? store;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late ReaderSettings _s = widget.settings;

  void _update(ReaderSettings next) {
    setState(() => _s = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle('阅读模式'),
              ...ReadingMode.values.map((mode) => RadioListTile<ReadingMode>(
                    value: mode,
                    // ignore: deprecated_member_use
                    groupValue: _s.mode,
                    // ignore: deprecated_member_use
                    onChanged: (v) {
                      if (v == null) return;
                      _update(_s.copyWith(mode: v));
                      widget.onModeChanged(v);
                    },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: const Color(0xFF5B7CFA),
                    title: Text(mode.label),
                    subtitle: Text(
                      mode.description,
                      style: const TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                  )),

              const SizedBox(height: 10),
              const _SectionTitle('背景'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                children: ReaderBackground.values.map((bg) {
                  final selected = _s.background == bg;
                  return GestureDetector(
                    onTap: () => _update(_s.copyWith(background: bg)),
                    child: Container(
                      width: 62,
                      height: 40,
                      decoration: BoxDecoration(
                        color: bg.color,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected ? const Color(0xFF5B7CFA) : Colors.white24,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(bg.label, style: TextStyle(color: bg.onColor, fontSize: 12)),
                    ),
                  );
                }).toList(),
              ),

              const _SectionTitle('字号'),
              _SliderRow(
                value: _s.fontSize,
                min: 12,
                max: 34,
                divisions: 22,
                label: _s.fontSize.toStringAsFixed(0),
                onChanged: (v) => _update(_s.copyWith(fontSize: v)),
              ),

              const _SectionTitle('行距'),
              _SliderRow(
                value: _s.lineHeight,
                min: 1.2,
                max: 2.6,
                divisions: 14,
                label: _s.lineHeight.toStringAsFixed(1),
                onChanged: (v) => _update(_s.copyWith(lineHeight: v)),
              ),

              const _SectionTitle('边距'),
              _SliderRow(
                value: _s.margin,
                min: 0,
                max: 48,
                divisions: 24,
                label: _s.margin.toStringAsFixed(0),
                onChanged: (v) => _update(_s.copyWith(margin: v)),
              ),

              const _SectionTitle('点击区域（左右各占屏宽比例）'),
              _SliderRow(
                value: _s.tapZoneLeft,
                min: 0.1,
                max: 0.45,
                divisions: 7,
                label: '${(_s.tapZoneLeft * 100).toStringAsFixed(0)}%',
                onChanged: (v) => _update(
                  _s.copyWith(tapZoneLeft: v, tapZoneRight: v),
                ),
              ),

              const _SectionTitle('阅读亮度'),
              _SliderRow(
                value: _s.screenBrightness,
                min: 0.3,
                max: 1.0,
                divisions: 14,
                label: '${(_s.screenBrightness * 100).toStringAsFixed(0)}%',
                onChanged: (v) => _update(_s.copyWith(screenBrightness: v)),
              ),


              const SizedBox(height: 12),
              const _SectionTitle('章节跳转'),
              const SizedBox(height: 6),
              if (widget.document.chapterCount > 1)
                DropdownButtonFormField<int>(
                  initialValue: widget.controller.progress.chapterIndex
                      .clamp(0, widget.document.chapterCount - 1),
                  dropdownColor: const Color(0xFF2A2A2A),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(

                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: widget.document.chapters
                      .map((c) => DropdownMenuItem(
                            value: c.index,
                            child: Text(
                              '${c.title}  (${c.pageCount}页)',
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    widget.controller.goToChapter(v);
                    Navigator.of(context).maybePop();
                  },
                )
              else
                const Text('本篇只有一章',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),

              const SizedBox(height: 16),
              if (widget.document.warnings.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '导入提示',
                        style: TextStyle(
                            color: Colors.orange,
                            fontWeight: FontWeight.w600,
                            fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      ...widget.document.warnings.map((w) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              w,
                              style: const TextStyle(
                                  color: Colors.orangeAccent, fontSize: 12),
                            ),
                          )),
                    ],
                  ),
                ),

              // 压缩包解压缓存管理（用户要求"允许解压到 app 缓存"）
              if (widget.extraction != null &&
                  widget.bookId != null &&
                  widget.store != null) ...[
                const SizedBox(height: 16),
                _ExtractionCard(
                  manager: widget.extraction!,
                  bookId: widget.bookId!,
                  store: widget.store!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 解压缓存状态与管理入口
class _ExtractionCard extends StatefulWidget {
  const _ExtractionCard({
    required this.manager,
    required this.bookId,
    required this.store,
  });

  final ExtractionManager manager;
  final String bookId;
  final ByteStore store;

  @override
  State<_ExtractionCard> createState() => _ExtractionCardState();
}

class _ExtractionCardState extends State<_ExtractionCard> {
  int _bytes = 0;

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  Future<void> _refreshSize() async {
    final n = await widget.store.extractedSizeOf(widget.bookId);
    if (mounted) setState(() => _bytes = n);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ExtractionSnapshot>(
      stream: widget.manager.snapshots,
      builder: (context, snapshot) {
        final s = snapshot.data;
        final state = s?.bookId == widget.bookId
            ? s!.state
            : widget.manager.stateOf(widget.bookId);

        // 解压完成时刷新一次占用
        if (state == ExtractionState.done && _bytes == 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _refreshSize());
        }

        final (title, subtitle, color) = switch (state) {
          ExtractionState.running => (
              '正在后台解压…',
              '翻页会优先读取已解压的文件，未完成的部分自动回退到压缩包读取',
              Colors.lightBlueAccent,
            ),
          ExtractionState.done => (
              '已解压到缓存',
              '翻页直接读文件，延迟显著降低。占用 ${ByteStore.humanSize(_bytes)}',
              Colors.greenAccent,
            ),
          ExtractionState.skipped => (
              '已跳过解压',
              s?.result?.skippedReason ?? '解压后体积过大，保持按需读取（不影响阅读）',
              Colors.orangeAccent,
            ),
          ExtractionState.failed => (
              '解压失败',
              s?.errorMessage ?? '未知错误；已自动回退到按需读取',
              Colors.redAccent,
            ),
          ExtractionState.idle => (
              '尚未解压',
              '阅读时按需从压缩包解压单个条目',
              Colors.white54,
            ),
        };

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.folder_zip_outlined, size: 18, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                          color: color, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (state == ExtractionState.running)
                    TextButton(
                      onPressed: () => widget.manager.cancel(widget.bookId),
                      child: const Text('停止', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              if (state == ExtractionState.running && s?.progress != null) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: s!.progress!.ratio,
                  minHeight: 3,
                  backgroundColor: Colors.white12,
                ),
                const SizedBox(height: 4),
                Text(
                  '${s.progress!.done}/${s.progress!.total} · '
                  '已写入 ${ByteStore.humanSize(s.progress!.bytesWritten)}',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
              if (_bytes > 0) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                    label: const Text('清除解压缓存',
                        style: TextStyle(fontSize: 12)),
                    onPressed: () async {
                      await widget.manager.clearFor(widget.bookId);
                      await _refreshSize();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已清除解压缓存（不影响阅读，只是回到按需解压）'),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: Text(
          text,
          style: const TextStyle(
              color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
        ),
      );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
