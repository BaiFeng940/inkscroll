import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/prefs_store.dart';
import 'state/app_state.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ★ 收紧 Flutter 默认图片缓存。
  // 默认是 100 张 / 100MB，对 Webtoon 长条来说太宽松：
  // 一张 1080x20000 的长图就能吃掉几百 MB。
  // ★ 调整 Flutter 的**解码后位图**缓存。
  //
  //   默认 100 张 / 100MB 对 Webtoon 长条太宽松（一张 1080×20000 能吃掉几百 MB），
  //   但调得太紧又会让"往回滑一页"重新解码。
  //
  //   由于我们已经用 `ResizeImage` 把每页解码宽度限制到屏幕物理宽
  //   （1080p 屏上一页约 6MB），这里给 40 张 / 128MB 比较平衡：
  //   足以覆盖前后几屏的预取，又不会把内存顶爆。
  //   120Hz 高刷下这一项尤其关键 —— 每帧重新解码是不可能跑到 120fps 的。
  PaintingBinding.instance.imageCache.maximumSize = 40; // 张数
  PaintingBinding.instance.imageCache.maximumSizeBytes = 128 << 20; // 128MB

  final prefs = await PrefsStore.open();

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(prefs)..bootstrap(),
      child: const BookReaderApp(),
    ),
  );
}

class BookReaderApp extends StatelessWidget {
  const BookReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.select((AppState s) => s.settings);
    return MaterialApp(
      title: 'inkScroll',
      debugShowCheckedModeBanner: false,
      theme: settings.themeData(brightness: Brightness.light),
      darkTheme: settings.themeData(brightness: Brightness.dark),
      themeMode: settings.themeMode,
      home: const HomeScreen(),
    );
  }
}
