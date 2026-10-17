/// 轻量持久化：书架元数据 / 阅读进度 / 设置。
///
/// 起步用 SharedPreferences + JSON，零迁移成本、零原生依赖。
/// 书籍数量到几百本、或需要复杂查询（分类树、全文搜索）时，
/// 迁移路径是 drift/sqlite，只需替换本文件的实现，UI 与阅读器不受影响。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/book_meta.dart';
import '../data/models/reader_settings.dart';

class PrefsStore {
  PrefsStore._(this._prefs);

  final SharedPreferences _prefs;

  static const _kBooks = 'books.v1';
  static const _kSettings = 'settings.v1';

  /// 进度键：progress.{bookId}.{modeName}
  static String _progressKey(String bookId, ReadingMode mode) =>
      'progress.$bookId.${mode.name}';

  static Future<PrefsStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return PrefsStore._(prefs);
  }

  // ------------------------------------------------------------------
  // 书架
  // ------------------------------------------------------------------
  List<BookMeta> loadBooks() {
    final raw = _prefs.getString(_kBooks);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => BookMeta.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      // 数据损坏时不要卡死 App：返回空书架，用户可以重新导入
      return [];
    }
  }

  Future<void> saveBooks(List<BookMeta> books) async {
    final json = jsonEncode(books.map((b) => b.toJson()).toList());
    await _prefs.setString(_kBooks, json);
  }

  Future<void> upsertBook(BookMeta book) async {
    final books = loadBooks();
    final i = books.indexWhere((b) => b.id == book.id);
    if (i >= 0) {
      books[i] = book;
    } else {
      books.insert(0, book);
    }
    await saveBooks(books);
  }

  Future<void> deleteBook(String bookId) async {
    final books = loadBooks()..removeWhere((b) => b.id == bookId);
    await saveBooks(books);
    // 清掉这本书的全部模式进度
    for (final m in ReadingMode.values) {
      await _prefs.remove(_progressKey(bookId, m));
    }
  }

  Future<void> renameBook(String bookId, String newTitle) async {
    final books = loadBooks();
    final i = books.indexWhere((b) => b.id == bookId);
    if (i >= 0) {
      books[i].title = newTitle;
      await saveBooks(books);
    }
  }

  Future<void> toggleFavorite(String bookId) async {
    final books = loadBooks();
    final i = books.indexWhere((b) => b.id == bookId);
    if (i >= 0) {
      books[i].isFavorite = !books[i].isFavorite;
      await saveBooks(books);
    }
  }

  Future<void> touchBook(String bookId) async {
    final books = loadBooks();
    final i = books.indexWhere((b) => b.id == bookId);
    if (i >= 0) {
      books[i].lastReadAt = DateTime.now();
      await saveBooks(books);
    }
  }

  Future<void> setCover(String bookId, String coverPath) async {
    final books = loadBooks();
    final i = books.indexWhere((b) => b.id == bookId);
    if (i >= 0) {
      books[i].coverPath = coverPath;
      await saveBooks(books);
    }
  }

  // ------------------------------------------------------------------
  // 阅读进度（按模式分开存）
  // ------------------------------------------------------------------
  ReadingProgress loadProgress(String bookId, ReadingMode mode) {
    final raw = _prefs.getString(_progressKey(bookId, mode));
    if (raw == null || raw.isEmpty) {
      return ReadingProgress(mode: mode);
    }
    try {
      return ReadingProgress.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      return ReadingProgress(mode: mode);
    }
  }

  Future<void> saveProgress(String bookId, ReadingProgress progress) async {
    await _prefs.setString(
      _progressKey(bookId, progress.mode),
      jsonEncode(progress.toJson()),
    );
  }

  /// 一次性读出所有模式的进度，用于打开书时决定恢复哪一条
  Future<Map<ReadingMode, ReadingProgress>> loadAllProgress(String bookId) async {
    final out = <ReadingMode, ReadingProgress>{};
    for (final m in ReadingMode.values) {
      final raw = _prefs.getString(_progressKey(bookId, m));
      if (raw == null || raw.isEmpty) continue;
      try {
        out[m] = ReadingProgress.fromJson(
            (jsonDecode(raw) as Map).cast<String, dynamic>());
      } catch (_) {
        // 单条损坏不影响其他模式
      }
    }
    return out;
  }

  Future<void> saveAllProgress(
    String bookId,
    Map<ReadingMode, ReadingProgress> all,
  ) async {
    for (final entry in all.entries) {
      await _prefs.setString(
        _progressKey(bookId, entry.key),
        jsonEncode(entry.value.copyWith(mode: entry.key).toJson()),
      );
    }
  }

  // ------------------------------------------------------------------
  // 设置
  // ------------------------------------------------------------------
  ReaderSettings loadSettings() {
    final raw = _prefs.getString(_kSettings);
    if (raw == null || raw.isEmpty) return const ReaderSettings();
    try {
      return ReaderSettings.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      return const ReaderSettings();
    }
  }

  Future<void> saveSettings(ReaderSettings settings) async {
    await _prefs.setString(_kSettings, jsonEncode(settings.toJson()));
  }
}
