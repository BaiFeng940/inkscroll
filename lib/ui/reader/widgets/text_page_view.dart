/// 纯文本页渲染（TXT / 未来的 DOCX）。
///
/// 排版参数全部来自 [ReaderSettings]：字号、行距、边距。
/// 背景色跟随阅读器设置（白/羊皮纸/灰/黑），文字颜色取对比色。
library;

import 'package:flutter/material.dart';

import '../../../data/models/reader_settings.dart';
import '../../../reader/document.dart';

class TextPageView extends StatelessWidget {
  const TextPageView({
    super.key,
    required this.page,
    required this.settings,
  });

  final PageNode page;
  final ReaderSettings settings;

  @override
  Widget build(BuildContext context) {
    final content = page.content;
    if (content is! TextPageContent) {
      return const SizedBox.shrink();
    }

    final isHeading = content.headingLevel != null && content.headingLevel! <= 2;
    final color = settings.background.onColor;

    return Container(
      color: settings.background.color,
      padding: EdgeInsets.symmetric(
        horizontal: settings.margin,
        vertical: settings.margin * 0.75,
      ),
      // 文本页可能比一屏高（长段落），允许内部滚动，
      // 避免内容被截断（长图模式尤其明显）
      child: SingleChildScrollView(
        // 内部的滚动与外层长页滚动会冲突，所以文本页在长图模式下
        // 依赖 PageMetrics 给出的高度足够容纳内容
        physics: const ClampingScrollPhysics(),
        child: Text(
          content.text,
          style: TextStyle(
            color: color,
            fontSize: isHeading
                ? settings.fontSize * 1.35
                : settings.fontSize,
            fontWeight: isHeading ? FontWeight.w700 : FontWeight.w400,
            height: settings.lineHeight,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
