# 合集命名：把「XX合集/第一话」→「XX 第一话」
import io, re

PATH = r"D:\DSH Desktop\work\flutter-comic-reader\lib\importers\webdav_folder_importer.dart"
with io.open(PATH, encoding="utf-8") as f:
    s = f.read()

# 1) 子目录候选：name: sub.name -> collectionBookName(dirName, sub.name)
before = s
s = s.replace(
    "            url: sub.url,\n            name: sub.name,",
    "            url: sub.url,\n            name: collectionBookName(dirName, sub.name),",
)
print("子目录候选改名:", s != before)

# 2) 子目录里的压缩包：name: a.name（第二次出现的位置）
before = s
s = s.replace(
    "            name: a.name,\n            images: const [],\n            isArchive: true,",
    "            name: collectionBookName(dirName, a.name),\n            images: const [],\n            isArchive: true,",
)
print("压缩包候选改名:", s != before)

HELPER = '''  /// 合集里的一本书该叫什么名字。
  ///
  /// 现实命名：`漫画根目录/XX合集/第一话/`。只取「第一话」的话，库里有
  /// 几十本「第一话」「第二话」，完全分不清谁是谁。规则：
  ///   1. 合集名去掉「合集」二字（它只是分类标记，不是书名的一部分）；
  ///   2. 拼成 `合集名 子名`；
  ///   3. 子名如果已经以合集名开头（重复部分），不重复拼接；
  ///   4. 压缩包去掉扩展名。
  ///
  /// 例：`XX合集` + `第一话` → `XX 第一话`
  static String collectionBookName(String collection, String sub) {
    final c = collection.replaceAll('合集', '').trim();
    if (c.isEmpty) return _stripArchiveExt(sub);
    final s = _stripArchiveExt(sub);
    if (s.startsWith(c)) return s;
    return '$c $s';
  }

  static String _stripArchiveExt(String name) {
    var s = name.trim();
    for (final ext in const ['.zip', '.cbz', '.tar']) {
      if (s.toLowerCase().endsWith(ext)) {
        return s.substring(0, s.length - ext.length);
      }
    }
    return s;
  }

'''

anchor = "  /// 扫描一个直接子目录，返回它内部的书（可能是 1 本、多本、或 0 本）。"
if "collectionBookName(String" not in s and anchor in s:
    s = s.replace(anchor, HELPER + anchor, 1)
    print("已插入 collectionBookName")

with io.open(PATH, "w", encoding="utf-8", newline="\r\n") as f:
    f.write(s)
print("完成")
