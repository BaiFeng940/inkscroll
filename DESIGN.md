# inkScroll 架构与设计

> 本文按 **0.15.0 的实际实现**撰写（2026-11 重写，替换旧设计期文档）。
> 所有机制都在代码里可核对，标注了对应文件；行号会漂移，以文件为准。

## 0. 定位与三条铁律

inkScroll 是本地与网盘（WebDAV）双来源的漫画 / 文档阅读器。性能设计围绕三条硬约束：

1. **不解压整个压缩包** —— 自研 ZIP 引擎按需解压；
2. **不合成超大 Bitmap** —— 解码宽度钳制到屏幕物理宽；
3. **不一次性加载所有图片** —— 双层缓存 + 只构建可见项。

推导出的技术选型：状态管理用 **Provider + ChangeNotifier**（零代码生成、概念最少）；
ZIP / WebDAV / PDF / SAF **自研或走系统 API**，不引 pdfx / pdfium / url_launcher 这类重依赖
（直接依赖仅 9 个 Flutter 包，见 `pubspec.yaml`）。

## 1. 分层架构

```
lib/
├── ui/            书架 · 设置 · 网盘浏览器 · 阅读器
│   └── reader/    reader_screen · gesture_arbiter · widgets/{page_image,progress_bar,text_page_view}
├── state/         app_state.dart —— 全局状态：书架 CRUD、导入编排、文档装载、封面队列、缓存统计、更新检查
├── reader/        document.dart（模型+度量）· reader_controller.dart（状态机）
│                  page_cache.dart · document_codec.dart · cover_generator.dart
│                  {webdav_page,webdav_archive,pdf}_page_resolver.dart
├── data/          byte_store.dart（私有目录布局）· prefs_store.dart · archive_extractor.dart
│                  archive/（zip/tar 引擎 + ZipCrypto）· webdav/（自研客户端）· pdf/pdf_native.dart
│                  models/{book_meta,reader_settings}.dart · display_channel.dart
├── importers/     import_router.dart（魔数优先）+ 13 个导入器 · netdisk/（抽象，预留）
└── core/          magic.dart · image_header.dart · charset.dart · natural_sort.dart
                   errors.dart（sealed AppError）· lru_cache.dart
android/           MainActivity.kt · SafFolderPlugin.kt · RefreshRateController.kt · PdfPlugin.kt
```

原生侧只有 4 个自研 Kotlin 插件（MethodChannel：`inkscroll/saf`、`inkscroll/display`、
`inkscroll/pdf`），零第三方插件依赖。

## 2. 数据模型：引用与字节分离

`lib/reader/document.dart`。铁律：**模型里绝不出现字节**，只描述「内容在哪」。

- `sealed ContentRef` 六种：`LooseFileRef`（文件夹/散图）、`PdfPageRef`（路径+页码，
  按需原生渲染）、`ArchiveEntryRef`（本地包内条目）、`WebDavRef`（网盘直链）、
  `WebDavArchiveRef`（网盘包内条目，Range 读）、`InlineRef`（极少用的内存内容）。
- `PageContent` 三态：`ImageContent` / `TextPageContent`（含全书字符锚点 `pageStartCharOffset`）/
  `PdfPageContent`（pt 尺寸）。`PageNode.aspectRatio` 是虚拟长页的几何基石。
- `Document`：扁平 `pages: Map<String, PageNode>` + 章节 `chapters`。
  `pagesInOrder` 带**脏标记缓存**（唯一变异入口是 `applyAspect` 回填真实比例）。
- 序列化 `document_codec.dart`：version 1 tagged-union JSON，5000 页约 1-2MB；
  写入 tmp + rename（rename 失败退回删旧再改名），打开 = 一次 JSON 解析而非 1~3 秒重扫。

### 度量（虚拟长页几何）

`PageLayoutMetrics.build` 用嗅探到的 aspectRatio 前缀和算出全书几何——
不加载任何图片即可定位 / 跳转 / 显示百分比。解码完成后经 `applyAspect` 回填真实比例
（偏差 <0.5% 忽略），度量在帧末 + 300ms 防抖合并重建。

## 3. 阅读状态机

`lib/reader/reader_controller.dart`。

- **两种模式**：`horizontal`（PageView，拖动 + 点击分区同时可用）与
  `verticalContinuous`（CustomScrollView + SliverList，页高由真实比例决定，无缝拼接）。
  打开书时按「本书记忆 → 全局默认 → 内容 hint 自动判断」选模式。
- **进度与渲染解耦**：进度走独立的 `progressRatio / progressLabel` 两个 ValueNotifier，
  只在页码或万分位百分比变化时写入（120Hz 下把每帧 120 次通知压到接近 0）；
  ChangeNotifier 只在文档结构 / 菜单 / 模式变化时广播。
