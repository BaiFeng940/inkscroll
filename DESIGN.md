# Flutter 漫画 / 文档阅读器 —— 完整设计与实现方案

> 面向 Android 为主、兼容 iOS。
> 三条硬约束贯穿全文：
> 1. **不解压整个压缩包** —— 只读中央目录，按需解出单个条目。
> 2. **不合成超大 Bitmap** —— 虚拟长页 + 可见窗口渲染，逐页独立解码。
> 3. **不一次性加载所有图片** —— 预取窗口 + LRU 淘汰 + 失败重试。
>
> 配套代码见同仓库 `lib/`，第一章"起步实现"给出了可运行的最小闭环。

---

# 目录

- [第 1 部分：整体架构、模块划分、数据模型、技术选型](#第-1-部分整体架构模块划分数据模型技术选型)
- [第 2 部分：导入流程 —— 从原始来源到统一模型](#第-2-部分导入流程--从原始来源到统一模型)
- [第 3 部分：三种阅读模式的实现方案](#第-3-部分三种阅读模式的实现方案)
- [第 4 部分：关键代码片段](#第-4-部分关键代码片段)
- [第 5 部分：难点、优化、第三方库、合规风险](#第-5-部分难点优化第三方库合规风险)
- [第 6 部分：起步实现（本仓库已落地的代码）](#第-6-部分起步实现本仓库已落地的代码)

---

# 第 1 部分：整体架构、模块划分、数据模型、技术选型

## 1.1 设计主线（三条约束反推出的架构）

| 约束 | 架构后果 |
|---|---|
| 不解压整个压缩包 | 必须有**随机访问字节层**（`RandomAccessByteSource`）；模型只能存"引用"不能存"字节"；内容加载必须异步、可取消 |
| 不合成超大 Bitmap | 必须有**虚拟长页 + 逐页独立解码**；页面模型是"虚拟坐标系统"而不是"一个 Widget 一个图" |
| 不一次性加载所有图片 | 必须有**可见窗口 + 预取窗口 + LRU 淘汰**；内容按需加载要走统一注册表 |

一句话：**统一内容抽象层 + 三种 Reading Layout + 独立手势仲裁层。**

## 1.2 分层架构

```
┌─────────────────────────────────────────────────────────────┐
│  UI 层 (presentation)                                        │
│  HomeScreen(书架) / ReaderScreen / SettingsSheet             │
│  ReadingLayout(3种) · GestureArbiter · ProgressBar           │
└───────────────▲──────────────────────────────┬──────────────┘
                │ watch(provider)              │ 只依赖抽象
┌───────────────┴──────────────────────────────▼──────────────┐
│  Domain 层 (纯 Dart，无 Flutter 依赖，可单测)                 │
│  Document / Chapter / PageNode / ContentRef                  │
│  ReaderController · ReadingProgress · PageMetrics            │
└───────────────▲──────────────────────────────┬──────────────┘
                │                              │
┌───────────────┴──────────────┐  ┌────────────▼──────────────┐
│  Import / Parse 层            │  │  Infrastructure 层         │
│  ImportRouter (格式路由)      │  │  RandomAccessByteSource    │
│  FolderImporter               │  │  ArchiveSource (ZIP/RAR/7z)│
│  ArchiveImporter              │  │  EntryCache (LRU)          │
│  TxtImporter                  │  │  PageImageCache (LRU)      │
│  DocxImporter / PdfImporter   │  │  ByteStore (落盘)          │
│  WebImporter                  │  │  PrefsStore (设置/进度)    │
│  NetDiskProvider (抽象)       │  │  PlatformBridge (原生通道) │
└──────────────────────────────┘  └───────────────────────────┘
```

**关键点：Domain 层不认识 Flutter。** 保证"统一文档模型"可单测，也保证解析器可插件化。

## 1.3 目录结构

```
lib/
├── main.dart
├── app/                      应用外壳：主题、暗色模式、路由
├── core/                     无业务基础设施
│   ├── magic.dart            魔术字节识别
│   ├── image_header.dart     图片尺寸嗅探（不解码像素）
│   ├── natural_sort.dart     自然排序
│   ├── lru_cache.dart        LRU
│   ├── charset.dart          编码探测
│   ├── errors.dart           统一错误 + UI 动作映射
│   └── logger.dart
├── data/
│   ├── models/               BookMeta / BookSource / ReadingProgress / ReaderSettings
│   ├── byte_source.dart      RandomAccessByteSource 及实现
│   ├── archive/              压缩包层
│   │   ├── archive_source.dart      抽象 + 条目模型 + 条目缓存
│   │   ├── zip_archive_source.dart  ★ 自研中央目录 + 按需 DEFLATE
│   │   ├── native_archive_source.dart  rar/7z 原生桥占位
│   │   └── archive_factory.dart
│   ├── importer.dart         Importer 抽象 + ImportOutcome
│   ├── byte_store.dart       导入内容落盘（zip/文件夹）
│   └── prefs_store.dart      SharedPreferences 持久化
├── importers/
│   ├── import_router.dart    探测 → 分派
│   ├── folder_importer.dart  ★ 已实现
│   ├── archive_importer.dart ★ 已实现（zip/tar/gz；rar/7z 待接）
│   ├── txt_importer.dart     ★ 已实现（分章 + 分页）
│   ├── image_importer.dart   ★ 已实现（散图）
│   ├── pdf_importer.dart     骨架 + 接入指引
│   ├── docx_importer.dart    骨架 + 接入指引
│   ├── web_importer.dart     骨架 + 接入指引
│   └── netdisk/              NetDiskProvider 抽象 + 注册表
├── reader/
│   ├── document.dart         ★ 统一文档模型
│   ├── page_metrics.dart     ★ 虚拟长页度量（总高/偏移⇄百分比）
│   ├── reader_controller.dart★ 状态机 + 进度 + 跳转 + 模式换算
│   └── page_cache.dart       页字节 LRU
└── ui/
    ├── home_screen.dart      书架 / 最近 / 收藏 / 搜索
    ├── reader/
    │   ├── reader_screen.dart
    │   ├── horizontal_reader.dart  模式 1 / 2
    │   ├── vertical_reader.dart    ★ 模式 3 虚拟长页
    │   ├── gesture_arbiter.dart    ★ 手势仲裁
    │   └── widgets/                PageImage / ProgressBar / Menu
    └── settings_sheet.dart
```

## 1.4 状态管理选型：**Provider（`provider` + `ChangeNotifier`）**

需求原文允许三选一并说明理由。**本仓库选择 Provider**，理由是"最容易实现且够用"：

| 维度 | Provider | Riverpod | Bloc |
|---|---|---|---|
| 上手成本 | ★ 最低，无代码生成 | 中（`family/autoDispose` 概念） | 高（事件/状态类样板） |
| 学习曲线 / 样板量 | 低 | 中 | 高 |
| 异步态表达 | `ChangeNotifier` + `ValueNotifier<AsyncValue>` 手写 | 原生 `AsyncNotifier` | 手写三态类 |
| 生命周期 | `ChangeNotifierProvider` + `dispose()` 手动管理 | 自动 `autoDispose` | 手动 `close` |
| 阅读器适配度 | 足够（阅读状态本就是"一个可变的控制器"） | 最佳 | 偏重 |

**结论**：
- 阅读器状态天然是一个"长生命周期、频繁小幅变更"的控制器 → `ChangeNotifier` 是**最贴合**的模型，`notifyListeners()` 驱动进度条刷新即可。
- 书架/设置是全局单例 → `Provider` 直接提供。
- 真正需要谨慎的是**释放**：Provider 不会自动释放，所以 `ReaderController` 必须在 `ReaderScreen.dispose()` 中显式 `dispose()` 并清空页缓存 —— 本仓库代码已按此处理。

> 如果项目要长大（多书并行、复杂异步图谱），迁移路径清晰：把 `ChangeNotifier` 换成 `Riverpod` 的 `Notifier`，`Provider` 换成 `ProviderScope`，UI 改动很小。**先用最简单的跑通，是更优的工程决策。**

---

## 1.5 统一文档模型

这是整个项目的"汇率表"：**所有格式先翻译成这套模型，阅读器只认这套模型。**

```dart
// 内容类型
sealed class PageContent {}
final class ImageRefContent extends PageContent {   // 位图：漫画页/DOCX 内嵌图/网页插图
  final ContentRef ref;        // ★ 只存"引用"，不存字节
  final int? intrinsicWidth, intrinsicHeight;
  final String? mimeType;
}
final class TextContent extends PageContent {
  final String text;
  final int? headingLevel;
}
final class PdfPageContent extends PageContent {
  final ContentRef ref; final int pageIndex;
  final double widthPt, heightPt;
}

// 内容引用
sealed class ContentRef {}
final class LooseFileRef extends ContentRef { final String path; }             // 外部文件
final class ArchiveEntryRef extends ContentRef {                               // 压缩包内条目
  final String archivePath;    // 压缩包在磁盘上的位置（app 私有目录内）
  final String entryPath;      // 包内路径
  final int uncompressedSize;
}
final class NetworkRef extends ContentRef { final Uri uri; final Map<String,String> headers; }

// 页 / 章 / 文档
class PageNode {
  final String id;
  final PageKind kind;
  final PageContent content;
  final double? aspectRatio;   // ★ 虚拟长页的关键：不加载图也能算高度
  final String? title;
}

class Chapter { final int index; final String title; final List<String> pageIds; }

class Document {
  final String id, bookId, title;
  final DocumentKind kind;                 // comic / novel / pdf / web / doc
  final List<Chapter> chapters;
  final Map<String, PageNode> pages;       // 扁平索引，O(1) 取页
  final ReadingUnit unit;                  // page | pixel
  final DocumentLayoutHint hint;           // 默认模式建议
}
```

**为什么 `aspectRatio` 是必须的**：长图模式要在**不加载任何图片**的前提下算出整条虚拟长页的总高度，否则进度条、百分比跳转全部无法工作。所以导入阶段必须做一次"图片头嗅探"——只读每张图的前若干字节解析宽高，成本极低（见 §2.6）。

**为什么 `ContentRef` 不含字节**：`Document` 会被序列化、被放进内存、被多个 View 共享。一旦它持有 `Uint8List`，内存必然失控。所有字节都通过 `ContentLoader` 按需获取。

## 1.6 内容加载抽象

```dart
/// 随机访问字节源 —— 本地文件、SAF URI、HTTP Range 都实现它
abstract interface class RandomAccessByteSource {
  Future<int> length();
  Future<Uint8List> read(int offset, int length);   // 可乱序、可并发
  Future<void> close();
}
```

阅读器侧只需要一个极薄的接口：

```dart
/// 页字节提供者：Model 不认识字节，View 不认识压缩包
abstract interface class PageByteResolver {
  Future<Uint8List> imageBytes(String pageId);
  Future<String> textOf(String pageId);
  Future<void> dispose();
}
```

`ArchivePageByteResolver` 的实现链：`pageId → ArchiveEntryRef → ZipArchiveSource.readEntry() → LRU 缓存 → Uint8List`。

## 1.7 技术选型表

| 需求 | 本仓库起步选择 | 理由 | 后续可升级 |
|---|---|---|---|
| 状态管理 | **provider** | 最低上手成本，足够表达阅读器状态 | Riverpod（大项目） |
| 文件选择 | **file_picker** | `pickFiles` / `getDirectoryPath`，Android 走 SAF 免存储权限 | — |
| 压缩包 | **自研 ZIP 中央目录 + `archive` 的 `Inflate`** | 自研才可能"只读中央目录"；`archive` 只借用 DEFLATE 算法 | 增量 inflate / ffi zlib |
| 图片渲染 | **Flutter 内置 `Image.memory`** | 零依赖，`ImageProvider` 自带解码缓存 | `extended_image`（要手势时） |
| 手势缩放 | **内置 `InteractiveViewer`** | 零依赖，双击缩放可自行实现 | 自管 `Matrix4`（要边缘拖拽时） |
| 轻量持久化 | **shared_preferences** | 书架元数据 + 进度 + 设置，起步零成本 | drift/sqlite（书多了之后） |
| 路径 | **path_provider** | 缓存目录、数据库目录 | — |
| PDF | 待接 **pdfx** 或原生通道 | 见 §2.8 | Android `PdfRenderer` |
| DOCX | 待接 **archive + xml** 自研 | 见 §2.9 | — |
| TXT 编码 | 起步 **BOM + UTF-8 严格校验** | 零依赖覆盖 UTF-8/16/32 | **charset_converter + fast_gbk**（要 GBK 时） |
| 网络 | 待接 **dio** | 拦截器 / CancelToken / Range 齐全 | — |
| HTML 解析 | 待接 **html** | 纯 Dart，可后台 isolate | — |
| 网页渲染兜底 | 待接 **flutter_inappwebview** | **仅网页导入使用** | — |
| 数据库 | 待接 **drift** | 类型安全、迁移友好 | — |
| 网盘 | 设计抽象 **NetDiskProvider** | 见 §2.11 | WebDAV 优先 |

---

# 第 2 部分：导入流程 —— 从原始来源到统一模型

## 2.1 流水线总览

```
用户操作 ──▶ SourcePicker（文件/多文件/文件夹/URL/分享链接）
                │
                ▼
          Probe（嗅探）  ★ 只读前 8KB：魔术字节 > 扩展名
                │
                ▼
          ImportRouter   格式 → Importer 分派
                │
                ▼
          Importer.run()  产出 DocumentDraft（带进度、可取消）
                │
                ▼
          Enrich：封面 / 尺寸嗅探 / 自然排序 / 分章 / 分页
                │
                ▼
          Persist：落盘 + 元数据 + 进度   （失败可回滚）
                │
                ▼
             Document
```

```dart
class ImportContext {
  final SourcePick pick;
  final RandomAccessByteSource? bytes;   // 本地可随机访问时提供
  final String? password;                // 密码重试时携带
  final void Function(double ratio, String label) onProgress;
  final int resourceBudgetBytes;
}

sealed class ImportOutcome {}
final class ImportedDocument extends ImportOutcome { final Document document; final DocumentKind kind; }
final class NeedPassword extends ImportOutcome { final String hint; final int attempt; }
final class ImportFailure extends ImportOutcome { final AppError error; }

abstract interface class Importer {
  String get id;
  bool canHandle(SourceProbe probe);
  Future<ImportOutcome> run(ImportContext ctx);   // 必须幂等
}
```

**密码流程用"返回值"而非异常表达**：

```
run(pwd=null) ──▶ NeedPassword(attempt:1)
      │                 │
      │        UI 弹密码框
      ▼                 ▼
run(pwd="abc") ──▶ NeedPassword(attempt:2)   ← 密码错误
      │
      └──▶ ImportedDocument
```

好处：UI 只需处理三个分支；`attempt` 天然实现"错 3 次提示放弃"；密码只在内存存活（除非勾选记住 → `flutter_secure_storage`）。

## 2.2 Probe：用魔术字节识别，而不是扩展名

改名、无扩展名、`.zip` 实为 rar 很常见。**先读前 8KB 定格式**（实现见 `lib/core/magic.dart`）。

| 格式 | 判定依据 |
|---|---|
| zip | `50 4B 03 04` / `50 4B 05 06` / `50 4B 07 08` |
| rar4 / rar5 | `52 61 72 21 1A 07 00` / `... 07 01 00` |
| 7z | `37 7A BC AF 27 1C` |
| gzip | `1F 8B` |
| bzip2 / xz | `42 5A 68` / `FD 37 7A 58 5A 00` |
| tar | offset **257** 处为 `ustar` |
| pdf | `25 50 44 46` |
| doc(OLE2) | `D0 CF 11 E0 A1 B1 1A E1` |
| jpeg / png / webp / gif | `FF D8 FF` / `89 50 4E 47` / `RIFF....WEBP` / `GIF` |

**优先级**：魔术字节 > 内部结构（zip vs docx 看有无 `word/document.xml` + `[Content_Types].xml`）> 扩展名（仅用于消歧）。

## 2.3 ZIP 按需读取（本部分核心）

**绝对禁止**：`extractArchiveToDisk()`、`archive.decodeBytes(整个文件)`、`File.readAsBytes(整包)`。

### 第 1 步：找 EOCD（End of Central Directory）

EOCD 位于文件末尾，最长 22 + 65535 字节注释区，**倒着扫** `0x06054B50`：

```dart
final fileLen = await src.length();
final tailLen = math.min(fileLen, 22 + 0xFFFF);      // 只读尾部 64KB
final tail = await src.read(fileLen - tailLen, tailLen);
int eocd = -1;
for (int i = tail.length - 22; i >= 0; i--) {
  if (_u32(tail, i) == 0x06054B50) { eocd = i; break; }
}
```

从 EOCD 取：条目数(offset 10)、中央目录大小(12)、中央目录偏移(16)。
若任一为 `0xFFFFFFFF` / `0xFFFF` → 走 **Zip64**（先读 Zip64 EOCD Locator `0x07064B50` 再读 `0x06064B50`）。

### 第 2 步：解析中央目录

**不要按 46 字节步进**，因为文件名/extra/comment 是变长的。逐条读取并按实际长度前进：

```dart
while (list.length < count) {
  if (_u32(cd, p) != 0x02014B50) break;
  final flags      = _u16(cd, p + 8);
  final method     = _u16(cd, p + 10);
  final compSize   = _u32(cd, p + 20);
  final uncompSize = _u32(cd, p + 24);
  final nameLen    = _u16(cd, p + 28);
  final extraLen   = _u16(cd, p + 30);
  final commentLen = _u16(cd, p + 32);
  final localOff   = _u32(cd, p + 42);

  // ★ flag bit 11 (0x0800) = 文件名是 UTF-8；否则按 CP437/GBK 猜（中文包极常见）
  final name = (flags & 0x0800) != 0
      ? utf8.decode(nameBytes, allowMalformed: true)
      : decodeLegacyName(nameBytes);

  // ZIP64 extra field (id=0x0001) 覆盖被置为 0xFFFFFFFF 的字段
  p += 46 + nameLen + extraLen + commentLen;
}
```

### 第 3 步：按需 + 增量解压（真正的落点）

```dart
// 只读 30 字节局部头，算出 data 起始偏移
final lh = await src.read(e.localHeaderOffset, 30);
if (_u32(lh, 0) != 0x04034B50) throw const AppError('ZIP 局部头损坏');
final dataStart = e.localHeaderOffset + 30 + _u16(lh, 26) + _u16(lh, 28);

// ---- STORE：直接切片，零解压 ----
if (e.compressionMethod == 0) return await src.read(dataStart, e.uncompressedSize);

// ---- DEFLATE：只读该条目的压缩数据，解出需要的量就停 ----
final need = math.min(e.uncompressedSize, maxBytes);
final comp = await src.read(dataStart, e.compressedSize);
final out  = Inflate(comp, e.uncompressedSize).getBytes();
return Uint8List.sublistView(Uint8List.fromList(out), 0, need);
```

**为什么这不是"解压整个包"**：
- 从源读取的字节数 = `30 + 该条目压缩大小`，**与其他条目完全无关**；
- 一个 2GB 的漫画包，打开第一页只读了约 200KB；
- 中央目录本身必须完整读（约 1.8MB / 4 万条目），这是 ZIP 格式的天生上限，无法避免。

### 第 4 步：内存与并发规则

| 规则 | 值 | 原因 |
|---|---|---|
| 单条目解压输出上限 | 默认 64MB（可配） | 防 zip bomb；超过即报错，而不是 OOM |
| 条目字节 LRU 缓存 | 16 项 / 64MB | 滑回看时无需重复解压 |
| 已解压的图片再缓存 | `PageImageCache` 独立一层 | 与压缩包条目缓存分开计费更准 |
| 并发解压 | ≤ 2 | DEFLATE 是纯 CPU，太多会卡 UI isolate |
| **禁止** | `decodeBytes(整包)` | 直接违反约束 |

### 第 5 步：只解前 N 字节拿图片尺寸

**JPEG/PNG 的尺寸在文件头部，所以只需要解出前几十 KB。**

```dart
const _dimensionSniffBudget = 192 * 1024;
final need = math.min(e.uncompressedSize, _dimensionSniffBudget);
final head = await source.readEntry(e, maxBytes: need);
final dim  = ImageHeaderParser.tryParse(head);   // 见 §2.6
```

**产物**：`PageNode.aspectRatio`。至此虚拟长页总高度可在毫秒级算出，**一个像素都还没解码**。

## 2.4 rar / 7z：能力边界与桥接（诚实结论）

| 格式 | 纯 Dart `archive` | 结论 |
|---|---|---|
| zip | ✅ 完整 | **首选主线**，本仓库已自研按需读取 |
| tar | ✅ 完整 | 顺序读 512 字节头，记录 dataOffset 即可随机访问 |
| gz / tgz | ✅ | 单文件 gz 边解边产出；tar.gz 需顺序解压（可只解到目标条目即停） |
| bz2 | ⚠️ 部分 | `archive` 支持有限 |
| xz | ❌ | 基本没有纯 Dart 实现 |
| **rar** | ❌ | RAR5 是专有算法，**没有可用的成熟纯 Dart 实现** |
| **7z** | ❌ | 同上；LZMA/LZMA2 + BCJ 过滤器自研成本极高，不建议 |

**替代方案（按推荐度）**：

| 方案 | 实现 | 代价 |
|---|---|---|
| ① 引导转换（推荐起步） | 提示用户用外部工具转 zip | 0 成本、0 风险，但体验有损 |
| ② 原生桥 + 单条目解到临时文件 | Android `junrar`(libunrar) / `commons-compress`+`xz`；iOS `UnrarKit` / `PLzmaSDK` | APK +2~8MB；iOS 需 CocoaPods |
| ③ 只支持 RAR 的"存储(store)"模式条目 | store 模式未压缩，可直接按偏移切片读取 | 覆盖面小但实现成本极低 |

**原生桥接口设计**（`lib/data/archive/native_archive_source.dart` 已留骨架）：

```dart
abstract interface class NativeArchiveBridge {
  Future<List<ArchiveEntryInfo>> listEntries(String path, {String? password});
  /// ★ 只解这一个条目；大条目写入临时文件并返回句柄
  Future<NativeExtractResult> extractEntry(String path, ArchiveEntryInfo e,
      {String? password, int? maxBytes});
}

sealed class NativeExtractResult {}
final class NativeBytes extends NativeExtractResult { final Uint8List bytes; }
final class NativeTempFile extends NativeExtractResult {
  final String tempPath; final int offset, length; final String evictKey;
}
```

> **重要取舍**：原生解压"单条目到临时文件"是允许的（**不是**解压整个包），但必须配 **LRU 临时文件清理**（上限如 512MB，按最近使用淘汰，App 启动时清孤儿文件）。

## 2.5 tar / gz

| 情况 | 策略 |
|---|---|
| `.tar` | 顺序扫 512 字节**头部**（不读数据块）建立索引，之后随机读 |
| `.gz`（单文件） | 流式解压，边解边产出，中断即停 |
| `.tar.gz` | **务实方案**：解压到临时文件 + LRU（首次打开需索引，UI 明确提示）；进阶方案：解压时记录 gzip 块边界建稀疏索引，后续按需续解 |

tar 头结构要点：`name[0..100]`、`size[124..136]`（八进制）、`typeflag[156]`、`prefix[345..500]`；GNU 长文件名用 `typeflag='L'` 的前置条目承载；结束标志是连续两个全零块。

## 2.6 图片头部尺寸解析器

```dart
static ImageDimension? tryParse(Uint8List b) {
  if (b.length >= 24 && b[0]==0x89 && b[1]==0x50) return _png(b);   // IHDR
  if (b.length >= 4  && b[0]==0xFF && b[1]==0xD8) return _jpeg(b);  // 找 SOF
  if (b.length >= 30 && ascii(b,0,4)=='RIFF')     return _webp(b);  // VP8/VP8L/VP8X
  if (b.length >= 10 && ascii(b,0,3)=='GIF')      return _gif(b);
  if (b.length >= 26 && ascii(b,0,2)=='BM')       return _bmp(b);
  return null;
}
```

**JPEG 必须遍历 marker 找 SOF**（`0xC0..0xCF`，排除 `0xC4` DHT / `0xC8` JPG / `0xCC` DAC），不能假设尺寸在固定偏移：

```
FF D8 | FF E0 (APP0, len) | ... | FF C0 (SOF0) [len][precision][height:2][width:2]
```

WebP 三种变体：
- `VP8 `（有损）：`width = LE16(26) & 0x3FFF`，`height = LE16(28) & 0x3FFF`
- `VP8L`（无损）：读第 21~24 字节的 32 位，`w = (bits & 0x3FFF) + 1`，`h = ((bits>>14) & 0x3FFF) + 1`
- `VP8X`（扩展）：24 位小端 +1

## 2.7 压缩包 → Document 的转换（漫画主路径）

```
1) 过滤垃圾条目：__MACOSX/、.DS_Store、Thumbs.db、._*、desktop.ini
2) 分类：images / texts / nestedArchives
3) 嵌套压缩包且无其他内容 → 只下钻一层；≥3 层提示"疑似套娃包"
4) images ≥ 3 且占多数 → 漫画
5) texts 非空 → 小说
6) 其他 → 报错
```

**分章规则（漫画）**：按**最长公共目录前缀**分组，`第01话/001.jpg` → 章"第01话"；根目录图片归为"正文"。单章超过 200 张时按每 100 张切分，避免单章过长。

**排序必须逐段比较**，不能排完整路径（否则 `第1话/10.jpg` 与 `第10话/1.jpg` 会错位）：

```dart
comparePath(a, b) → 按 '/' 切分，逐段用 NaturalComparator.compare()
```

## 2.8 PDF 导入：只取元数据，绝不预渲染

```
① 确保有可随机访问的 PDF 源
   < 32MB → 全部读入内存（PDF 解析需随机访问）
   ≥ 32MB → 分块落盘临时文件（TempFileCache 管理）
② 只打开文档取页数与 MediaBox 尺寸，不 render
③ 每页 → PageNode(kind: pdfPage, aspectRatio: w/h, content: PdfPageContent)
④ 渲染留在阅读器侧：可见页 + 上下各预渲 1 页，离开窗口即 dispose
```

| 引擎 | 随机渲染单页 | 内存控制 | 许可 | 结论 |
|---|---|---|---|---|
| **pdfx** | ✅ `render(page, width, height)` | 良好 | MIT | **默认选择** |
| 平台原生通道（`PdfRenderer` / `CGPDFDocument`） | ✅ 完全可控 | 最佳 | — | 进阶兜底 |
| syncfusion_flutter_pdfviewer | ✅ | 良好 | **商业许可** | 开源项目慎用 |

> **pdfx 注意点**：内部有文档级缓存，必须在离开时 `close()`，否则大 PDF 常驻内存。渲染宽度要限制为 `min(viewportWidth * 2, 2048)`——2x 密度已足够清晰，同时把位图控制在约 16MB 以内，避免超宽页 OOM。

## 2.9 DOCX 导入：DOCX = ZIP + XML

```
word/document.xml          主文档（段落 / 行内样式 / 表格 / 内嵌图）
word/_rels/document.xml.rels  rId → media/imageN.png 关系表
[Content_Types].xml        用于确认为 DOCX
```

段落解析要点：

```dart
for (final node in body.childElements) {
  switch (node.name.local) {
    case 'p':   builder.addParagraph(node); break;   // w:p
    case 'tbl': builder.addTable(node);     break;   // w:tbl
  }
}

// w:p 内：
//   w:pPr → w:pStyle/@w:val ('Heading1'...) → 标题层级；w:jc 对齐；w:ind 缩进
//   w:r   → w:rPr → w:b 粗体 / w:i 斜体 / w:u 下划线 / w:sz 半磅字号 / w:color / w:rFonts
//           w:t 文本（注意 xml:space="preserve"）；w:tab；w:br
//           w:drawing|w:pict → a:blip/@r:embed → 关系表 → 包内图片条目
```

**支持的格式**：粗体/斜体/下划线、字号、颜色、字体、标题层级、居中/缩进、图片、表格（降级为等宽文本网格）、列表（降级为 `•` + 缩进）。

**不支持的**：文本框/艺术字、SmartArt、图表（`word/charts/`）、脚注布局、页眉页脚精确定位、分栏。**必须在 UI 明确提示"部分排版已简化"，不要假装还原。**

### 旧版 `.doc`（OLE2）

**纯 Dart 不现实，也不该硬做**：需要解析 `WordDocument` 流 + `FIB` + piece table（`CLX`），文本可能分片、压缩（`fCompressed`）、甚至 RC4 加密，实现量数千行且极易出错。

| 方案 | 代价 | 合规 |
|---|---|---|
| **① 引导转换（推荐）** 提示用户另存为 .docx/.pdf | 体验有损，0 成本 | ✅ |
| ② 平台 Intent 让办公 App 转换后回传 | 依赖第三方 App | ✅ |
| ③ 服务端/本地 LibreOffice `--convert-to docx` | 移动端不可行 | ✅（自建） |
| ④ 商业 SDK（Aspose.Words / Syncfusion DocIO） | 体积大、授权费 | ⚠️ 商业 |
| ⑤ Android 侧 Apache POI `HWPF` 桥接 | APK +8MB、方法数膨胀 | ✅ Apache 2.0 |

**产品建议**：默认 ①，设置里提供 ② 作为进阶。

## 2.10 文件夹导入：自然排序 + 内容判定

```
1) 递归遍历（限深 4 层），过滤隐藏文件与系统文件
2) 根目录有 ≥2 个压缩包且图片 < 5 → 每个压缩包一"本"（返回 MultiBookDetected）
3) ≥2 个子目录含图片 → 子目录 = 章
4) 根目录直接放图 ≥3 → 单章漫画
5) 文本为主 → 小说
```

**自然排序实现要点**（`lib/core/natural_sort.dart`）：

```
'1.jpg' < '2.jpg' < '10.jpg'        数字段按数值比较，而非字典序
'第1话' < '第10话'                   中文标题中的数字同样生效
'a2b10' < 'a10b2'                    多段数字逐段比较
'1' < '01'                           数值相同则前导零少的优先
避免大数溢出：去前导零后先比长度，再比字典序（不转 int）
```

### Android SAF / 分区存储

| 场景 | 方案 | 需要权限 |
|---|---|---|
| 选单个/多个文件 | `file_picker.pickFiles()` → SAF `ACTION_OPEN_DOCUMENT` | **不需要** |
| 选文件夹 | `file_picker.getDirectoryPath()` | **不需要** |
| 枚举 SAF 目录 | `DocumentsContract.buildChildDocumentsUriUsingTree` 逐层查 | **不需要** |
| 需要直接路径（旧 App 迁移） | `MANAGE_EXTERNAL_STORAGE` | ⚠️ Google Play 严格审核，慎用 |

**SAF 三个坑**：
1. 用户可能只授权某个子目录 → 不能假设能上溯父目录；
2. 授权在卸载/清数据后失效 → 必须 catch `SecurityException` 重新引导；
3. `content://` 不是文件路径 → 要用 `ContentResolver.openFileDescriptor` 拿 fd，再用 ffi 的 `pread(fd, buf, count, offset)` 实现真正的随机访问（退化为顺序 skip+read 性能差很多）。

**iOS 对应**：`UIDocumentPickerViewController` + security-scoped bookmark，长期访问必须存 bookmark 并在下次 `resolve`。

## 2.11 网页导入：抓取 + 正文提取 + 引用重写

```dart
// ① 抓原始字节，自己解码（不要依赖 response.body 的自动解码）
final resp = await dio.get<List<int>>(uri.toString(),
  options: Options(responseType: ResponseType.bytes,
    headers: {'User-Agent': _mobileUA, 'Accept-Language': 'zh-CN,zh;q=0.9'}),
  cancelToken: ctx.cancel);

final encoding = _fromContentType(contentType)     // charset=...
              ?? _fromMetaCharset(resp.data!)      // <meta charset>
              ?? CharsetDetector.detectBytes(resp.data!);
final html = decodeBytes(resp.data!, encoding);

// ② Readability 提取
final article = await Readability.extract(html, baseUri: resp.realUri ?? uri);

// ③ 逐块生成 PageNode（段落 → text，插图 → image(NetworkRef)）
```

**Readability 启发式（Mozilla 简化版）**：

```
1) 清理：移除 script/style/noscript/iframe/nav/footer/aside/form
   class/id 黑名单：comment|sidebar|footer|header|nav|ad|promo|share|related

2) 打分：对每个 <p>/<pre>/<td>
     contentScore  = 1 + min(3, floor(textLength/100)) + 标点数量
     score[parent]      += contentScore
     score[grandparent] += contentScore / 2
   类名加成（中文站点同样有效）：
     命中 article|content|post|entry|main|正文|内容  → *2
     命中 comment|meta|foot|nav|sidebar|ad           → *0.3

3) 取最高分节点的祖先链中"内容最完整"的一个作为 article root

4) 按阅读顺序抽取块：p / h1..h6 / blockquote / pre / ul,ol / figure,img / table
5) 标题：<h1> > og:title > <title>（去站点后缀）
6) 作者/时间：meta[name=author] / meta[property=article:author] / .author
```

**图片引用重写**（`src` / `data-src` / `data-original` / `data-lazy-src` / `srcset` 取最大宽度；`data:` base64 也支持；相对路径 → `base.resolve`）。

**为什么用 `NetworkRef` 而不是下载到本地**：
- 网页插图几十到几百张，全下载浪费流量；
- 走 HTTP loader 天然支持磁盘缓存与懒加载（**正好满足"图片懒加载"**）；
- 用户点"离线保存"时，批量下载并**把 `NetworkRef` 替换为 `FileRef`**。

**兜底**：HTTP 抓取失败（403 反爬 / SPA / Cloudflare）时，用隐藏 `flutter_inappwebview` 注入 Readability.js 拿回 article HTML，回到第 ② 步。
> **这里 WebView 只用于网页链接导入**，**绝不用 WebView 渲染漫画或 PDF**。

## 2.12 网盘导入：抽象接口驱动

```dart
abstract interface class NetDiskProvider {
  String get id;                 // 'webdav' | 'baidu' | 'aliyun' | 'quark'
  String get displayName;
  NetDiskCapability get capabilities;

  Future<bool> isAuthenticated();
  Future<AuthResult> authenticate(AuthContext ctx);
  Future<void> logout();

  Future<ShareHandle> resolveShare(Uri shareUrl, {String? password});
  Future<List<NetDiskEntry>> list(NetDiskRef dir);
  Future<SequentialByteSource> openRead(NetDiskEntry file);
  Future<Uri?> directLink(NetDiskEntry file);
}

class NetDiskCapability {
  final bool rangeRequest, directLink, shareWithoutLogin, needsOfficialApp;
}
```

### 各网盘现实（必须诚实披露）

| Provider | 列目录 | 流式读取 | Range | 分享链接免登录 | 实现路径 | 风险 |
|---|---|---|---|---|---|---|
| **百度网盘** | ✅ 官方 API | ✅ | 取决于 dlink | ❌ 需登录 | OAuth2 + `/xpan/*`；分享用 `surl` + `pwd` 换 `shareid`/`uk` 再 `/xpan/share/list` | 官方限速；`dlink` 需带 `User-Agent: pan.baidu.com` 且必须附 `access_token` |
| **阿里云盘** | ✅ 官方 OpenAPI | ✅ | 通常支持 | ❌ 需登录 | OAuth2 + `/adrive/v1.0/openFile/*` | 接口随版本变化；需应用审核 |
| **夸克** | ⚠️ 无公开 API | ⚠️ 不可靠 | ⚠️ | ❌ | 仅能 WebView Cookie 驱动私有接口 | **违反 ToS 高风险、随时失效、可能触发风控封号** |
| **WebDAV**（坚果云/Nextcloud/群晖） | ✅ 标准协议 | ✅ | ✅ | ✅ 可匿名只读 | 纯 Dart `webdav_client` | ✅ **零风险，首推** |
| **SMB / SFTP**（局域网 NAS） | ✅ | ✅ | ✅ | — | `smb_connect` / `dartssh2` | ✅ 局域网自建，零风险 |
| **局域网 HTTP 目录**（Komga / Calibre-Web） | ✅ | ✅ | ✅ | ✅ | `dio` + HTML 解析 | ✅ **零风险，首推** |

### 远程压缩包的两条路径

```
网盘里的 book.zip
 ├─ 路径 A：全量下载到本地临时文件 → 走本地 ZipArchiveSource
 │    优点：实现简单、后续阅读快、支持随机访问
 │    缺点：首次必须下完（受网盘限速影响大）
 └─ 路径 B：HTTP Range 读远程 zip 中央目录
      ① 先取末尾 ~64KB 拿 EOCD
      ② HEAD 或 Range: bytes=0-0 探测总大小与 Accept-Ranges
      ③ 逐条目按需 Range 下载解压
      优点：打开 2GB 包只需下载几百 KB
      缺点：直链常带一次性签名、Range 支持不稳定、请求多了被限流
```

**建议两条都实现，运行时探测决定**：

```dart
Future<RemoteArchiveStrategy> chooseStrategy(NetDiskProvider p, NetDiskEntry e) async {
  final link = await p.directLink(e);
  if (link != null) {
    final src = HttpRangeByteSource(dio, link, p.downloadHeaders);
    if (await src.probeRangeSupport() && e.size < _hugeThreshold) {
      return Strategy.remoteRange;      // 首选：不下载整个包
    }
  }
  return Strategy.downloadThenOpen;     // 兜底：下载整包（带进度 + 断点续传）
}
```

### 第三方"解析服务"的定位

- ❌ 不要假设其可用性（随时关停、限速、返回空链）；
- ❌ 不要在其上做用户鉴权（等于把 token 交给第三方）；
- ⚠️ 可能违反目标网盘 ToS，且服务方可能收集用户数据；
- ✅ **正确用法**：用户**手动可选**的兜底入口，UI 注明"由第三方提供，请自行评估风险"，**默认关闭**。

### 插件化注册表

```dart
class NetDiskRegistry {
  final Map<String, NetDiskProvider Function()> _factories = {};
  void register(String id, NetDiskProvider Function() f) => _factories[id] = f;
  NetDiskProvider? resolve(String id) => _factories[id]?.call();

  static NetDiskRegistry bootstrap() => NetDiskRegistry()
    ..register('webdav', () => WebDavProvider())
    ..register('smb',    () => SmbProvider())
    ..register('baidu',  () => BaiduProvider())
    ..register('aliyun', () => AliyunProvider())
    ..register('quark',  () => QuarkExperimentalProvider(isEnabled: false));
}
```

新增一个网盘 = 实现 7 个方法 + `register()` 一行。**阅读器、导入流程、UI 全部零改动。**

## 2.13 导入的工程细节

**在后台 isolate 执行**：inflate、XML 解析、正则分章都是 CPU 密集。注意 `onProgress` 闭包不能跨 isolate，要用 `SendPort` 转发。

**去重（内容指纹）**：

```dart
String contentFingerprint(SourcePick pick, {List<ArchiveEntryInfo>? entries}) {
  if (entries != null) {
    // 压缩包：条目数 + 总解压大小 + 首尾条目名 —— 不读内容，大包也能算
    return 'arc:' + sha1('${entries.length}|${totalSize}|${first.path}|${last.path}').substring(0,16);
  }
  // 本地文件：路径 + 大小 + mtime
  return 'file:' + sha1('${pick.path}|${pick.size}|${pick.mtime}').substring(0,16);
}
```

**原子写入**：元数据与进度在同一个事务里写；封面生成放在事务之后（失败只是没封面，不影响书可用）。

**封面策略**：显式封面（`cover.jpg`/`ComicInfo.xml`）> 第一章第一页 > PDF 第 1 页 > `og:image` > 程序生成占位封面。**用 `targetWidth: 512` 解码，绝不加载原图再缩放。**

**错误分类驱动 UI**：

```dart
sealed class AppError { final String message; final String? technicalDetail; final ErrorAction action; }
enum ErrorAction { retry, enterPassword, chooseAnother, openSettings, convertFile, none }
```

---

# 第 3 部分：三种阅读模式的实现方案

## 3.1 三种模式一览

| 模式 | 交互 | 实现骨架 | 进度单位 |
|---|---|---|---|
| ① 左右滑动翻页 | 水平拖拽 → 上一页/下一页 | `PageView` + `PageController` | page |
| ② 左右点击翻页 | 点左侧上一页、右侧下一页、中间呼出菜单 | 同一 `PageView`，叠加点击分区 | page |
| ③ 上下滑动（虚拟长页） | 纵向连续滚动，无缝拼接 | `CustomScrollView` + `SliverList` + 预计算度量 | **pixel** |

**模式 ①② 共用同一个 `PageView`**，差异只在手势层：① 开启 `physics: PageScrollPhysics()`；② 也开启滑动（更符合直觉），同时叠加点击分区；若用户想要"纯点击"，可把 `physics` 设为 `NeverScrollableScrollPhysics()`。

**模式之间的位置换算**在 `ReaderController` 中统一处理（§3.6），底层都用**归一化 ratio** 作为"跨模式通用货币"。

## 3.2 模式 ③：虚拟长页的核心 —— 度量先行

### 3.2.1 为什么必须先有度量

虚拟长页要在**不加载任何图片**的前提下回答三个问题：
1. 整条长页总高度是多少？（进度条、百分比）
2. 第 N 页的顶部 y 是多少？（跳转）
3. 当前 y 落在第几页？（进度保存、可见窗口计算）

答案来自导入阶段得到的 `aspectRatio`：

```dart
class PageMetrics {
  final double viewportWidth;
  final List<double> tops;      // 每页顶部 y
  final List<double> heights;   // 每页高度 = viewportWidth / aspectRatio
  final double totalHeight;

  int pageAt(double y);
  double topOf(int index);
  double ratioAt(double y)  => totalHeight == 0 ? 0 : y / totalHeight;
  double offsetForRatio(double r) => (r * totalHeight).clamp(0, totalHeight);
  PageMetrics copyWithWidth(double w);   // 横竖屏切换重建
}
```

构建是 **O(n) 前缀和**，1 万页也是微秒级：

```dart
double y = 0;
for (final p in pages) {
  tops.add(y);
  final h = viewportWidth / (p.aspectRatio ?? 1.4);   // 无尺寸时用兜底比例
  heights.add(h);
  y += h;
}
totalHeight = y;
```

**`aspectRatio` 未知时的兜底**：用中位数比例（漫画常见 1.4~1.5），并在该页**真实解码后回填**，触发一次 `relayout`。因为长页总高会变，所以要**按锚点保持位置**（§3.5）。

### 3.2.2 为什么是 `CustomScrollView + SliverList`（而不是嵌套 ListView / SingleChildScrollView）

| 方案 | 问题 |
|---|---|
| `SingleChildScrollView` + `Column` | **一次性构建所有子节点** → 1 万页直接卡死，违反约束 |
| 外层 `ListView` + 内层 `ListView`(不可滚动) | 需要 `shrinkWrap` + 禁用滚动，**性能极差**（每帧测量全部子项） |
| `PageView`(vertical) | 一页一屏，无法"无缝拼接"，不符合 Webtoon 需求 |
| **`CustomScrollView` + `SliverList`** ✅ | Sliver 按需构建**可见 + cacheExtent 内**的子项，天然懒加载；总高度由 `SliverList` 根据已构建项累加，但**未构建项的高度需要提前告知** |

关键：给每个 item 一个**固定高度**（来自 `PageMetrics`），`SliverList` 就不需要测量未构建项，`maxScrollExtent` 也能算准。

```dart
CustomScrollView(
  controller: _scroll,
  cacheExtent: _cacheExtent,   // ★ 预取窗口，例如 1.5 屏
  slivers: [
    SliverList.builder(
      itemCount: pages.length,
      itemBuilder: (ctx, i) => SizedBox(
        height: metrics.heights[i],      // ★ 预先告知高度 → 不需要测量未构建项
        child: PageImage(pageId: pages[i].id),
      ),
    ),
  ],
)
```

### 3.2.3 可见窗口、预取窗口、回收

```
                     viewport (屏幕上可见)
   ┌────────────────────────────────────────────────┐
───┼────────────────────────────────────────────────┼───
   │  预取窗口 = cacheExtent (上下各 1~1.5 屏)       │
   │  ┌──────────────────────────────────────────┐  │
   │  │ 可见区：真正解码并渲染                      │  │
   │  └──────────────────────────────────────────┘  │
───┼────────────────────────────────────────────────┼───
   │                                                │
```

| 层级 | 范围 | 行为 |
|---|---|---|
| 可见区 | `scrollOffset ~ scrollOffset + viewportHeight` | 解码 + 渲染 |
| 预取区 | 上下各 `cacheExtent` | **只预解压 + 预加载字节**，交给 `PageImageCache`；不强制解码 |
| 窗口外 | 其余 | **LRU 淘汰字节**，`Image.memory` 释放 → 允许 GC |

`Flutter` 的 `ImageCache` 默认上限是 100 张 / 100MB，长图场景要主动收紧：

```dart
// main.dart
PaintingBinding.instance.imageCache.maximumSize     = 24;        // 张数
PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20; // 64MB
```

**为什么不能靠 Flutter 默认缓存**：默认按"图片张数"计，一张 1080×20000 的 Webtoon 长条就能吃掉几百 MB，必须同时限制字节数并配合自己的 `PageImageCache`。

### 3.2.4 超长图的瓦片化解码（单页高度 > 设备最大纹理）

**问题**：Android 的 `GL_MAX_TEXTURE_SIZE` 常见为 4096 / 8192 / 16384。一条 1080×30000 的 Webtoon 长条**无法作为单个纹理上传**，`Image.memory` 会解码失败或 OOM。

**解决思路（分三级，按成本递增）**：

| 级别 | 做法 | 何时用 |
|---|---|---|
| L0 | `Image.memory(..., cacheWidth: ...)` 让解码器降采样 | 页高 ≤ 8192 时够用 |
| L1 | **`cacheWidth` + 按需缩小**：把宽度降到屏幕物理宽度即可，高度按比例缩小 | 大多数情况 |
| L2 | **瓦片化**：把一页切成 N 个垂直瓦片，各自独立解码渲染 | 页高 > 16384 且不能缩小 |

**L2 的实现要点**（本仓库起步未实现，需自研）：

```
① 用 ui.ImageDescriptor.encoded 拿到整图尺寸（不解码像素）
② 用 ui.instantiateImageCodec(bytes, targetWidth: tileWidthPx, targetHeight: ...)
   实际上 Flutter 只支持整体缩放，不支持"区域解码"
③ 真正的瓦片化必须走平台原生：
   - Android: BitmapRegionDecoder.decodeRegion(rect, options)  ★ 完美支持
   - iOS:     CGImageSourceCreateThumbnailAtIndex / CGImage.cropping(to:)
④ 平台通道返回瓦片字节 → 各自的 Image.memory 渲染
⑤ 一条长页 = Column(children: tiles)，外层仍是 SliverList 的一项
```

> **诚实说明**：Dart 层**做不到**真正的区域解码。Webtoon 长条的瓦片化必须走 Android `BitmapRegionDecoder`。本仓库起步实现采用 L1（`cacheWidth` 限宽 + 高度受控），并把 L2 的接口位置留在 `PageImage` 里。

### 3.2.5 无缝拼接的细节

| 细节 | 做法 |
|---|---|
| 图片之间无间隙 | `SizedBox(height: heights[i])` 精确等于 `width / aspectRatio`；不要加 `Padding`、不要用 `Divider` |
| 避免 1 像素缝 | 高度用 `double` 累加后**最后一项补齐**：`heights.last = totalHeight - tops.last` |
| 图片填满 | `Image.memory(fit: BoxFit.fill)` —— 因为高度已按比例算好，`fill` 不会变形；用 `cover` 会裁切，用 `contain` 会出现缝隙 |
| 圆角/边框 | **禁止**在长图模式加圆角或间距，否则破坏"一条长页"的视觉 |
| 抗锯齿 | 保持默认；Webtoon 缩小时可能略糊，可加 `filterQuality: FilterQuality.medium` |

## 3.3 进度计算与跳转任意位置

### 3.3.1 进度 = 滚动像素 / 总高度

```dart
_scroll.addListener(() {
  final y = _scroll.offset;
  onScroll(y);                      // → controller.updateScroll(y)
});

// controller 内
void updateScroll(double y) {
  final m = _metrics!;
  _progress = _progress.copyWith(
    pixelOffset: y,
    pageIndex: m.pageAt(y),
    ratio: m.ratioAt(y),
  );
  notifyListeners();                // 只刷新进度条，不重建列表
}
```

**性能关键**：进度条的刷新**必须与列表重建解耦**。做法：
- `ReaderController` 的 `notifyListeners()` 只让 `ProgressBar` 重建（用 `Selector` / 独立的 `ValueNotifier<double>`）；
- **绝不在滚动回调里 `setState` 整个阅读器**。

```dart
// 推荐：进度单独用一个 ValueNotifier<double>，滚动时只通知它
final progressRatio = ValueNotifier<double>(0);
// ProgressBar 监听它；文档结构变化时才走 Provider
```

### 3.3.2 跳转到任意像素或百分比

```dart
// 跳百分比
void jumpToRatio(double r) {
  final target = _metrics!.offsetForRatio(r);
  _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
}

// 带平滑动画（拖动进度条松手时用）
void animateToRatio(double r) {
  final target = _metrics!.offsetForRatio(r);
  _scroll.animateTo(target,
      duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
}

// 跳到指定页
void jumpToPage(int index) => jumpToRatio(_metrics!.topOf(index) / _metrics!.totalHeight);
```

**拖动进度条的交互模式很重要**：

```
onDragStart  → 进入"预览模式"：暂停进度回写，显示目标页码/百分比气泡
onChanged    → 只更新气泡，不真正滚动（避免抖动）
onDragEnd    → animateToRatio(最终值)，恢复进度回写
```

如果 `onChanged` 就直接 `jumpTo`，长列表会疯狂重建，且松手后位置会被滚动回调覆盖，体验很差。

### 3.3.3 横竖屏切换 / 字号变化后保持进度

**核心手段：锚点（anchor）**。

```
旋转前：
  scrollY = 12345, 当前页 index=7, 页内偏移 = 12345 - topOf(7) = 345
  记录 anchor = (pageIndex: 7, ratioInPage: 345 / heightOf(7) = 0.37)

旋转后（viewportWidth 变了 → 所有高度都变了）：
  新 heightOf(7) = newWidth / aspectRatio
  新 scrollY = newTopOf(7) + 0.37 * new heightOf(7)
  → jumpTo(newScrollY)
```

**不能**直接用 `ratio`（全书百分比）恢复，因为各页高度按比例变化时，全书比例会漂移；**必须用"页 + 页内比例"这个二维锚点**。

```dart
class ScrollAnchor {
  final int pageIndex;
  final double ratioInPage;
  final double zoom;
  final Offset zoomPan;
}
```

同理，**TXT 改字号后**：分页结果变了，要用**字符偏移**作为锚点（而不是页号），重新分页后找到包含该字符偏移的新页。这正是"两阶段分页"（§2.7 / §4.4）存在的意义。

## 3.4 手势系统与冲突仲裁

### 3.4.1 需要识别的手势

| 手势 | 行为 |
|---|---|
| 单指纵向拖动 | 长图模式滚动 / 页模式无（或切页） |
| 单指横向拖动 | 页模式翻页 |
| 双指捏合 | 缩放（1.0 ~ 5.0） |
| 双击 | 放大到 2.0 并居中 / 还原到 1.0 |
| 单击左侧 | 模式 ② 上一页 |
| 单击右侧 | 模式 ② 下一页 |
| 单击中间 | 显示 / 隐藏菜单 |
| 长按 | 收藏当前页 / 书签（可选） |

### 3.4.2 冲突来源与仲裁状态机

冲突有三种：

1. **横向翻页 vs 缩放平移**：缩放到 2x 后，横向拖动应该是**平移图片**，不是翻页。
2. **纵向滚动 vs 纵向平移**：长图模式放大后，纵向拖动要同时满足"滚动到下一屏"和"平移当前图"。
3. **单击 vs 双击**：`onTap` 会先于 `onDoubleTap` 触发，必须延迟处理单击。

**仲裁规则（按优先级）**：

```
                    ┌──────────────┐
                    │  pointer down │
                    └──────┬───────┘
                           ▼
                  ┌─────────────────┐
                  │ 多指(≥2) 按下？  │──是──▶ 缩放模式：InteractiveViewer 全权接管，
                  └────────┬────────┘        外层滚动/翻页 physics = NeverScrollable
                           │否
                           ▼
                  ┌─────────────────┐
                  │ 当前 scale > 1？ │──是──▶ 平移优先：
                  └────────┬────────┘        图片未到边缘 → 图片平移
                           │否                图片到边缘 → 允许外层滚动（手感续接）
                           ▼
                  ┌─────────────────┐
                  │ 判定主方向       │  横向位移 > 纵向位移 × 1.3 → 横向手势
                  └────────┬────────┘  否则 → 纵向手势
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
        模式①②：翻页             模式③：滚动
```

**代码落点**：`ui/reader/gesture_arbiter.dart`

```dart
enum GestureMode { idle, scaling, panning, horizontalPaging, verticalScrolling }

class GestureArbiter extends ChangeNotifier {
  GestureMode _mode = GestureMode.idle;
  double _scale = 1.0;

  /// 外层滚动/翻页是否应该被禁用
  bool get lockOuterScroll => _mode == GestureMode.scaling ||
                              (_mode == GestureMode.panning && !_panAtEdge);

  /// 图片是否已经平移到边缘（边缘处应把滚动权交还外层）
  bool _panAtEdge = true;

  void onScaleStart(int pointerCount) {
    _mode = pointerCount >= 2 ? GestureMode.scaling : GestureMode.idle;
    notifyListeners();
  }

  void onScaleUpdate(double scale, Offset panDelta, Size imageSize, Size viewSize) {
    _scale = scale.clamp(1.0, 5.0);
    if (_scale > 1.0 && _mode != GestureMode.scaling) _mode = GestureMode.panning;
    if (_scale <= 1.0) _mode = GestureMode.idle;
    // 计算是否已到边缘
    _panAtEdge = _computeAtEdge(panDelta, imageSize, viewSize);
    notifyListeners();
  }

  void onScaleEnd() {
    if (_scale < 1.0) _scale = 1.0;
    _mode = _scale > 1.0 ? GestureMode.panning : GestureMode.idle;
    notifyListeners();
  }
}
```

**接入方式**：

```dart
// 长图模式：外层滚动控制器根据仲裁结果切换 physics
NotificationListener<ScrollNotification>(
  onNotification: (n) {
    if (arbiter.lockOuterScroll) return true;   // 吞掉滚动通知
    return false;
  },
  child: CustomScrollView(
    physics: arbiter.lockOuterScroll
        ? const NeverScrollableScrollPhysics()
        : const ClampingScrollPhysics(),
    ...
  ),
)
```

### 3.4.3 单击 vs 双击：必须延迟

```dart
Timer? _tapTimer;

void onTapUp(TapUpDetails d) {
  _tapTimer?.cancel();
  _tapTimer = Timer(const Duration(milliseconds: 220), () {
    _handleSingleTap(d.localPosition);   // 超过 220ms 没有第二次点击 → 单击
  });
}

void onDoubleTapDown(TapDownDetails d) { _doubleTapPosition = d.localPosition; }

void onDoubleTap() {
  _tapTimer?.cancel();                   // 取消挂起的单击
  _toggleZoom(_doubleTapPosition);
}
```

> 220ms 是经验值（略大于系统双击间隔）；太短会把双击误判成两次单击，太长会感觉单击有延迟。

### 3.4.4 缩放后仍能滚到任意位置

**难点**：`InteractiveViewer` 的 `panEnabled` 与世界边界是耦合的。当 `scale > 1` 且图片远大于视口时，`InteractiveViewer` 会**吃掉所有平移手势**，导致无法滚动到下一页。

**三种解法**：

| 解法 | 做法 | 评价 |
|---|---|---|
| A. `InteractiveViewer` + `boundaryMargin` | 设 `boundaryMargin: EdgeInsets.all(double.infinity)`，允许无限平移 | 简单，但会"滑出"到空白 |
| B. 每页独立缩放 | `InteractiveViewer` 只包当前页；缩放到边缘时**把滚动权交还外层**（`_panAtEdge`） | ✅ **推荐**，手感自然 |
| C. 自管 `Matrix4` + 全屏 `GestureDetector` | 完全自己控制 `scale/translate` 与滚动的优先级 | 最灵活，代码量最大 |

**本仓库起步实现用 B**：`InteractiveViewer` 只包单页；`GestureArbiter` 判断"是否已到图片边缘"，到边缘就把该次拖动交给外层 `CustomScrollView`（长图）或 `PageView`（页模式）。

**缩放后"跳转到任意位置"仍然成立**，因为跳转操作的目标是**外层滚动控制器的像素位置**，与内层缩放矩阵无关：

```dart
void jumpToRatio(double r) {
  final target = _metrics!.offsetForRatio(r);
  _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
  // 跳转时重置内层缩放，避免"跳到新位置但还带着旧缩放"
  arbiter.resetZoom();
}
```

## 3.5 三种模式间的位置换算

**统一货币：归一化 ratio（0~1）。**

```dart
// 模式①② → 模式③
double pixelFromPage(int pageIndex, double ratioInPage) {
  final m = metrics!;
  return m.topOf(pageIndex) + ratioInPage * m.heights[pageIndex];
}

// 模式③ → 模式①②
(int pageIndex, double ratioInPage) pageFromPixel(double y) {
  final m = metrics!;
  final i = m.pageAt(y);
  return (i, ((y - m.topOf(i)) / m.heights[i]).clamp(0.0, 1.0));
}

// 任意模式 → 保存进度
ReadingProgress snapshot() {
  if (mode == ReadingMode.vertical) {
    final (i, r) = pageFromPixel(scrollY);
    return ReadingProgress(pageIndex: i, ratioInPage: r,
        pixelOffset: scrollY, ratio: metrics!.ratioAt(scrollY), mode: mode);
  }
  return ReadingProgress(pageIndex: currentPage, ratioInPage: 0,
      pixelOffset: 0, ratio: currentPage / (pageCount - 1), mode: mode);
}

// 恢复进度（下次打开 / 切换模式）
void restore(ReadingProgress p) {
  if (mode == ReadingMode.vertical) {
    jumpToPixel(pixelFromPage(p.pageIndex, p.ratioInPage));
  } else {
    pageController.jumpToPage(p.pageIndex);
  }
}
```

**进度按模式分别记忆**：用户可能在"左右翻页"读到第 50 页，切到长图模式时不应丢失原模式的精确位置。

```dart
// prefs key: progress.{bookId}.{mode} → {pageIndex, ratioInPage, ratio, pixelOffset}
```

**`TXT` 换字号**时用**字符偏移锚点**而非页号：

```dart
// 分页前记录当前页首字符的全局偏移
final charAnchor = chapterCharOffsetOf(currentPage) + firstVisibleCharIndex;
// 重新分页后
final newPage = pageContainingChar(charAnchor);
```

## 3.6 预加载、缓存、失败重试

```dart
class PrefetchPolicy {
  /// 预取窗口（页数），按方向区分：向下读得多，向上读得少
  static const ahead = 3;
  static const behind = 1;

  /// 预取只解压字节、不渲染
  Future<void> prefetch(int currentPage) async {
    for (int i = currentPage + 1; i <= currentPage + ahead; i++) {
      unawaited(pageCache.ensure(i));     // 失败不阻塞主流程
    }
    for (int i = currentPage - 1; i >= currentPage - behind; i--) {
      unawaited(pageCache.ensure(i));
    }
  }
}
```

| 策略 | 做法 |
|---|---|
| 内存缓存 | `PageImageCache`（LRU，16 项 / 64MB）+ Flutter `ImageCache` 收紧到 24 张 / 64MB |
| 磁盘缓存 | 解压出来的页字节可选落盘（`cacheDir/pages/{bookId}/{hash}.bin`），但**要算清总预算**（默认关，仅对网络源开启） |
| 失败重试 | 指数退避（200ms → 400ms → 800ms），最多 3 次；第 3 次失败显示"点击重试"占位 |
| 不阻塞 | 预取全部 `unawaited`，列表滚动永远不等待预取 |
| 取消 | 快速滚动时取消已在途的预取（`CancelToken` / Future 取消标记） |

---

# 第 4 部分：关键代码片段

以下片段与仓库 `lib/` 中的实现一致（可能略微简化），可直接对照阅读。

## 4.1 压缩包按需读取（`lib/data/archive/zip_archive_source.dart`）

```dart
/// ZIP 中央目录随机访问：只读需要的字节，从不整包读取
class ZipArchiveSource implements ArchiveSource {
  static const _eocdSig = 0x06054B50;
  static const _centralSig = 0x02014B50;
  static const _localSig = 0x04034B50;

  final RandomAccessByteSource src;
  final int maxEntryBytes;
  final _cache = LruCache<String, Uint8List>(maxEntries: 16, maxBytes: 64 << 20);
  late final List<ArchiveEntryInfo> entries;

  Future<void> open() async {
    final len = await src.length();
    final tailLen = math.min(len, 22 + 0xFFFF);
    final tail = await src.read(len - tailLen, tailLen);

    int eocd = -1;
    for (int i = tail.length - 22; i >= 0; i--) {
      if (_u32(tail, i) == _eocdSig) { eocd = i; break; }
    }
    if (eocd < 0) throw const AppError('不是有效的 ZIP（找不到中央目录）');

    final count    = _u16(tail, eocd + 10);
    final cdSize   = _u32(tail, eocd + 12);
    final cdOffset = _u32(tail, eocd + 16);
    // 生产实现还需处理 Zip64（0xFFFFFFFF / 0xFFFF）

    final cd = await src.read(cdOffset, cdSize);
    entries = _parseCentralDirectory(cd, count);
  }

  /// ★ 只解这一个条目
  @override
  Future<Uint8List> readEntry(ArchiveEntryInfo e, {int? maxBytes}) async {
    final key = '${e.entryPath}@${maxBytes ?? -1}';
    final hit = _cache.get(key);
    if (hit != null) return hit;

    final need = maxBytes == null
        ? e.uncompressedSize
        : math.min(maxBytes, e.uncompressedSize);

    // ZIP64/流式条目的 compressedSize 可能为 0 → 退化为用 uncompressedSize 估读
    final compSize = e.compressedSize > 0 ? e.compressedSize : e.uncompressedSize;

    final lh = await src.read(e.localHeaderOffset, 30);
    if (_u32(lh, 0) != _localSig) throw const AppError('ZIP 局部头损坏');
    final nameLen  = _u16(lh, 26);
    final extraLen = _u16(lh, 28);
    final dataStart = e.localHeaderOffset + 30 + nameLen + extraLen;

    Uint8List out;
    if (e.compressionMethod == 0) {
      // STORE：未压缩，直接切片
      out = await src.read(dataStart, need);
    } else {
      final comp = await src.read(dataStart, compSize);
      if (comp.length < compSize) throw const AppError('压缩数据被截断');
      // 借用 package:archive 的 DEFLATE 实现（已确认 API：Inflate(bytes, size).getBytes()）
      final raw = Inflate(comp, e.uncompressedSize).getBytes();
      out = Uint8List.sublistView(Uint8List.fromList(raw), 0, need);
    }

    if (maxBytes == null) _cache.put(key, out);
    return out;
  }
}
```

## 4.2 虚拟长页（`lib/reader/page_metrics.dart` + `lib/ui/reader/vertical_reader.dart`）

```dart
/// 虚拟长页度量：由 aspectRatio 累加得到，与是否已解码无关
class PageMetrics {
  factory PageMetrics.build({
    required List<double?> aspectRatios,
    required double viewportWidth,
    double fallbackAspect = 1.4,
  }) {
    final tops = <double>[];
    final heights = <double>[];
    double y = 0;
    for (final ar in aspectRatios) {
      final a = (ar != null && ar.isFinite && ar > 0.05 && ar < 20) ? ar : fallbackAspect;
      tops.add(y);
      final h = viewportWidth / a;
      heights.add(h);
      y += h;
    }
    return PageMetrics._(viewportWidth, tops, heights, y);
  }

  int pageAt(double y) {
    if (y <= 0) return 0;
    if (y >= totalHeight) return heights.length - 1;
    // 二分查找：pixel → pageIndex
    int lo = 0, hi = tops.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (tops[mid] <= y) { lo = mid; } else { hi = mid - 1; }
    }
    return lo;
  }

  double ratioAt(double y) => totalHeight <= 0 ? 0 : (y / totalHeight).clamp(0.0, 1.0);
  double offsetForRatio(double r) => (r.clamp(0.0, 1.0)) * totalHeight;
}
```

```dart
/// 模式 ③：上下滑动虚拟长页
class VerticalReader extends StatefulWidget {
  final Document doc;
  final PageByteResolver resolver;
  final ReaderController controller;
}

class _VerticalReaderState extends State<VerticalReader> {
  late final ScrollController _scroll;
  late PageMetrics _metrics;

  @override
  void didChangeDependencies() {
    final width = MediaQuery.sizeOf(context).width;
    _metrics = PageMetrics.build(
      aspectRatios: widget.doc.pagesInOrder.map((p) => p.aspectRatio).toList(),
      viewportWidth: width,
    );
    widget.controller.attachMetrics(_metrics);
    super.didChangeDependencies();
  }

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
    _scroll.addListener(_onScroll);
    // 恢复进度
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    widget.controller.updateScroll(_scroll.offset);   // 只通知进度 ValueNotifier
  }

  void _restore() {
    final p = widget.controller.progress;
    final y = _metrics.topOf(p.pageIndex) + p.ratioInPage * _metrics.heights[p.pageIndex];
    if (y > 0 && _scroll.hasClients) _scroll.jumpTo(y.clamp(0, _scroll.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final pages = widget.doc.pagesInOrder;
    final arbiter = widget.controller.arbiter;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (d) => widget.controller.handleSingleTap(d.localPosition, context),
      onDoubleTapDown: (d) => widget.controller.rememberDoubleTap(d.localPosition),
      onDoubleTap: () => widget.controller.toggleZoom(context),
      child: AnimatedBuilder(
        animation: arbiter,
        builder: (ctx, _) => CustomScrollView(
          controller: _scroll,
          cacheExtent: MediaQuery.sizeOf(context).height * 1.5,   // ★ 预取窗口
          physics: arbiter.lockOuterScroll
              ? const NeverScrollableScrollPhysics()
              : const ClampingScrollPhysics(),
          slivers: [
            SliverList.builder(
              itemCount: pages.length,
              itemBuilder: (ctx, i) => SizedBox(
                // ★ 预先告知高度：SliverList 不需要测量未构建项
                height: _metrics.heights[i],
                child: PageImage(
                  pageId: pages[i].id,
                  resolver: widget.resolver,
                  fit: BoxFit.fill,           // 高度已按比例算好，fill 不变形
                  prefetchNeighbors: const [-1, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }
}
```

## 4.3 手势冲突处理（`lib/ui/reader/gesture_arbiter.dart`）

```dart
enum GesturePhase { idle, scaling, panningAtEdge, panningInside }

class GestureArbiter extends ChangeNotifier {
  double _scale = 1.0;
  GesturePhase _phase = GesturePhase.idle;
  bool _atEdge = true;

  double get scale => _scale;

  /// 外层滚动/翻页是否要让位给内层平移
  bool get lockOuterScroll =>
      _phase == GesturePhase.scaling ||
      (_phase == GesturePhase.panningInside);

  void onScaleStart(ScaleStartDetails d) {
    _phase = d.pointerCount >= 2 ? GesturePhase.scaling : _phase;
    notifyListeners();
  }

  void onScaleUpdate(ScaleUpdateDetails d, {required Size imageSize, required Size viewSize}) {
    _scale = d.scale.clamp(1.0, 5.0);
    if (_scale > 1.001) {
      _atEdge = _computeAtEdge(d.focalPointDelta, imageSize, viewSize);
      _phase = _atEdge ? GesturePhase.panningAtEdge : GesturePhase.panningInside;
    } else {
      _phase = GesturePhase.idle;
    }
    notifyListeners();
  }

  void onScaleEnd(ScaleEndDetails d) {
    _scale = _scale < 1.05 ? 1.0 : _scale;   // 吸附：接近 1 就还原
    _phase = _scale > 1.0 ? GesturePhase.panningInside : GesturePhase.idle;
    notifyListeners();
  }

  void toggleZoom() {
    _scale = _scale > 1.05 ? 1.0 : 2.0;
    _phase = _scale > 1.0 ? GesturePhase.panningInside : GesturePhase.idle;
    notifyListeners();
  }

  void resetZoom() { _scale = 1.0; _phase = GesturePhase.idle; notifyListeners(); }

  /// 图片是否已平移到边缘（边缘处应把拖动权交还外层滚动）
  bool _computeAtEdge(Offset delta, Size imageSize, Size viewSize) {
    final scaledW = imageSize.width * _scale;
    final scaledH = imageSize.height * _scale;
    final overflowX = (scaledW - viewSize.width) / 2;
    final overflowY = (scaledH - viewSize.height) / 2;
    if (overflowX <= 0 && overflowY <= 0) return true;
    // 到达边缘时 delta 方向的溢出量为 0
    return overflowY <= 0 || delta.dy.abs() < 0.5;
  }
}
```

**单击 / 双击仲裁**（在 `ReaderController` 内）：

```dart
void handleSingleTap(Offset pos, BuildContext ctx) {
  final size = MediaQuery.sizeOf(ctx);
  final x = pos.dx;

  // 长图模式：中间区域唤出菜单，左右仍有 25% 可点击翻页
  final leftZone  = size.width * settings.tapZoneLeft;    // 默认 0.25
  final rightZone = size.width * (1 - settings.tapZoneRight);

  _tapTimer?.cancel();
  _tapTimer = Timer(const Duration(milliseconds: 220), () {
    if (x < leftZone) {
      _goPrevChapterOrPage();
    } else if (x > rightZone) {
      _goNextChapterOrPage();
    } else {
      toggleMenu();
    }
  });
}

void toggleZoom(BuildContext ctx) {
  _tapTimer?.cancel();     // ★ 关键：双击必须取消挂起的单击
  _arbiter.toggleZoom();
}
```

## 4.4 TXT 分页锚点（改字号后位置不丢）

```dart
/// 用"字符偏移"而不是"页号"作为锚点
class TextAnchor {
  final int charOffset;      // 全书字符偏移
  final double ratioInPage;  // 页内可见比例（滚动位置）
}

/// 重新分页后找出包含该字符偏移的页
int pageContainingChar(List<int> pageStartOffsets, int charOffset) {
  int lo = 0, hi = pageStartOffsets.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (pageStartOffsets[mid] <= charOffset) { lo = mid; } else { hi = mid - 1; }
  }
  return lo;
}
```

## 4.5 图片尺寸嗅探（`lib/core/image_header.dart`）

```dart
class ImageHeaderParser {
  static ImageDimension? tryParse(Uint8List b) {
    if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50) {
      return ImageDimension(_be32(b, 16), _be32(b, 20), 'image/png');   // IHDR
    }
    if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) return _jpeg(b);
    if (b.length >= 30 && _ascii(b, 0, 4) == 'RIFF' && _ascii(b, 8, 4) == 'WEBP') return _webp(b);
    if (b.length >= 10 && _ascii(b, 0, 3) == 'GIF') {
      return ImageDimension(_le16(b, 6), _le16(b, 8), 'image/gif');
    }
    return null;
  }

  /// JPEG 必须遍历 marker 找 SOF，尺寸不在固定偏移
  static ImageDimension? _jpeg(Uint8List b) {
    int i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) { i++; continue; }
      final marker = b[i + 1];
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2; continue;
      }
      if (marker == 0xDA) return null;                    // 进入扫描数据
      final segLen = _be16(b, i + 2);
      final isSof = marker >= 0xC0 && marker <= 0xCF &&
                    marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
      if (isSof) return ImageDimension(_be16(b, i + 7), _be16(b, i + 5), 'image/jpeg');
      i += 2 + segLen;
    }
    return null;   // 头部不够长 → 调用方多解一点再试
  }
}
```

## 4.6 自然排序（`lib/core/natural_sort.dart`）

```dart
class NaturalComparator {
  static int compare(String a, String b) {
    int i = 0, j = 0;
    while (i < a.length && j < b.length) {
      final ca = a.codeUnitAt(i), cb = b.codeUnitAt(j);
      if (_isDigit(ca) && _isDigit(cb)) {
        int si = i, sj = j;
        while (i < a.length && _isDigit(a.codeUnitAt(i))) i++;
        while (j < b.length && _isDigit(b.codeUnitAt(j))) j++;
        final na = a.substring(si, i), nb = b.substring(sj, j);
        // ★ 去掉前导零后先比长度再比字典序：避免转 int 溢出
        final ta = na.replaceFirst(RegExp(r'^0+(?=\d)'), '');
        final tb = nb.replaceFirst(RegExp(r'^0+(?=\d)'), '');
        if (ta.length != tb.length) return ta.length - tb.length;
        final c = ta.compareTo(tb);
        if (c != 0) return c;
        if (na.length != nb.length) return na.length - nb.length;  // '1' < '01'
      } else {
        final c = ca.compareTo(cb);
        if (c != 0) return c;
        i++; j++;
      }
    }
    return (a.length - i) - (b.length - j);
  }

  /// ★ 逐段比较路径，否则 '第1话/10.jpg' 与 '第10话/1.jpg' 会错位
  static int comparePath(String a, String b) {
    final pa = a.split('/'), pb = b.split('/');
    for (int k = 0; k < math.min(pa.length, pb.length); k++) {
      final c = compare(pa[k], pb[k]);
      if (c != 0) return c;
    }
    return pa.length - pb.length;
  }
}
```

---

# 第 5 部分：难点、优化、第三方库、合规风险

## 5.1 难点清单（按风险排序）

| # | 难点 | 为什么难 | 对策 |
|---|---|---|---|
| 1 | **超长图单页解码** | Flutter 只能整体解码，长条超过 GPU 最大纹理（4096/8192/16384）就失败 | L1 限宽解码 + L2 平台 `BitmapRegionDecoder` 瓦片化（§3.2.4） |
| 2 | **缩放与滚动的边界交接** | `InteractiveViewer` 会吃掉平移手势，手感容易"卡住" | 仲裁状态机 + `_panAtEdge` 时把权交还外层（§3.4） |
| 3 | **进度精度与性能** | 滚动回调每帧触发，`setState` 整树会掉帧 | 进度用独立 `ValueNotifier`，与列表解耦（§3.3.1） |
| 4 | **`aspectRatio` 未知时的长页总高漂移** | 未知比例的页先按兜底比例排，真解码后高度变化 → 位置跳变 | 解码后回填比例 + **锚点重定位**（§3.2.1、§3.3.3） |
| 5 | **rar / 7z** | 专有算法，无成熟纯 Dart 实现 | 原生桥 / 引导转换（§2.4） |
| 6 | **GBK / GB2312 编码** | Dart 不自带 GBK 解码表 | `fast_gbk`（纯 Dart）或 `charset_converter`（平台） |
| 7 | **SAF 的 `content://` 随机访问** | 不是文件路径，无法 seek | `openFileDescriptor` 拿 fd + ffi `pread`（§2.10） |
| 8 | **网盘直链的 Range 支持不稳定** | 一次性签名、限流、Server 不支持 206 | 运行时探测 + 路径 A 兜底（§2.12） |
| 9 | **密码压缩包** | zip AES 支持弱，rar/7z 加密必须原生 | 统一 `NeedPassword` 返回值协议（§2.1） |
| 10 | **zip bomb / 恶意包** | 单个条目解压后可达数百 GB | 单条目输出上限 + 条目数上限 + 解压比告警 |

## 5.2 性能优化清单

### 内存

```
1) 三层缓存，各自独立限额：
   - Flutter ImageCache：24 张 / 64MB（默认 100 张 / 100MB 太宽松）
   - PageImageCache（自己的）：16 项 / 64MB
   - ArchiveEntryCache（自己的）：16 项 / 64MB
2) 解码时一定带 cacheWidth：
   Image.memory(bytes, cacheWidth: (screenWidth * devicePixelRatio).round())
   ★ 这是省内存最有效的一招：1080 宽的图在 1080p 屏上不必以 3000 宽解码
3) 长图模式禁止 cacheHeight（会破坏比例），只限宽
4) 滚动窗口外的页主动 evict：
   imageCache.evict(provider); 或直接让 PageImageCache LRU 淘汰
5) 离屏时（push 到其他页面）暂停预取、清空预取队列
```

### CPU / 帧率

```
1) inflate、XML 解析、正则分章 → 放后台 isolate（Isolate.run）
2) 解压并发 ≤ 2，避免抢主线程时间片
3) 列表项用 const / RepaintBoundary 隔离：
   RepaintBoundary(child: PageImage(...))  ← 一页重绘不牵连其他页
4) 进度条与列表分离通知（§3.3.1）
5) Webtoon 长条渲染时给 Image 加 filterQuality: FilterQuality.low
   （缩小渲染时 medium/high 会增加 GPU 成本但视觉提升有限）
6) 避免 build 里做重复计算：PageMetrics 缓存，只在 viewportWidth 变化时重建
```

### I/O

```
1) 中央目录只读一次，缓存在内存（条目列表）
2) 相邻条目在 zip 里物理相邻 → 读一个条目时顺手预读下一块的 1MB（可选优化）
3) 页字节可选落盘（仅网络源有意义），键 = sourceId+entryPath+size+mtime
4) 导入时的尺寸嗅探只解前 192KB；1 万页的包 ≈ 读 2GB 上限，实际远小于此
   （因为多数图 < 192KB，只解一次压缩数据）
```

## 5.3 第三方库推荐（分层）

### 起步最小集（本仓库已用）

```yaml
provider: ^6.1.2            # 状态管理
file_picker: ^8.1.2         # SAF 文件/文件夹选择
shared_preferences: ^2.3.2  # 书架元数据 + 进度 + 设置
path_provider: ^2.1.4       # 缓存/数据目录
archive: ^3.6.1             # 仅借用 DEFLATE（Inflate）
```

### 推荐补齐（按优先级）

| 库 | 用途 | 备注 |
|---|---|---|
| `pdfx` | PDF 渲染 | MIT；必须 `close()` |
| `xml` | DOCX 解析 | 纯 Dart |
| `html` | 网页正文解析 | 纯 Dart |
| `dio` | 网络 + Range + CancelToken | 优于 `http` |
| `fast_gbk` | GBK/GB18030 纯 Dart 解码 | 无平台依赖 |
| `charset_converter` | 平台编码探测/转换 | Android `CharsetDetector` |
| `extended_image` | 图片手势 + 自定义 ImageProvider | 想省手势代码时 |
| `flutter_cache_manager` | 网络图磁盘缓存 | 配 `cached_network_image` |
| `drift` | 书籍多了之后的本地数据库 | 支持复杂查询/迁移 |
| `flutter_secure_storage` | 记住压缩包密码、网盘 token | Keychain/Keystore |
| `flutter_inappwebview` | **仅网页导入兜底** | 不要用于渲染内容 |
| `webdav_client` | WebDAV 网盘 | 零合规风险，首推 |
| `photo_view` | 更强的图片缩放（含边缘拖拽） | 可替代 `InteractiveViewer` |
| `visibility_detector` | 精确判断项是否可见 | 精细预取控制 |
| `isolate` / `flutter_isolate` | 后台解析 | 大文件导入 |

### 明确不推荐 / 需谨慎

| 库 | 原因 |
|---|---|
| `syncfusion_flutter_pdfviewer` | **商业许可**，开源项目需评估授权 |
| `docx_template` | 定位是"按模板生成"，做提取不顺手 |
| `cached_network_image` 单独用于压缩包内图片 | 它只解决网络缓存，覆盖不了"字节来自压缩包"的场景 |
| 任何"网盘解析"第三方 SDK | 见 §5.4 |

## 5.4 合规风险（必须写进产品与文档）

### 网盘

| 风险 | 说明 | 建议 |
|---|---|---|
| **违反 ToS** | 非官方接口（Cookie 驱动）通常被明确禁止，可能导致账号封禁 | 优先官方 OAuth API；Cookie 方案标注"实验性、自担风险"、默认关闭 |
| **数据隐私** | 第三方"解析服务"会拿到你的分享链接甚至 Cookie | 不做用户鉴权中转；默认关闭；明确告知 |
| **版权内容** | 分享链接常指向受版权保护的漫画/影视 | 只做"用户自己的文件"通道；不提供内容搜索/聚合/推荐 |
| **接口变更** | 官方 API 版本升级会破坏兼容 | Provider 内部版本化封装，接口层做能力探测与降级 |
| **限速与计费** | 非会员下载带宽受限，可能触发风控 | 提供进度、断点续传、限流提示；不承诺速度 |

### 网页抓取

| 风险 | 说明 | 建议 |
|---|---|---|
| 违反 `robots.txt` / 站点条款 | 批量抓取可能被禁止 | 只做"用户输入单个 URL"的按需抓取，不做爬虫批量站群 |
| 反爬与法律 | 绕过 Cloudflare 等技术措施存在法律风险 | **不实现反爬绕过**；403 时提示"该站点不支持导入" |
| 版权 | 抓取正文/图片可能构成侵权 | 仅用于个人阅读；不提供分享/导出/再分发能力 |
| 隐私 | 抓取会把 URL 暴露给站点 | 可提供"无追踪"提示；不注入广告/统计 |

### 压缩包与文件

| 风险 | 说明 | 建议 |
|---|---|---|
| zip bomb | 单条目解压可达数百 GB | 单条目输出上限（默认 64MB）+ 解压比告警 |
| 路径穿越 | `../../etc/passwd` 式条目名 | **本设计不解压到磁盘，天然免疫**；若将来落盘，必须校验规范化路径 |
| 恶意图片 | 畸形图片触发解码器漏洞 | 依赖 Flutter/Skia 的加固；限制单图尺寸 |

### 分区存储

| 风险 | 说明 | 建议 |
|---|---|---|
| `MANAGE_EXTERNAL_STORAGE` | Google Play 严格审核，非核心功能易被拒 | **不用**；走 SAF 与 app 私有目录 |
| 权限过度申请 | 只读漫画不需要 `READ_MEDIA_IMAGES`（SAF 已授权） | 优先 SAF，按需申请，拒绝后优雅降级 |

## 5.5 无法直接实现的功能与替代方案

| 需求 | 能否直接实现 | 替代方案 |
|---|---|---|
| rar / 7z 解压 | ❌ 纯 Dart | 原生桥（junrar / libarchive / PLzmaSDK）；或引导转 zip |
| 旧版 `.doc` 文本提取 | ❌ 纯 Dart | 引导转换 / 平台 Intent / 服务端 LibreOffice / POI 桥接 |
| 超长图区域解码（瓦片） | ❌ Dart 层 | Android `BitmapRegionDecoder`、iOS `CGImage.cropping` 平台通道 |
| GBK / GB2312 解码 | ❌ Dart 标准库 | `fast_gbk`（纯 Dart）或 `charset_converter`（平台） |
| 全格式压缩包（含 xz/bz2） | ⚠️ 部分 | 原生桥统一兜底；明确列出支持的格式矩阵 |
| 夸克网盘稳定解析 | ❌ | WebDAV/局域网兜底；Cookie 方案标注实验性 |
| `content://` 随机访问 | ⚠️ 需原生 | fd + ffi `pread`；或退化为顺序读取 |
| 网页正文完美提取 | ⚠️ 启发式 | Readability + WebView 兜底 + **允许用户手动框选正文** |

## 5.6 推荐的实施阶段

| 阶段 | 内容 | 里程碑 |
|---|---|---|
| **P0（本仓库）** | 统一模型 + ZIP 按需读取 + 文件夹/TXT/散图导入 + 三种阅读模式 + 进度 + 手势 + 书架 | 能读 zip 漫画和 txt 小说 |
| **P1** | 图片头嗅探全覆盖、自然排序完善、封面提取、编码探测（BOM+UTF-8）、失败重试、预取策略 | 日常可用 |
| **P2** | PDF（pdfx）、DOCX（自研 XML）、网页（dio + html + Readability） | 文档能力补齐 |
| **P3** | 内存/CPU 调优、超长图瓦片化、drift 数据库、分类/收藏/搜索 | 大文件不卡不 OOM |
| **P4** | 网盘（先 WebDAV，再官方 OAuth 网盘）、远程 zip Range 策略、离线保存 | 来源扩展 |
| **P5** | rar/7z 原生桥、`.doc` 引导转换、iOS 打磨 | 格式完备 |

---

# 第 6 部分：起步实现（本仓库已落地的代码）

> **实现进度与差异说明（重要）**
>
> 本仓库已经按"最容易实现"的路径落地了一个可运行的最小闭环，
> 但在两处与上文设计有意不同，都以**代码为准**：
>
> 1. **状态管理用 Provider**（与 §1.4 结论一致）。
> 2. **加密压缩包**：检测得到、能弹密码框，但**纯 Dart 不做解密**。
>    `ZipArchiveSource.readEntry` 对加密条目直接给出"请先解压出未加密的 zip"
>    的明确错误，而不是假装校验密码。详见 README 的"关于加密压缩包的实测结论"。
> 3. **tar.gz / gz、rar / 7z、PDF / DOCX / 网页 / 网盘、GBK、超长图瓦片化**
>    均未实现，但在代码里都留了骨架与逐行接入指引。
> 4. **Document 会落盘成 document.json**（见 §1.5 的补充）：打开一本书是
>    "读一个 JSON"，而不是重新解析整个压缩包 —— 这是秒开的关键。

---

## 6.7 实机反馈后的三处关键修正（2026-06）

这三条都是**实测才暴露的问题**，值得单独记下来，因为它们各自推翻了我原先的一个"想当然"。

### 6.7.1 `BoxFit.fill` 会让长图变形 —— 这是设计疏漏

§3.2.5 里我写的是"长图模式用 `Image.memory(fit: BoxFit.fill)`，
因为高度已按比例算好，`fill` 不会变形"。**这句话只在测量值完全准确时成立。**

现实是：`aspectRatio` 来自导入时的头部嗅探，它可能失败、可能偏差，
也可能因为图片本身有 padding 而对不上。一旦有一丝误差，`fill` 就把它**放大成可见的拉伸**——
用户看到的就是"图片高度被压扁了"。

**结论**：长图模式应该用 **`BoxFit.cover`**。

| fit | 变形 | 页间缝隙 | 结论 |
|---|---|---|---|
| `fill` | ❌ 会拉伸变形 | ✅ 无 | **错的选择** |
| `contain` | ✅ 不变形 | ❌ 会留缝（破坏"一条长页"） | 只适合翻页模式 |
| **`cover`** | ✅ 不变形 | ✅ 无（误差那几像素被裁掉） | **✅ 正确选择** |

而且这引出一个更重要的设计原则：
**"测量值"不能是系统的单点真相，必须能被真实数据纠正。**
所以 `PageImage` 在真实解码后会回填准确的 `aspectRatio`，
`ReaderController` 用"页 + 页内比例"锚点保住滚动位置再重建度量 —— 见 §3.3.3。
这条自愈链路原本只是为"嗅探失败"准备的，现在成了常规路径。

### 6.7.2 DEFLATE 是流式的 —— `maxBytes` 省不了 CPU

§2.3 里我给的"只解前 N 字节"看起来完美，但**它省的是拷贝，不是解压**：

```dart
// 旧实现（本仓库实际写过的代码）
final comp = await src.read(dataStart, entry.compressedSize); // 读完整条压缩数据
final raw  = Inflate(comp, entry.uncompressedSize).getBytes(); // 解压整张图
return subView(raw, 0, need);                                  // 只取前 256KB
```

一张 5MB 的漫画页，为了读几十字节的图片头，解压了 5MB。
500 张图 = 解压几 GB —— 这就是"压缩包导入太慢"的真正原因。

**为什么不能只读压缩数据的固定比例？**
因为 deflate 的"压缩字节位置 → 输出字节位置"不是线性关系
（Huffman 编码 + 回溯引用），`compSize * need / uncompSize` 这种估算**不可靠**。

**正确做法：分级试探 + 校验。**

```
for step in [48KB, 160KB, 512KB]:
    comp = read(dataStart, min(step, compSize))
    try: raw = inflate(comp)        # 截断会抛异常
    except: continue                # 加大试探量
    if raw.length >= 32 and 首字节是已知图片签名:
        return raw[0:need]          # ✅ 命中就返回，只解压了几十 KB
return null                          # 全部失败 → 回退读整条
```

关键在**校验"首字节是已知图片签名"**：只有确实解出了图片头才算成功，
所以正确性丝毫不打折。绝大多数 JPEG/PNG 的尺寸在文件最前面，第一档就命中。

### 6.7.3 全量嗅探在大包上不可行 —— 改成"前段精确 + 全篇抽样"

即使有了 6.7.2 的优化，**逐张嗅探"每张图"这件事本身在大包上仍是 O(n) 次解压**。
1000 页的包，每次最少解 48KB，也是 48MB 的解压量 + 1000 次文件读取。

一个重要的认识：**虚拟长页只需要"每页的高度"，而高度只需要"统计上正确"。**

- 用户最先看到的是**前几十页** → 这些必须精确，否则一进去就是错位 + 跳动；
- 全篇的**中位比例**决定兜底高度是否合理 → 抽样几百页足够估计；
- 是否 Webtoon → 一个统计判断，抽样足够；
- 其余页 → 用中位比例兜底，**阅读时由 6.7.1 的自愈机制校正**。

于是策略变成：**前 120 页全测 + 全篇均匀抽样 240 页**（共约 360 次），
而不是 1000 次。图上万页时差距是数量级的。

> **代价要写进产品文案，不能藏着**：未抽到的页首次显示时高度是估计值，
> 滚过去可能有一次微调。这个 trade-off 换的是"大包秒开"。
> 少于约 360 页的包仍然全量精确测量。

### 6.7.4 并发嗅探的隐藏陷阱：`setPosition` + `read` 不是原子的

加了 `mapConcurrent(concurrency: 8)` 之后性能上去了，但引入了一个**静默的正确性 bug**：

```dart
await _raf.setPosition(offset);   // A 设好位置
                                  // ← B 在这里插进来 setPosition 了
return await _raf.read(actual);   // A 读到的是 B 偏移处的数据！
```

`RandomAccessFile` 没有"带偏移的读"原语，`setPosition + read` 必须成对执行。
所以 `FileByteSource` 内部加了一条 Future 链做互斥：

```dart
final previous = _lock;
final completer = Completer<void>();
_lock = completer.future;
await previous;                   // 排队
try { await _raf.setPosition(offset); return await _raf.read(actual); }
finally { completer.complete(); }
```

开销极小（真正耗时的是 DEFLATE 解压，那部分**仍然完全并发**）。
这个 bug 的表现是"图片头解析**随机**失败"，非常难查 ——
所以结论是：**任何并发 I/O 都要先问一句"这个 API 是不是有隐含的可变游标"。**

### 6.7.5 教训汇总

| 我原先的想法 | 现实 | 修正 |
|---|---|---|
| "高度已算好，`fill` 不会变形" | 测量值必有误差，`fill` 会把误差放大成变形 | 用 `cover`；并让测量值可被真实数据纠正 |
| "只解前 N 字节就省了成本" | DEFLATE 流式，仍要解压整条 | 分级试探解压 + 校验签名 |
| "每页都要精确测量" | 虚拟长页只需要统计正确 + 前段精确 | 前段精确 + 全篇抽样 + 自愈 |
| "并发读文件更快" | `setPosition+read` 非原子，会串位 | 读取互斥，只并发 CPU |
| "目录读不出来就返回空" | 用户只看到"没有内容"，完全无从排查 | 预检 + 分类错误 + 扩展名直方图 |


## 6.1 技术选择说明（"最容易实现"的具体取舍）

| 决策 | 选择 | 为什么这是最容易的 |
|---|---|---|
| 状态管理 | **Provider + ChangeNotifier** | 无代码生成、无额外概念；阅读器状态本就是可变控制器 |
| ZIP 读取 | **自研中央目录解析** | `archive` 的 `decodeBytes` 会把整包读进内存，直接违反约束；自己写只多约 200 行 |
| DEFLATE | **借 `archive` 的 `Inflate`** | 不重复实现压缩算法，同时保留"只读需要的字节"的能力 |
| 图片渲染 | **Flutter 内置 `Image.memory`** | 零依赖；`cacheWidth` 已经能解决绝大多数内存问题 |
| 手势缩放 | **内置 `InteractiveViewer` + 自研仲裁** | 不用引第三方也能达到可用手感 |
| 持久化 | **`shared_preferences` + JSON** | 起步不需要数据库；书籍上百本时再迁移 drift |
| 导入策略 | **落盘到 app 私有目录** | `file_picker` 在 Android 给的是临时缓存路径，必须复制才能长期使用；复制到私有目录同时解决"离线阅读" |

## 6.2 已实现的功能

- ✅ 导入**文件夹**（递归、自然排序、多章、图片/文本判定）
- ✅ 导入 **ZIP 压缩包**（**只读中央目录，按需解压单条目**）
- ✅ 导入 **TXT**（BOM + UTF-8 校验检测编码、正则分章、按段分页）
- ✅ 导入**散图**（多选图片直接成书）
- ✅ 三种阅读模式：水平滑动拖拽 / 水平点击 / 垂直虚拟长页
- ✅ 虚拟长页：`aspectRatio` 预计算度量、`SliverList` 懒构建、无间隙拼接
- ✅ 进度：百分比计算、进度条拖动跳转、**按模式分别记忆**、退出保存
- ✅ 手势：单击分区（左/中/右）、双击缩放、双指缩放、缩放与滚动仲裁
- ✅ 书架：最近阅读、收藏、搜索、删除、重命名
- ✅ 设置：阅读模式、亮度、背景色（日间/夜间/羊皮纸）、字号、行距
- ✅ 内存：三层 LRU + `ImageCache` 收紧 + `cacheWidth` 限宽解码
- ✅ 图片尺寸嗅探（PNG/JPEG/WebP/GIF/BMP 头部解析）→ 长页高度无需解码像素

## 6.3 留了骨架、待接入的功能（含接入位置）

| 功能 | 文件 | 接入方式 |
|---|---|---|
| PDF | `lib/importers/pdf_importer.dart` | 加 `pdfx`，实现 `PdfEngine.open/pageCount/pageSize/render` |
| DOCX | `lib/importers/docx_importer.dart` | 加 `xml`，解析 `word/document.xml` + `document.xml.rels` |
| 网页 | `lib/importers/web_importer.dart` | 加 `dio` + `html`，实现 Readability |
| 网盘 | `lib/importers/netdisk/netdisk_provider.dart` | 先实现 `WebDavProvider` |
| rar / 7z | `lib/data/archive/native_archive_source.dart` | 加平台通道 + LRU 临时文件 |
| GBK 编码 | `lib/core/charset.dart` | 加 `fast_gbk` 或 `charset_converter` |
| 超长图瓦片 | `lib/ui/reader/widgets/page_image.dart` | 加平台通道 `BitmapRegionDecoder` |

## 6.4 运行方式

```bash
# 1) 安装 Flutter（>= 3.19）
# 2) 在项目目录补齐平台目录（pubspec / lib 已经写好，不会被覆盖）
cd flutter-comic-reader
flutter create . --project-name book_reader --platforms=android,ios

# 3) 拉依赖并运行
flutter pub get
flutter run
```

> 若 `flutter create .` 覆盖了 `pubspec.yaml`，请从 `pubspec.yaml.bak`（或 git）恢复依赖段。
> **建议先 `cp pubspec.yaml pubspec.yaml.bak` 再执行 `flutter create .`。**

首次运行后：点右上角 `+` → "选择文件夹"（选一个装图片的目录）或"选择压缩包"（选一个 zip）→ 进入阅读器。

## 6.5 验证清单（装上 Flutter 后按此自测）

- [ ] 导入一个含 1000 张图的 zip：**内存峰值 < 300MB**，滚动不卡
- [ ] 该 zip 打开时**不产生任何解压目录**（检查 `cacheDir` 无大文件）
- [ ] PDF / 大 TXT：打开耗时 < 2s（只建索引）
- [ ] 长图模式：进度条百分比与视觉位置一致，拖动跳转准确
- [ ] 横竖屏旋转：停在原页原位（锚点算法生效）
- [ ] 双击放大到 2x，拖到图片边缘后能继续滚动到下一页
- [ ] 三种模式切换：位置不丢
- [ ] 杀掉 App 重开：恢复上次进度，且每种模式各自的进度都对
- [ ] 导入 GBK 的 TXT：不乱码
- [ ] 恶意 zip（单条目 10GB 声明）：被上限拦截并给出明确错误，不 OOM

## 6.6 已知限制（诚实版）

1. **rar / 7z 未实现** —— 只识别并给出"请转为 zip"的提示（符合"无法纯 Dart 实现"的事实）。
2. **tar.gz 未实现** —— 需要顺序解压，按 §2.5 的方案 B 落地。
3. **GBK / GB2312 未实现** —— 起步只支持 UTF-8 / UTF-16 / UTF-32（含 BOM），非 UTF-8 会按 UTF-8 容错解码并提示。
4. **超长图瓦片化解码未实现** —— 起步用"限宽解码"，超过 GPU 纹理上限的极端长条会渲染失败。
5. **DOCX / PDF / 网页 / 网盘未实现** —— 已留导入器骨架与接口位置。
6. **未在本机编译验证** —— 交付环境无 Flutter SDK；代码按 Flutter 3.19+ / Dart 3.x 编写，注释里标注了需要复核的 API 点。
