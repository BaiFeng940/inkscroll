/// 阅读设置与阅读进度模型。
library;

import 'package:flutter/material.dart';

/// 两种阅读模式
///
/// ## 为什么"左右滑动"和"左右点击"合并成了一个
///
/// 之前把它们拆成两个模式（`horizontalSlide` / `horizontalTap`），
/// 但翻页模式本来就是**同一个 `PageView` + 同一套手势**：
/// 水平拖动翻页和点击两侧翻页**同时可用**才是符合直觉的行为 ——
/// 用户不该被迫在"我只能滑"和"我只能点"之间二选一。
///
/// 合并后 `horizontal` 同时支持：
///   - 水平拖动 / 惯性滑动翻页（`PageScrollPhysics`）
///   - 点击左侧 → 上一页，点击右侧 → 下一页
///   - 点击中间 → 呼出菜单
///   - 双击 → 缩放，缩放后可平移
enum ReadingMode {
  /// ① 左右翻页（拖动与点击两种方式同时可用）
  horizontal,

  /// ② 上下滑动翻页 —— 纵向虚拟长页（Webtoon 模式）
  verticalContinuous,
}

extension ReadingModeX on ReadingMode {
  String get label => switch (this) {
        ReadingMode.horizontal => '左右翻页',
        ReadingMode.verticalContinuous => '上下滑动',
      };

  String get description => switch (this) {
        ReadingMode.horizontal =>
          '左右拖动或点击屏幕两侧翻页，点击中间呼出菜单（一页一屏）',
        ReadingMode.verticalContinuous => '纵向连续滚动，多页无缝拼接成一条长页（Webtoon）',
      };

  IconData get icon => switch (this) {
        ReadingMode.horizontal => Icons.swap_horiz,
        ReadingMode.verticalContinuous => Icons.swap_vert,
      };

  bool get isVertical => this == ReadingMode.verticalContinuous;
}

/// 背景主题
enum ReaderBackground { white, sepia, gray, black }

extension ReaderBackgroundX on ReaderBackground {
  Color get color => switch (this) {
        ReaderBackground.white => const Color(0xFFFFFFFF),
        ReaderBackground.sepia => const Color(0xFFF3E9D2),
        ReaderBackground.gray => const Color(0xFF4A4A4A),
        ReaderBackground.black => const Color(0xFF000000),
      };

  String get label => switch (this) {
        ReaderBackground.white => '白色',
        ReaderBackground.sepia => '羊皮纸',
        ReaderBackground.gray => '灰色',
        ReaderBackground.black => '黑色',
      };

  Color get onColor => switch (this) {
        ReaderBackground.white || ReaderBackground.sepia => Colors.black87,
        ReaderBackground.gray || ReaderBackground.black => Colors.white70,
      };

  bool get isDark => this == ReaderBackground.gray || this == ReaderBackground.black;
}

class ReaderSettings {
  const ReaderSettings({
    this.mode = ReadingMode.verticalContinuous,
    this.background = ReaderBackground.black,
    this.fontSize = 18.0,
    this.lineHeight = 1.7,
    this.margin = 16.0,
    this.tapZoneLeft = 0.25,
    this.tapZoneRight = 0.25,
    this.screenBrightness = 1.0,
    this.keepScreenOn = true,
    this.themeMode = ThemeMode.system,
    this.lastModePerBook = const {},
  });

  final ReadingMode mode;
  final ReaderBackground background;
  final double fontSize;
  final double lineHeight;
  final double margin;

  /// 点击区域宽度占总宽的比例（模式 ②）
  final double tapZoneLeft;
  final double tapZoneRight;

  /// 0.5 ~ 1.0 的阅读亮度覆盖（不修改系统亮度）
  final double screenBrightness;
  final bool keepScreenOn;

  final ThemeMode themeMode;

  /// 每本书最后使用的模式：bookId -> mode
  final Map<String, ReadingMode> lastModePerBook;

