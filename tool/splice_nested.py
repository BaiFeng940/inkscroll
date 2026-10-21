# 用行号做精确替换（前面按文本匹配失败，因为实际换行/缩进与预期不同）
import io

FLDR = r"D:\DSH Desktop\work\flutter-comic-reader\lib\importers\webdav_folder_importer.dart"

NEW = '''    final subs = entries.where((e) => e.isDirectory).take(maxNested).toList()
      ..sort((a, b) => compareByOriginalName(a.name, b.name));

    // ★ 必须并发。
    //
    // 原来是 `for (sub in subs) { await client.list(sub.url) }` —— 每个
    // 子目录都要等一次完整的 PROPFIND 往返。真实目录是
    // 「根目录 / 38 个合集 / 每个合集若干话」，串行下来就是上千次
    // 首尾相接的请求，几十秒到几分钟很正常。这才是"网盘库导入太慢"
    // 的真正来源：不是下载慢，是这种小请求被一根线串起来等。
    //
    // 结果按原始下标放回 slots，导入顺序仍与目录名自然序一致。
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

    final subWorkers =
        math.min(nestedScanConcurrency, math.max(1, subs.length));
    await Future.wait(List.generate(subWorkers, (_) => subWorker()));
    for (final list in slots) {
      if (list != null) out.addAll(list);
    }
    return out;'''

with io.open(FLDR, encoding="utf-8", newline="") as f:
    raw = f.read()
lines = raw.split("\r\n") if "\r\n" in raw else raw.split("\n")
nl = "\r\n" if "\r\n" in raw else "\n"

# 定位：从含 "final subs = entries" 的行，到其后第一个 "return out;"
start = next(i for i, l in enumerate(lines) if "final subs = entries" in l)
end = next(i for i in range(start, len(lines)) if lines[i].strip() == "return out;")

print(f"替换 {start+1}..{end+1}（共 {end-start+1} 行）")
lines[start:end + 1] = NEW.split("\n")

with io.open(FLDR, "w", encoding="utf-8", newline=nl) as f:
    f.write(nl.join(lines))
print("完成")
