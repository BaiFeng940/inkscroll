/// 自然排序：漫画文件名是重灾区。
///
/// 覆盖场景：
///   '1.jpg'   < '2.jpg'   < '10.jpg'      数字按数值比，不是字典序
///   '第1话'   < '第10话'
///   'a2b10'   < 'a10b2'
///   '1'       < '01'                       数值相同，前导零少的优先
library;

import 'dart:math' as math;

class NaturalComparator {
  /// 比较两个字符串。数字段按数值大小比较。
  ///
  /// 注意：刻意不把数字转成 int。漫画文件名里可能出现
  /// '99999999999999999999.jpg'，转 int 会溢出。
  static int compare(String a, String b) {
    int i = 0;
    int j = 0;
    while (i < a.length && j < b.length) {
      final ca = a.codeUnitAt(i);
      final cb = b.codeUnitAt(j);
      final da = _isDigit(ca);
      final db = _isDigit(cb);

      if (da && db) {
        final si = i;
        final sj = j;
        while (i < a.length && _isDigit(a.codeUnitAt(i))) {
          i++;
        }
        while (j < b.length && _isDigit(b.codeUnitAt(j))) {
          j++;
        }
        final na = a.substring(si, i);
        final nb = b.substring(sj, j);

        // 去掉前导零后，先比长度再比字典序 —— 等价的数值比较，且不会溢出
        final ta = _stripLeadingZeros(na);
        final tb = _stripLeadingZeros(nb);
        if (ta.length != tb.length) return ta.length - tb.length;
        final c = ta.compareTo(tb);
        if (c != 0) return c;
        // 数值完全相同：前导零少的排前面（'1' < '01'）
        if (na.length != nb.length) return na.length - nb.length;
      } else {
        final c = ca.compareTo(cb);
        if (c != 0) return c;
        i++;
        j++;
      }
    }
    return (a.length - i) - (b.length - j);
  }

  /// ★ 逐段比较路径。
  ///
  /// 直接比较整条路径是错的：
  ///   '第1话/10.jpg' vs '第10话/1.jpg'
  ///   整串比较会在 '第1' 之后比较 '0' 和 '话'，得到错误顺序。
  /// 正确做法是按 '/' 切分，逐段用自然排序比较。
  static int comparePath(String a, String b) {
    final pa = a.split('/');
    final pb = b.split('/');
    final n = math.min(pa.length, pb.length);
    for (int k = 0; k < n; k++) {
      // 最后一段通常是文件名，其余是目录段，两者用同一套规则即可
      final c = compare(pa[k], pb[k]);
      if (c != 0) return c;
    }
    return pa.length - pb.length;
  }

  static int Function(String, String) get instance => compare;

  static String _stripLeadingZeros(String s) {
    int k = 0;
    while (k < s.length - 1 && s.codeUnitAt(k) == 0x30) {
      k++;
    }
    return s.substring(k);
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
}