  ReaderSettings copyWith({
    ReadingMode? mode,
    ReaderBackground? background,
    double? fontSize,
    double? lineHeight,
    double? margin,
    double? tapZoneLeft,
    double? tapZoneRight,
    double? screenBrightness,
    bool? keepScreenOn,
    ThemeMode? themeMode,
    Map<String, ReadingMode>? lastModePerBook,
  }) {
    return ReaderSettings(
      mode: mode ?? this.mode,
      background: background ?? this.background,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      margin: margin ?? this.margin,
      tapZoneLeft: tapZoneLeft ?? this.tapZoneLeft,
      tapZoneRight: tapZoneRight ?? this.tapZoneRight,
      screenBrightness: screenBrightness ?? this.screenBrightness,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      themeMode: themeMode ?? this.themeMode,
      lastModePerBook: lastModePerBook ?? this.lastModePerBook,
    );
  }

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'background': background.name,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'margin': margin,
        'tapZoneLeft': tapZoneLeft,
        'tapZoneRight': tapZoneRight,
        'screenBrightness': screenBrightness,
        'keepScreenOn': keepScreenOn,
        'themeMode': themeMode.name,
        'lastModePerBook':
            lastModePerBook.map((k, v) => MapEntry(k, v.name)),
      };

  static ReaderSettings fromJson(Map<String, dynamic> json) {
    return ReaderSettings(
      mode: _modeFromName(json['mode']),
      background: _enumByName(
          ReaderBackground.values, json['background'], ReaderBackground.black),
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18.0,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.7,
      margin: (json['margin'] as num?)?.toDouble() ?? 16.0,
      tapZoneLeft: (json['tapZoneLeft'] as num?)?.toDouble() ?? 0.25,
      tapZoneRight: (json['tapZoneRight'] as num?)?.toDouble() ?? 0.25,
      screenBrightness: (json['screenBrightness'] as num?)?.toDouble() ?? 1.0,
      keepScreenOn: json['keepScreenOn'] as bool? ?? true,
      themeMode: _enumByName(ThemeMode.values, json['themeMode'], ThemeMode.system),
      lastModePerBook: ((json['lastModePerBook'] as Map?) ?? const {})
          .map((k, v) => MapEntry(k as String, _modeFromName(v))),
    );
  }

  /// 解析阅读模式，**兼容合并前的旧值**。
  ///
  /// 0.1.0 之前存的是 `horizontalSlide` / `horizontalTap` 两个名字，
  /// 现在合并成了 `horizontal`。老用户升级后如果直接按 name 匹配会失败、
  /// 掉回默认的"上下滑动"，把用户原本的偏好弄丢 —— 所以这里显式映射。
  static ReadingMode _modeFromName(Object? name) {
    if (name is String) {
      switch (name) {
        case 'horizontal':
        case 'horizontalSlide': // 旧：左右滑动
        case 'horizontalTap': // 旧：左右点击
          return ReadingMode.horizontal;
        case 'verticalContinuous':
          return ReadingMode.verticalContinuous;
      }
    }
    return ReadingMode.verticalContinuous;
  }

  ThemeData themeData({required Brightness brightness}) {
    const seed = Color(0xFF5B7CFA);
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
    );
  }

  static T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
    if (name is! String) return fallback;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }
}

/// 顶层工具：按 name 找枚举值
T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is! String) return fallback;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

// ---------------------------------------------------------------------------

/// 阅读进度。
///
/// 同时保存"页 + 页内比例"和"归一化百分比"：
///   - 页模式用 pageIndex
///   - 长图模式用 pixelOffset + ratioInPage
///   - ratio 用于进度条显示与跨模式换算
///
/// ★ 按模式分别记忆：用户可能在左右翻页读到第 50 页，
///   切到长图模式时不应该丢失原模式的精确位置。
class ReadingProgress {
  const ReadingProgress({
    this.pageIndex = 0,
    this.pixelOffset = 0,
    this.ratioInPage = 0,
    this.ratio = 0,
    this.mode = ReadingMode.verticalContinuous,
    this.chapterIndex = 0,
    this.charOffset,
    this.zoom = 1.0,
    this.updatedAt,
  });

  final int pageIndex;
  final double pixelOffset;
  final double ratioInPage;
  final double ratio;
  final ReadingMode mode;
  final int chapterIndex;

  /// TXT 改字号后用它做锚点（字符偏移），比页号稳定得多
  final int? charOffset;

  final double zoom;
  final DateTime? updatedAt;

  bool get isEmpty => pageIndex == 0 && pixelOffset == 0 && ratio == 0;

  ReadingProgress copyWith({
    int? pageIndex,
    double? pixelOffset,
    double? ratioInPage,
    double? ratio,
    ReadingMode? mode,
    int? chapterIndex,
    int? charOffset,
    double? zoom,
    DateTime? updatedAt,
  }) {
    return ReadingProgress(
      pageIndex: pageIndex ?? this.pageIndex,
      pixelOffset: pixelOffset ?? this.pixelOffset,
      ratioInPage: ratioInPage ?? this.ratioInPage,
      ratio: ratio ?? this.ratio,
      mode: mode ?? this.mode,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      charOffset: charOffset ?? this.charOffset,
      zoom: zoom ?? this.zoom,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'pageIndex': pageIndex,
        'pixelOffset': pixelOffset,
        'ratioInPage': ratioInPage,
        'ratio': ratio,
        'mode': mode.name,
        'chapterIndex': chapterIndex,
        'charOffset': charOffset,
        'zoom': zoom,
        'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
      };

  static ReadingProgress fromJson(Map<String, dynamic> json) => ReadingProgress(
        pageIndex: json['pageIndex'] as int? ?? 0,
        pixelOffset: (json['pixelOffset'] as num?)?.toDouble() ?? 0,
        ratioInPage: (json['ratioInPage'] as num?)?.toDouble() ?? 0,
        ratio: (json['ratio'] as num?)?.toDouble() ?? 0,
        mode: enumByName(
            ReadingMode.values, json['mode'], ReadingMode.verticalContinuous),
        chapterIndex: json['chapterIndex'] as int? ?? 0,
        charOffset: json['charOffset'] as int?,
        zoom: (json['zoom'] as num?)?.toDouble() ?? 1.0,
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      );
}