- **保存**：400ms 防抖 + dispose 强制保存；每模式一条进度（锚点 = 页码 + 页内比例）。
- **跳转**：长页的 maxScrollExtent 是估算值，`jumpToRatioConverging` 最多 3 轮收敛（误差 <0.5%）。
- **手势**（`gesture_arbiter.dart` + UI 层 `_ZoomHost`）：
  - 时序常量唯一来源 `ReaderTiming`：单击延迟 = 双击窗口 = 260ms（两窗口错位会让双击不可达）；
  - 双击缩放以 `TransformationController` 的真实矩阵为唯一事实源：2.5 倍动画放大到落点，
    再双击动画复位；垂直长页模式整体禁用（双击在无缝长页上没有意义且会锁滚动）；
  - `boundaryMargin: zero` 的真实边界下，缩放态平移到水平边缘自动把拖动权交还翻页。

## 4. 字节供给：PageByteResolver

统一接口 `imageBytes / peekBytes / dispose`（`page_cache.dart`），五个实现：

| 实现 | 缓存 | 预取 | 说明 |
|---|---|---|---|
| ArchivePageByteResolver | LRU 32 项/128MB | 靠预解压 | 优先读 `extracted/`，缺失回退 zip 单条目 |
| FilePageByteResolver | 同上 | 无 | 文件夹/散图直读 |
| PdfPageResolver | 12 项/96MB | **前后各 2 页** | 系统 PdfRenderer 渲染，宽 1600（原生上限 2048） |
| WebDavPageByteResolver | 24 项/96MB | radius=2 | 每页落盘 `netcache/`，tmp+rename |
| WebDavArchivePageResolver | 24 项/96MB | radius=2 | Range 读网盘 zip，双 32 位哈希命名 |

同页并发请求用 `_inflight` 合并；注意 `_load(...).whenComplete(...)` 代理 Future 在真机
会挂死（踩过两次，相关文件都有长注释）。

## 5. ZIP 引擎（自研）

`lib/data/archive/zip_archive_source.dart` + `zip_crypto.dart`。

- 打开 = 倒扫 EOCD（22+65535B）→ Zip64 → 中央目录一次读回（4 万条目约 1.8MB）。
- 条目读取分级试探：48/160/512KB 解压 + 图片签名校验，命中即返回，避免为读图片头解压整图；
  最坏回退全量。护栏：单条目 64MB、总量 2GB、5 万条目（zip 炸弹防线）。
- ZipCrypto（PKWARE 传统加密）纯 Dart 解密；AES（method 99）明确拒绝并给转换指引。
- 路径穿越防护：条目名规范化（`_sanitizePath`）。

## 6. WebDAV 客户端（自研）

`lib/data/webdav/webdav_client.dart`。自研理由：需要在 GET 上做 Range 嗅探
（只下前 64KB 拿图片尺寸）、自定义超时 / 重试 / 并发。

- PROPFIND 兼容：不带体（123云盘 / fnOS 拒绝带体）、「207 + 空列表」按可疑退避重试 3 次
  （该坑导致过每次扫描书本数随机，修复见 `webdav_folder_importer._listWithRetry`）；
- 302 → CDN：`package:http` 跟随后 Range 头保留，123云盘实测 206 精确返回；
- `WebDavByteSource` 把随机访问架在 Range 上（开包 1~2 次请求，每页 2 次，与包大小无关）；
- 连接池每主机 16，安全选项：明文 HTTP 可用（家用 NAS 场景）、「允许自签名」默认关。

## 7. 导入管线

`import_router.dart` 按**魔数**（读头 8KB）路由，不信扩展名；来源五类
`file / files / folder / url / webdav`。

- 并发策略：嗅探 8 路、WebDAV 扫描 5 路 + 嵌套 4 路、批量导入 worker 池 8 本/批、
  每主机连接 16；实测 174 本 / 149 秒（0.86 秒/本）。
- 批量导入持有 CPU + Wi-Fi 唤醒锁（`import_lock.dart`，原生 30 分钟兜底）；
  防重入标志 `_importing` 在 finally 复位（0.14.x 曾漏复位导致二次导入必失败）。
- 判重：网盘按（连接 id, 规范化 URL）覆盖文件夹与压缩包两类来源；
  本地指纹函数已删（0.15.0 清理死代码）。
- 大库书架写盘：批量期间只累积，结束一次 `upsertBooks`（逐本 upsert 是 O(n²) JSON 编解码）。

## 8. 存储布局

`byte_store.dart`：`<appSupport>/books/<bookId>/` 下
`archive.<ext>`（私有副本）/ `content/`（文件夹内容）/ `extracted/`（后台解压产物，可清）/
`netcache/`（网盘页缓存，可清）/ `document.json` / `cover.png`。根目录 `.nomedia` 防相册扫描。

