# 修复三件事：
#   1) 合集嵌套扫描由串行改并发（网盘库导入慢的根因）
#   2) 连接池上限 6 → 12（扫描并发 5 × 嵌套 4 = 20，池太小会排队）
#   3) 删除设置里的「不在家时怎么连？」入口
import io, re

FLDR = r"D:\DSH Desktop\work\flutter-comic-reader\lib\importers\webdav_folder_importer.dart"
CLIENT = r"D:\DSH Desktop\work\flutter-comic-reader\lib\data\webdav\webdav_client.dart"
SETTINGS = r"D:\DSH Desktop\work\flutter-comic-reader\lib\ui\settings_screen.dart"


def read(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()


def write(p, s):
    with io.open(p, "w", encoding="utf-8", newline="\r\n") as f:
        f.write(s)


# ── 1) 嵌套扫描并发化 ────────────────────────────────────────────────
s = read(FLDR)

OLD = """      final subs = entries.where((e) => e.isDirectory).toList()
        ..sort((a, b) => compareByOriginalName(a.name, b.name));
      for (final sub in subs.take(maxNested)) {
        try {
          final subEntries = await client.list(sub.url);
          final subImages = _collectImages(subEntries, client, sub.url);
          if (subImages.isNotEmpty) {
            out.add(WebDavComicCandidate(
              url: sub.url,
              name: collectionBookName(dirName, sub.name),
              images: subImages,
            ));
            continue;
          }
          final subZips = subEntries
              .where((e) => !e.isDirectory && _isArchiveName(e.name))
              .toList()
            ..sort((a, b) => compareByOriginalName(a.name, b.name));
          for (final a in subZips) {
            out.add(WebDavComicCandidate(
              url: a.url,
              name: collectionBookName(dirName, a.name),
              images: const [],
              isArchive: true,
              archiveSize: a.size,
            ));
          }
        } catch (_) {
          // 单个子目录失败不影响其他
        }
      }
      return out;"""

NEW = """      final subs = entries.where((e) => e.isDirectory).take(maxNested).toList()
        ..sort((a, b) => compareByOriginalName(a.name, b.name));

      // ★ 必须并发。
      //
      // 原来是 `for (sub in subs) { await client.list(sub.url) }` —— 每个
      // 子目录都要等一次完整的 PROPFIND 往返。用户的实际目录是
      // 「根目录 / 38 个合集 / 每个合集若干话」，串行下来就是上千次
      // 首尾相接的请求，几十秒到几分钟都正常。这就是"网盘库导入太慢"
      // 的真正来源（不是下载慢，是这种小请求被串起来等）。
      //
      // 结果按原始下标放回 slots，保证导入顺序仍与目录名自然序一致。
      final slots = List<List<WebDavComicCandidate>?>.filled(subs.length, null);
      var nextSub = 0;

      Future<void> subWorker() async {
        while (true) {
          final i = nextSub++;
          if (i >= subs.length) return;
          final sub = subs[i];
          final list = <WebDavComicCandidate>[];
          try {
            final subEntries = await client.list(sub.url);
            final subImages = _collectImages(subEntries, client, sub.url);
            if (subImages.isNotEmpty) {
              list.add(WebDavComicCandidate(
                url: sub.url,
                name: collectionBookName(dirName, sub.name),
                images: subImages,
              ));
            } else {
              final subZips = subEntries
                  .where((e) => !e.isDirectory && _isArchiveName(e.name))
                  .toList()
                ..sort((a, b) => compareByOriginalName(a.name, b.name));
              for (final a in subZips) {
                list.add(WebDavComicCandidate(
                  url: a.url,
                  name: collectionBookName(dirName, a.name),
                  images: const [],
                  isArchive: true,
                  archiveSize: a.size,
                ));
              }
            }
          } catch (_) {
            // 单个子目录失败不影响其他
          }
          slots[i] = list;
        }
      }

      final subWorkers = math.min(nestedScanConcurrency, math.max(1, subs.length));
      await Future.wait(List.generate(subWorkers, (_) => subWorker()));
      for (final list in slots) {
        if (list != null) out.addAll(list);
      }
      return out;"""

if OLD in s:
    s = s.replace(OLD, NEW)
    print("嵌套扫描已改并发")
else:
    print("警告：嵌套扫描锚点未命中")

# 常量
if "nestedScanConcurrency" not in s:
    anchor = "  static const int maxNested = 40;"
    if anchor in s:
        s = s.replace(
            anchor,
            anchor + "\n\n  /// 合集内部的并发扫描路数。\n"
                    "  ///\n"
                    "  /// 一个合集下常常有几十话，串行 PROPFIND 会把首尾相接的\n"
                    "  /// 往返延迟直接累加；这里并发 4，配合连接池 12 刚好不排队。\n"
                    "  static const int nestedScanConcurrency = 4;",
            1,
        )
        print("已加 nestedScanConcurrency")

write(FLDR, s)

# ── 2) 连接池 6 → 12 ────────────────────────────────────────────────
c = read(CLIENT)
if "maxConnectionsPerHost = 6;" in c:
    c = c.replace("maxConnectionsPerHost = 6;", "maxConnectionsPerHost = 12;")
    print("连接池 6 → 12")
write(CLIENT, c)

# ── 3) 删除「不在家时怎么连？」入口 ─────────────────────────────────
t = read(SETTINGS)
before = t
# 该 ListTile 是 OutlinedButton.icon 形式，找它的 start..end
m = re.search(
    r"\n *OutlinedButton\.icon\(\n(?:.*\n)*?.*?'不在家时怎么连？（远程访问）'\);\n",
    t,
)
if m:
    # 向后删到该 widget 结束（找到 "              ),\n" 收尾）
    start = m.start()
    rest = t[m.end():]
    # 找到第一个空行 + Divider 或下一个区块的边界
    end_marker = rest.find("\n          const Divider(height: 24),")
    if end_marker != -1:
        t = t[:start] + rest[end_marker:]
        print("已删除「不在家时怎么连？」")
    else:
        print("警告：找不到删除边界")
else:
    print("警告：找不到「不在家时怎么连？」")

if t != before:
    write(SETTINGS, t)
