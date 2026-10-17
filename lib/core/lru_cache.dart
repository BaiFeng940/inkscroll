/// 简单的 LRU 缓存，同时按"条目数"和"字节数"双重限额。
///
/// 阅读器要同时限制张数与字节数：一张 Webtoon 长条可能比 100 张普通页还大。
library;


class LruCache<K, V> {
  LruCache({required this.maxEntries, required this.maxBytes, this.sizeOf});

  final int maxEntries;
  final int maxBytes;

  /// 如何计算一个 value 的字节数；为 null 时按 1 计（只限条目数）
  final int Function(V value)? sizeOf;

  final _map = <K, V>{};
  int _bytes = 0;

  int get length => _map.length;
  int get bytes => _bytes;

  V? get(K key) {
    final v = _map.remove(key);
    if (v == null) return null;
    _map[key] = v; // 移到最后 = 最近使用
    return v;
  }

  bool containsKey(K key) => _map.containsKey(key);

  void put(K key, V value) {
    final old = _map.remove(key);
    if (old != null) _bytes -= _size(old);
    _map[key] = value;
    _bytes += _size(value);
    _evict();
  }

  void remove(K key) {
    final old = _map.remove(key);
    if (old != null) _bytes -= _size(old);
  }

  void clear() {
    _map.clear();
    _bytes = 0;
  }

  void _evict() {
    while (_map.isNotEmpty && (_map.length > maxEntries || _bytes > maxBytes)) {
      final oldestKey = _map.keys.first;
      final v = _map.remove(oldestKey);
      if (v != null) _bytes -= _size(v);
    }
  }

  int _size(V v) => sizeOf?.call(v) ?? 1;
}