元数据存 SharedPreferences（`prefs_store.dart`）：`books.v1` 整库 JSON、`progress.<bookId>.<mode>`、
`settings.v1` 等。容量到几百本书时计划迁 drift/sqlite（迁移路径已在注释预留，接口只换本文件）。

## 9. 高刷新率两层适配

`RefreshRateController.kt` + `MainActivity.kt`。国产 ROM 对不主动声明的应用一律给 60Hz
（vivo 实测 `requestedFrameRate: 0.00 Hz / NoPreference`）：

1. **窗口显示模式**：onCreate 即设 `preferredDisplayModeId`（锁定分辨率选刷新率档，
   避免连带降分辨率），onResume / onWindowFocusChanged 反复补设；
2. **Surface 声明**：首帧渲染后 `Surface.setFrameRate(120, FIXED_SOURCE)`（遍历找 FlutterSurfaceView）；
3. **档位交给用户**：standard120 / max / system 三档（`ReaderSettings.highRefreshMode`），
   Dart 侧经 `inkscroll/display` 通道下发，启动与应用时生效。

## 10. 原生插件（4 个自研 Kotlin）

| 插件 | 通道 | 职责 |
|---|---|---|
| SafFolderPlugin | inkscroll/saf | SAF 文件夹选择 + 直读复制、单文件 `openUrl`、导入唤醒锁（Android 11+ 的 file_picker 目录缺陷见文件头注释） |
| RefreshRateController | inkscroll/display | 高刷两层 + 常亮 FLAG_KEEP_SCREEN_ON |
| PdfPlugin | inkscroll/pdf | 系统 PdfRenderer 打开 / 按页渲染 / 关闭；密码 PDF 独立错误码 |
| MainActivity | — | 插件装配 + 首帧监听 + 双重补设帧率 |

## 11. 错误体系

`core/errors.dart`：`sealed AppError` + `ErrorAction` 枚举——错误 → UI 按钮语义的唯一出口。
12 个子类覆盖压缩包（不是压缩包 / 密码错 / 不支持算法 / zip 炸弹 / 损坏）与网络
（连不上 / 认证 / HTTP / 非 WebDAV / 证书）。`pdf_native` 把密码 PDF 映射为明确文案。

## 12. 测试策略

`flutter test`：107 个用例（3 个手动真网盘用例默认跳过，需环境变量三元组）。
分层现状：**纯函数层覆盖优秀**（自然排序 / 魔数 / 图片头 / zip 中央目录 / WebDAV 解析 /
合集合并），编排层（app_state、archive_extractor、本地导入器）是已知缺口——批次二补
document.json 往返、解压管线与状态机可 fake 化单测。`flutter analyze` 保持 0 issue。

## 13. 发布

- 版本号规则：新功能 +次版本、只修 bug +修订、主版本仅在用户明确要求时升；
  `versionCode = 主×1000000 + 次×1000 + 修订`。单一真相来源 `app_version.dart`，
  `test/app_version_test.dart` 防漂移（同时扫 UI 硬编码版本号）。
- CI（`.github/workflows/build.yml`）：打 tag 触发 analyze → test → 三 ABI 构建 → Release；
  版本号从 pubspec 现读。
- 应用内更新：GitCode 国内镜像优先（数组接口）→ GitHub 兜底；一天一查，仅有更新才弹窗。
- 仓库行尾统一 LF（`.gitattributes`）；Gradle 发行包走腾讯镜像、Maven 走阿里云（国内构建
  快一个数量级，海外可还原官方源）。Flutter 引擎构件（download.flutter.io）在本机被限速时，
  可从 storage.flutter-io.cn 预取 jar+pom 建本地 maven 仓库插到镜像链最前。

## 14. 已知取舍（诚实清单）

| 取舍 | 现状 | 计划 |
|---|---|---|
| 网盘密码 XOR+Base64 混淆存 SharedPreferences | 作者自知非加密 | 迁 flutter_secure_storage（Keystore） |
| 密码 PDF 不支持（系统渲染器限制） | 明确报错 | 无计划，提示用户解密 |
| GBK 文本仅提示不转码 | 中文小说场景硬伤 | 接 fast_gbk（pubspec 注释位已留） |
| file_picker 单文件在 Android 11+ 返回 path=null | 压缩包/PDF 单文件导入不可用（文件夹走 SAF 不受影响） | 单文件改走 SAF 通道或升级插件 |
| rar/7z、DOCX、网页正文 | 骨架 + 接入指引 | 按需启用 |
| SharedPreferences 存整库 JSON | 几百本内够用 | 迁 drift/sqlite |
| UI 硬编码深色 chrome / 无封面 Hero 转场 | 0.15.0 已做令牌化前的动效批次 | 批次二做 ReaderChromeTheme 令牌层 |
