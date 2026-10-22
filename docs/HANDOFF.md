# inkScroll 交接文档

> 面向"新开一个会话继续开发"的场景。包含环境、架构、已完成、**待做的两项（含设计）**、
> 踩过的坑、以及可直接粘贴的提示词。
> 当前版本：**0.14.1**（2026-10）

---

## 1. 项目速览

| 项 | 值 |
|---|---|
| 应用 | inkScroll —— 本地与网盘（WebDAV）漫画 / 文档阅读器 |
| 技术栈 | Flutter 3.47.7 / Dart 3.13.5；Provider + ChangeNotifier |
| 包名 | `com.inkscroll.reader` |
| Android | SDK 36、NDK 28.2、Gradle 9.3.1、minSdk 由 Flutter 默认 |
| 权威工作区 | `D:\DSH Desktop\work\flutter-comic-reader`（git 仓库） |
| 构建副本 | `C:\Users\Administrator\develop\book_reader`（**Gradle 不接受含空格的路径，必须在副本里构建**） |
| GitHub | `BaiFeng940/inkscroll`（公开，MIT） |
| GitCode 镜像 | `BaiFeng940/inkscroll` |
| 官网 | https://baifeng940.github.io/inkscroll/ |
| 帮助中心 | https://baifeng940.github.io/inkscroll/help/ （28 篇） |
| 发布签名 | RSA 4096 / 10000 天，`CN=inkScroll`；密钥在 `C:\Users\Administrator\develop\keys\`（**仓库外，务必备份**） |

### 硬性设计约束（不可违反）

1. **不得**把所有图片合成超大 Bitmap
2. **不得**一次性解压整个压缩包
3. **不得**一次性加载所有图片
4. 不要用 WebView 套一切（仅网页导入用）
5. 不要假设网盘分享链接一定能解析

---

## 2. 构建与发布流程

### 2.1 环境变量（每个 pwsh 调用都要重设）

```powershell
$env:Path = "C:\Users\Administrator\develop\flutter\bin;" + $env:Path
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:JAVA_HOME = "D:\Android Studio\jbr"
```

常用绝对路径：
- dart：`C:\Users\Administrator\develop\flutter\bin\cache\dart-sdk\bin\dart.exe`
- adb：`$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe`
- git：`C:\Program Files\Git\cmd\git.exe`
- python（带 Pillow）：`D:\DSH Desktop\resources\office-runtime\primary-runtime\dependencies\python\python.exe`

### 2.2 构建

```powershell
# 1) 同步到构建副本（不能带空格路径）
robocopy "$proj\lib"   "$build\lib"   /MIR /NFL /NDL /NJH /NJS /NP
robocopy "$proj\android" "$build\android" /MIR /XD build .gradle .cxx /NFL /NDL /NJH /NJS /NP
Copy-Item "$proj\pubspec.yaml" "$build\pubspec.yaml" -Force

# 2) 构建（先关掉占用文件的 java 进程）
Get-Process java -ErrorAction SilentlyContinue | Stop-Process -Force
Set-Location $build
flutter pub get
flutter build apk --release --split-per-abi
```

产物：`build\app\outputs\flutter-apk\app-arm64-v8a-release.apk`（及 v7a / x86_64）

### 2.3 版本号规则（用户明确要求）

`主版本.次版本.修订号`

| 情况 | 规则 |
|---|---|
| 用户明确要求 | 主版本 +1，次/修订归零 |
| 有新功能 | 次版本 +1，修订归零 |
| 只修 bug | 修订号 +1 |

- 主版本**不由开发者自行递增**
- `versionCode` = `主*1000000 + 次*1000 + 修订`（0.13.1 → 13001）
- **版本号"两处"是个误会，实际是三处**：`pubspec.yaml` 的 `version:`、`lib/app_version.dart`
  的 `kAppVersion`，以及**界面文案**（0.14.0 的设置页「关于」那行是硬编码的 0.13.1，
  于是同一屏出现 0.14.0 和 0.13.1 两个版本 —— 真机截图才看到）。
  现在界面一律用 `$kAppVersion` 插值，并且 `test/app_version_test.dart` 会扫 `lib/ui/`
  里"版本 x.y.z"这种写死的写法直接判红。

### 2.4 安装到真机

```powershell
& $adb connect 192.168.10.102:5555
& $adb -s 192.168.10.102:5555 install -r -t "<apk路径>"
```

> **0.14.1 实测**：同一台机器、签名相同、覆盖安装，`adb install` **直接 `Success`，没弹框**
> （弹框主要出现在换签名 / 首次安装时）。所以每次先直接试 `install -r`，
> 只在卡住时再去做下面的点弹窗。

⚠️ **vivo V2073A 会弹"继续安装"确认框**，`adb install` 会挂住或报
`INSTALL_FAILED_ABORTED: User rejected permissions`。处理方式：

```powershell
# 提交安装后，另开命令点掉弹窗
& $adb -s $dev shell uiautomator dump /sdcard/ui.xml
# 找 text='继续安装' 的 bounds，取其中心点击
& $adb -s $dev shell input tap 540 2216
```

### 2.5 推送与发布（**git push 到 github.com 经常不通**）

`github.com:443` 常常连不上（`Failed to connect after 21s`），但 `api.github.com` 正常。
所以 GitHub 侧一律走 **Git Data API**：blobs → tree → commit → 更新 ref。

```powershell
$gh = 'ghp_...'   # 需要用户提供的 PAT（repo 权限）
$h = @{ Authorization = "Bearer $gh"; Accept = "application/vnd.github+json"; "User-Agent"="inkscroll" }
# 1) 取远端 head 与 base tree
$ref = Invoke-RestMethod "https://api.github.com/repos/BaiFeng940/inkscroll/git/ref/heads/main" -Headers $h
$parent = Invoke-RestMethod "https://api.github.com/repos/BaiFeng940/inkscroll/git/commits/$($ref.object.sha)" -Headers $h
# 2) 逐文件创建 blob，组 entries[]
# 3) POST /git/trees  (base_tree + entries)
# 4) POST /git/commits (message + tree + parents)
# 5) PATCH /git/refs/heads/main
```

GitCode 侧 `git push` 是通的（用 token 作密码）：

```powershell
& $git -c credential.helper= push "https://BaiFeng940:<GITCODE_TOKEN>@gitcode.com/BaiFeng940/inkscroll.git" main:main
& $git -c credential.helper= push -f "...同上..." refs/tags/v<版本>:refs/tags/v<版本>
```

> 首次导入时 GitCode 会重建提交（SHA 分叉），需要**强制推送对齐**。

### 2.6 Release 资产

```powershell
# GitHub：直接上传
POST https://uploads.github.com/repos/BaiFeng940/inkscroll/releases/{id}/assets?name=<文件名>
```

**GitCode 的 release 资产只能由用户手动上传**（接口不存在，见 §5）。流程：

1. 我推代码 + tag
2. **release 对象本身可以用 API 建**（0.14.0 实测：`POST /api/v5/repos/<owner>/<repo>/releases?access_token=…`，
   body 传 `tag_name/name/body/target_commitish`，返回 200；但响应里**没有 release_id**，
   附件接口依旧 404）。所以：
   **用户在网页上只需要"把 `dist/` 里的两个 APK 拖进已建好的 release"**
   <https://gitcode.com/BaiFeng940/inkscroll/releases>
3. 我校验：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool\verify-gitcode-release.ps1 -Version 0.14.0
```

---

## 3. 架构地图

```
lib/
├── app_version.dart           版本号 + 更新源常量（单一真相来源）
├── core/
│   ├── errors.dart            AppError 体系（NetworkAuthError 等）
│   ├── image_header.dart      只读图片头解析宽高
│   ├── natural_sort.dart      自然序（1,2,10 而非 1,10,2）
│   └── lru_cache.dart
├── data/
│   ├── byte_store.dart        应用私有目录布局（bookDir/extracted/netcache）
│   ├── prefs_store.dart       SharedPreferences：书架/进度/设置/字典/更新检查
│   ├── importer.dart          SourcePick / ImportContext / ImportOutcome / Importer
│   ├── import_lock.dart       批量导入期间的 CPU+WiFi 锁
│   ├── update_service.dart    检查更新（GitCode 优先 → GitHub 兜底）
│   ├── archive/
│   │   ├── archive_source.dart       ArchiveSource / ArchiveEntryInfo 抽象
│   │   ├── zip_archive_source.dart   自写 EOCD/Zip64/局部头解析 + DEFLATE + ZipCrypto
│   │   ├── zip_crypto.dart           传统 ZIP 加密解密（纯 Dart）
│   │   ├── tar_archive_source.dart
│   │   └── native_archive_source.dart（rar/7z 预留）
│   ├── byte_source.dart       RandomAccessByteSource 抽象 + FileByteSource
│   ├── pdf/pdf_native.dart    PDF 原生通道封装
│   ├── webdav/
│   │   ├── webdav_client.dart       PROPFIND/GET Range/302/连接池
│   │   ├── webdav_byte_source.dart  用 Range 实现随机访问（网盘 zip 在线读）
│   │   └── webdav_connection.dart   连接模型 + 密码混淆存储
│   └── models/book_meta.dart  BookMeta + BookSource 各类（含 ArchiveSourceSpec.password）
├── importers/
│   ├── import_router.dart     按魔数/扩展名路由到具体导入器
│   ├── archive_importer.dart  本地压缩包（图片→漫画 / 文本→小说）
│   ├── pdf_importer.dart      PDF：只读页数+尺寸，不预渲染
│   ├── folder_importer.dart / loose_image_importer.dart / txt / docx / web
│   ├── webdav_folder_importer.dart  网盘目录 / 压缩包候选扫描（**核心，见待做项**）
│   └── webdav_archive_importer.dart 网盘单个 zip → Document（只读中央目录+抽样）
├── reader/
│   ├── document.dart          Document/Chapter/PageNode/ContentRef/PageContent
│   ├── document_codec.dart    document.json 序列化
│   ├── reader_controller.dart 阅读状态机（翻页/跳转/进度/模式切换）
│   ├── page_cache.dart        PageByteResolver 及本地/压缩包实现
│   ├── webdav_page_resolver.dart / webdav_archive_resolver.dart
│   └── pdf_page_resolver.dart 按需渲染 PDF 页
├── state/app_state.dart       全局状态：书架/导入/网盘库/缓存/更新（**最大文件**）
└── ui/
    ├── home_screen.dart       书架、批量管理、导入入口、启动检查更新
    ├── settings_screen.dart   设置（长说明已收进弹窗）
    ├── webdav_browse_screen.dart  网盘浏览 + 连接表单（字段顺序：地址/用户名/密码/备注）
    ├── prepare_screen.dart    本地压缩包首次打开前的解压准备页
    ├── update_dialog.dart     更新提示
    └── reader/                阅读器、进度条、手势仲裁、页面图片
android/app/src/main/kotlin/com/inkscroll/reader/
├── MainActivity.kt           注册三个插件 + 高刷双层适配
├── SafFolderPlugin.kt        SAF 选择器、openUrl、导入唤醒锁（通道 inkscroll/saf）
├── RefreshRateController.kt  窗口显示模式 + Surface 帧率
└── PdfPlugin.kt              PdfRenderer 通道 inkscroll/pdf（零体积增长）
```

### 关键设计（别改坏）

- **网盘 zip 在线读**：`WebDavByteSource` 用 HTTP Range 实现随机访问，让现成的
  `ZipArchiveSource` 直接跑在网盘文件上。打开包 1~2 次 Range，读一页 2 次。
  196 MB 的包 4 秒建好，翻页开销与包大小无关。
- **按需解压**：`readEntry` 对 DEFLATE 做分级试探（48K/160K/512K），只为读图片头时
  不解压整张图。
- **PDF 用系统 `PdfRenderer`**，不引 pdfx（后者会给 APK 加约 100 MB）。
- **密码与连接**：网盘密码 XOR+Base64 混淆（**不是加密**），压缩包密码明文存在
  `ArchiveSourceSpec.password`。

---

## 4. 已完成（只列能当"已验证能力"用的）

| 版本 | 内容 | 验证程度 |
|---|---|---|
| 0.3.9 | 网盘压缩包在线读（120 个 zip 全部导入，翻页正常） | 真机 ✅ |
| 0.4.x | 默认翻页方式 / 缓存管理 / 相册隐私 / 帮助中心 | 真机 ✅ |
| 0.5.0 | 合集嵌套识别 / 发布签名规范化 / 版本号规则 | 真机 ✅ |
| 0.8.0 | 应用内检查更新（GitCode 优先） | 真机 ✅ |
| 0.9.0 | 网盘压缩包导入并发化（2.97x） | CLI 基准 ✅ |
| 0.10.0 | **PDF 阅读**（3 页矢量样本，封面/翻页/进度都正常） | 真机 ✅ |
| 0.11.1 | 加密压缩包 ZipCrypto 解密 | CLI 交叉验证 ✅ / 真机 ❌ |
| 0.12.0 | 遮罩下可翻页 / 全局圆角输入框 / 合集命名 | 仅编译 ❌ |
| 0.12.1 | 删「不在家时怎么连」/ 嵌套扫描并发 / 302 瓶颈定位 | 编译 ✅ |
| 0.13.0 | **后台导入（唤醒锁）+ 并发 8** | 真机 ✅ 174 本 / 149 秒 |
| 0.13.1 | 修复重复导入（判重漏了压缩包） | 编译 + 逻辑审查 |
| 0.14.0 | **合并合集**（一个合集 = 一本书，每话 = 章节） | 真实网盘 ✅ 194→149 本 / 账目对齐 |
| 0.14.1 | 修「关于」行的硬编码版本号（同屏两个版本）+ 浏览页提示跟着合并开关变 | 真机 ✅ |

实测数据（123云盘，真实账号）：

```
串行          ~2.5 s/本，170 本约 7 分钟
并发 4        实测 6~8 分钟（早期版本）
并发 8 + 后台  实测 174 本 / 149 秒 = 0.86 s/本
```

---

## 5. 已知坑（照抄即可避开）

### 5.1 工具与脚本

| 坑 | 说明 |
|---|---|
| **Python 改 Dart 文件会写坏换行** | 用 `io.open(..., newline="\r\n")` 且内容里已有 `\n` 时，`\n` 被再转义 → 每行之间多一个空行（`\r\r\n`）。**优先用 `edit` 工具改源码**，必须用 Python 时用 `newline=""` 且自己做换行归一。⚠️ 这种文件用 `edit` 会**匹配不上**（工具看到的是归一化后的文本），0.14.0 已把 `webdav_folder_importer.dart` 修复为纯 LF（逐字节校验过：除行尾外内容完全一致），其余源码本来就是 LF |
| 文本匹配插入不可靠 | 注释里常出现同名字符串（如 `_deferCovers = true;`），会插错位置。用**行号 + assert**，并自底向上改 |
| 文件混用 CRLF/LF | 先统计 `\r\n` 与 `\n` 的占比再决定分隔符，否则行号全错 |
| PowerShell 5.1 | 无三元、`if` 不能当表达式、中文全角引号会炸、`Set-Content -Encoding UTF8` 会写 BOM（要 BOM 时反而要用它）、`Get-Content` 返回 PSObject |
| `.ps1` 脚本带中文必须存成 **UTF-8 with BOM** | 否则 PowerShell 按 ANSI 读成乱码，解析报错 |

### 5.2 网络 / 网盘

| 坑 | 说明 |
|---|---|
| **GitCode 的 release 附件上传接口不存在** | `/releases/{tag}/attach_files`、`/upload_assets`、`/releases/assets` 全部 404 或 405；release 对象**不返回 `release_id`**。只能网页手传。**但 release 对象本身能用 `POST /releases` 建**（0.14.0 实测 200） |
| **GitCode 的 `/raw/<分支>/<路径>` 返回 SPA 的 HTML** | 0.14.0 实测：HTTP 200、5792 字节、`<!DOCTYPE html>`，**不是文件内容** —— 拿它核对"代码推上去没有"会得到假结果。改用 `git fetch` 后比 **tree sha**（内容寻址，天然逐字节） |
| **GitCode 的 `main` 与 GitHub 是两条链** | GitHub 走 API 建提交 → sha 必然不同；GitCode 原来是本地链。推 `main` 要 `push -f`，推 tag 不用 |
| **GitCode 对 `HEAD` 返回 401** | 看起来像"文件下不了"，其实 `GET` 是 200 并重定向到 `file-cdn.gitcode.com`。**一律用 GET 判断** |
| GitCode release 的源码包不是安装包 | `v0.8.0.zip/.tar.gz` 是 `type:"source"`，任何 tag 自动生成；APK 是 `type:"attach"` |
| 123云盘 `GET` 会 302 到签名 CDN | `package:http` 跟随后 **`Range` 头仍在**，返回 206 精确字节 |
| 123云盘 `PROPFIND` 带 XML 体返回 404 | 先发空体（RFC 4918 允许），400/415 再带体重试 |
| **123云盘并发 `PROPFIND` 会回「207 + 空列表」** | **不报错**，只是那个目录"看起来是空的"。实测一次扫描 41 个请求里 16~17 个是空的 → 同一账号导入数量每次都不一样（194 / 169 / 141 本），而**串行扫 6 次都稳定 194**。只 `catch` 重试没用（它没抛异常），必须把"空结果"也当可疑信号重试。0.14.0 的 `WebDavFolderImporter._listWithRetry` 就是干这个的（空/异常都退避重试 3 次），修完连测 3 次稳定 |
| fnOS 同样拒绝带体 PROPFIND | 同上处理 |
| 飞牛网页端口 5666 ≠ WebDAV 端口 5005/5006 | 填错会报"不是 WebDAV 服务" |
| 302 缓存直连 CDN **实测无收益** | 已试过并回滚（`webdav_client.dart`）。CDN 签名地址本身还会再跳，缓存反而多一次请求 |

### 5.3 真机测试

| 坑 | 说明 |
|---|---|
| vivo 安装确认弹窗 | 见 §2.4；另：换签名后必须卸载重装（数据会清空） |
| 百度输入法把 `:` `/` 变全角 | `adb shell ime disable com.baidu.input_vivo/.ImeVivoService` |
| `keyevent 111`(ESC) 会关掉整个 AlertDialog | 想在输入后收起键盘又保留弹窗，**不要按 ESC**；直接点按钮 |
| `keyevent 4`(BACK) 在无键盘时会退出整页 | 同上 |
| 通过 adb 推送的文件不在 SAF 选择器里 | 需要 `am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Download/xxx` |
| 换签名/`pm clear` 后数据全没 | 重新添加网盘连接、重新导入 |
| `--target-platform android-arm64` 不带 `--split-per-abi` | versionCode 会退化成 1，导致降级安装失败 |
| release 包没有日志 | `debugPrint` 不进 logcat。**诊断信息要落到界面上**（本项目做法：设置页显示「上次导入：…」摘要） |

### 5.4 凭据（示例，注意轮换）

```
123云盘 WebDAV：https://webdav.123pan.cn/webdav  账号 18873682282  密码 bp3kywse
飞牛 NAS：https://192.168.10.105:5006  账号 davuser（管理员账号 白锋 走 WebDAV 会 401）
真机：192.168.10.102:5555（无线 ADB，USB 只供电）
GitHub PAT / GitCode token：向用户索取，用完建议删除
```

---

## 6. 待做（0.14.0 后剩两项）

> 6.1「合并合集」已于 **0.14.0 完成**，保留在下面作为实现记录与坑位清单。

### 6.1 ✅ 合并合集（0.14.0 已完成）

**现状（0.14.0 之前）**：`漫画根目录/XX合集/第一话/` 导入后是**两本独立的书**，命名 `XX 第一话`
（命名规则在 0.12.0 已实现，函数 `collectionBookName`）。

**已实现**：设置 → 在线库 →「合并合集」（默认**关**）。
开启后一个合集 = **一本书**（书名 `XX`，去掉「合集」二字），每一话 = **一个章节**，
章节菜单可切换、跨话翻页连续；关闭时行为与以前**完全一致**。

**真实网盘实测**（123云盘真实账号，`test/real_scan_manual_test.dart`）：

```
关闭合并：194 本（全部是压缩包）
开启合并：149 本（合集 29 本 + 散本 120 本）
折叠进合集的"话"：74 个
对账：194 = 149 − 29 + 74      ← 没有丢话、没有重复
最大合集：【】竹本 → 6 章 / 173 页（章名 Dream Up、EX档案、Fire up…）
```

**真机实测**（vivo V2073A / Android 13，adb 无线连接）：

```
设置 → 在线库 → 合并合集：默认关 → 打开（跨 force-stop 与覆盖安装都保持）
点连接行 → 网盘浏览 → 「添加为库」
  上次导入：扫描到 149 个候选（压缩包 120，合集 29）；待导 29，跳过 120；成功 29 本，失败 0 个
  ↑ 120 本散书是 0.13.1 时代就有的，判重把它们跳过了 —— 没有产生重复书
在线库出现「【】竹本」173 页（= 22+19+21+30+55+26）
阅读器 → 设置面板 → 章节跳转：Dream Up(22) / EX档案(19) / Fire up(21) / Heat up(30)
  / Heat up2(55) / sign up(26)；跳到最后一话 → 148/173（= 173−26+1，页号跨话连续）
这一本的 6 话**全是 zip**，首屏与章节首屏都能正常出图（证明包内页解析真的通了）
```

> 真机只验到"开关/扫描/导入/章节/渲染"这些**代码路径**；滑动跟手度、高刷这类
> 手感项没有量化，但和改动无关（沿用 0.12/0.13 的实现）。

> 交接文档原来写的"约 38 本 / 174 本"是**当时账号的结构**（每个合集是一个图片子目录）。
> 现在这个账号里"话"绝大多数是**合集目录下的 zip**（`XX合集/第一话.zip`），
> 所以是 29 个合集、194 话。判断标准请用**"一个合集恰好一本书"**，不要盯固定总数。

**数据模型**（`lib/importers/webdav_folder_importer.dart`）——**已实现**

```dart
class WebDavComicCandidate {
  // 现有字段保持不变：url / name / images / isArchive / archiveSize
  final List<WebDavCollectionChapter> chapters;   // 新增，默认 const []
  bool get isCollection => chapters.isNotEmpty;   // 新增
}

class WebDavCollectionChapter {                   // 新增
  const WebDavCollectionChapter({
    required this.title, required this.url, required this.images,
    this.isArchive = false, this.archiveSize,     // 新增：话是 zip 时用
  });
  final String title;              // 「第一话」
  final String url;                // 子目录 **或压缩包** URL
  final List<WebDavEntry> images;  // 该话的图（已按自然序排好）；zip 话为空
}
```

> ⚠️ `isArchive` / `archiveSize` 是**原设计漏掉的一半**：真实库里 `XX合集/第一话.zip`
> 这种"一话一个包"才是主流（实测 74 话里几乎全是 zip）。只按原设计的
> `title/url/images` 实现，这些合集会被扫成 0 章。

**改动清单**（全部已落地）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `lib/data/prefs_store.dart` | 新增 `mergeCollections`（默认 **false**），键 `library.mergeCollections.v1`；`loadMergeCollections()` / `saveMergeCollections()` |
| 2 | `lib/state/app_state.dart` | ① 字段 `bool mergeCollections` + `setMergeCollections()`，bootstrap 里读<br>② `scanLibrary(..., mergeCollections: mergeCollections)`<br>③ 导入循环里：`if (c.isCollection)` → 走合并分支（`else if (c.isArchive)`，同样落盘）<br>④ 「上次导入」摘要里加"合集 N" |
| 3 | `lib/importers/webdav_folder_importer.dart` | ① `_scanOneLevel` 增加参数 `mergeCollections`；开启且本层没图时**整个合集只返回 1 个候选**<br>② 新增 `_scanChapters()`：**4 路并发**扫各话（图片子目录 / 定目录下的 zip / 子目录里的 zip 三种都收），读完按章节名自然序排序<br>③ 新增 `buildMergedCollection({conn, client, candidate})`：逐话调用 `_build(ctx:null, …)`（zip 话走 `WebDavArchiveImporter.buildDocument`）<br>④ 新增**纯函数** `mergeDocuments()`：页 id 重写为 `c{章号}_{原id}` 后合并（便于单测）<br>⑤ `scanLibrary` 透传该参数；`buildFromCandidate` 遇到合集候选自动转交<br>⑥ `buildDocument` 的兜底：合集目录自己没有图时按章节重建（document.json 丢了也能打开） |
| 4 | `lib/ui/settings_screen.dart` | 在线库区块加一个 `SwitchListTile`：<br>标题「合并合集」<br>副标题「开启后，合集内各话合并成一本书，按章节切换；关闭则每话一本」 |

**合并后的 Document 构造要点**

```dart
// 实际实现见 WebDavFolderImporter.mergeDocuments
final id = 'c${chapterIndex}_${p.id}';   // ★ 不加前缀，第二话的 n:0 会顶掉第一话第一页
// chapterIndex 取"已加进来的章节数"，空话被跳过时章号也不会错位
```

**实测结果**（对应原验收标准）

1. ✅ 开启开关 → 重新导入 → 每个合集 1 本，书名 `XX`（不带「合集」）
2. ✅ 打开 → `chapterCount` 与扫描到的话数一致、页数连续（单测断言 `pages.length == pageCount`）
3. ✅ 关闭开关 → 回到"每话一本"，命名仍是 `XX 第一话`
4. ✅ 合集下的 zip 能合并成章节（`isArchive` 章节，走 `WebDavArchiveImporter`）
5. ✅ `flutter analyze` 0 issue；`flutter test` **103 passed / 3 skipped**（skip 的是手动真网盘用例）

**坑位提醒**（0.14.0 实际踩到的）

- `_build` 是 `static Future<Document>`，参数 `ctx` 可传 `null`
- `_scanChapters` 与 `_scanOneLevel` 都是 **4 路并发**，合并时**没有退回串行**
  （总并发仍是 5 × 4，与改动前一致）
- 判重 key 用**合集目录 URL**：开启状态下重复「添加为库」只会跳过，不会产生重复书
- 页 id 撞车是最隐蔽的坑：总页数**看起来还是对的**，只有"第二话开始内容变少"这种怪象
- **合并后同一本书里会同时出现直链图片页（`WebDavRef`）和包内页（`WebDavArchiveRef`）**。
  `WebDavPageByteResolver` 原来只认前者，遇到后者直接抛"页内容引用类型与网络来源不匹配"，
  表现是 zip 章节**整章空白**（书架、章节数、页数全都正常）。0.14.0 已让它按包 URL
  懒创建 `WebDavArchivePageResolver` 并转交，两个预取循环也都跳过对方的页
- 扫描结果会小幅波动 → **已在 0.14.0 修掉**，见 §5.2「207 + 空列表」那一行。
  如果以后又出现"每次导入数量都不一样"，先怀疑 `_listWithRetry` 被绕过或调小

---

### 6.2 加密压缩包真机验证（代码已写，缺验证）

**已完成**

- `lib/data/archive/zip_crypto.dart`：ZipCrypto 解密（纯 Dart）
- `zip_archive_source.dart` 的 `readEntry` 增加了加密分支（读整条 → 解密 → 丢 12 字节头 → 解压）
- `ArchiveSourceSpec.password` 持久化 + `_openArchive(password:)` 全链路
- 设置里的「压缩包密码字典」（默认空 = 不启用），导入时自动尝试
- 测试 `test/zip_crypto_test.dart`（自实现加密器做双向验证，5 个用例）
- **CLI 交叉验证通过**：`tool/make_encrypted_zip.py` 用 Python 独立实现加密器
  生成加密 zip，Python 标准库能读 → `tool/probe_encrypted_zip.dart` 走 App 相同代码路径：
  ```
  [1] 无密码 → 正确要求密码
  [2] 正确密码 → 3/3 条目解出合法 PNG（字节数与原始一致）
  [3] 错误密码 → 正确报"密码错误"
  ```

**待验证（真机，约 3 分钟）**

1. 设置 → 压缩包密码字典 → 添加 `manga123`
2. 导入 `/sdcard/Download/encrypted-comic.zip`（可用 `tool/make_encrypted_zip.py` 重新生成）
3. 打开 → 应看到 3 张彩色测试图（720×1080，分别黄/绿/红底）
4. 再测：**不带字典**时导入同一个包 → 应弹密码框；输错密码 → 报"密码错误"

**已知限制**：AES-256（compression method 99）不支持，会给出明确提示。

---

### 6.3 遮罩翻页验证（代码已写，缺验证）

**已完成**（0.12.0）

- `_ReaderMenuOverlay` 的遮罩从 `HitTestBehavior.opaque + onTap` 改成 `IgnorePointer`
- `ReaderController.handleSingleTap`：菜单可见时，点两侧**照样翻页**（菜单保持打开），
  点中间才关菜单

**待验证（真机，约 1 分钟）**

1. 打开任意一本书 → 点屏幕中间呼出菜单
2. 点**右侧边缘** → 页码应 +1，且菜单仍在
3. 点屏幕**中间** → 菜单关闭
4. 上下拖动 → 滚动 / 翻页正常（之前被遮罩吃掉）

若仍不能翻页，说明还有别的手势拦截点，优先查：
`ReaderProgressBar` 所在层、`InteractiveViewer`、以及 `page_image.dart` 的
手势识别器是否 `HitTestBehavior.opaque`。

---

## 7. 可直接粘贴的提示词

### 7.1 已完成：合并合集（0.14.0）

留给记录用 —— 这条需求已经做完，**不要再重做一遍**。
想验证它现在是否还正常，跑：

```powershell
$env:INKSCROLL_DAV_URL  = "https://webdav.123pan.cn/webdav"
$env:INKSCROLL_DAV_USER = "18873682282"
$env:INKSCROLL_DAV_PASS = "<123云盘 WebDAV 密码>"
flutter test test/real_scan_manual_test.dart --reporter expanded
# 期望：关闭 194 本 / 开启 149 本（合集 29），且 194 = 149 − 29 + 74
```

原始需求（存档）：

```
继续开发 inkScroll（Flutter 漫画阅读器）。工作区 D:\DSH Desktop\work\flutter-comic-reader。

任务：实现设置里的「合并合集」功能。

现状：网盘目录 漫画根目录/XX合集/第一话/ 导入后是两本独立的书（命名 XX 第一话，命名规则已实现）。
目标：新增开关「合并合集」，开启后一个合集 = 一本书，每一话 = 一个章节。

设计与改动清单见 docs/HANDOFF.md 的 §6.1，请严格按那里的数据模型和 4 处改动来做。
注意：
- 用 edit 工具改源码，不要用脚本批量替换（历史上踩过换行被写坏的坑）
- _build() 可复用，ctx 传 null
- 现有嵌套扫描已是 4 路并发，不要退回串行
- 默认关闭，不改变现有行为

验收：开启后书架约 38 本（每合集一本）、章节可切换、跨话翻页连续；
关闭后回到 174 本且命名不变。analyze 0 issue、test 全绿。
完成后按 HANDOFF §2.5 推送 GitHub(API) 与 GitCode(git push)，并按版本号规则发版。
```

### 7.2 验证任务（加密压缩包 + 遮罩翻页）

```
继续开发 inkScroll。工作区 D:\DSH Desktop\work\flutter-comic-reader。
真机 192.168.10.102:5555 已 root-free，用 adb 操作。

任务：补两个"代码已写、缺真机验证"的功能，详见 docs/HANDOFF.md §6.2 和 §6.3。

一、加密压缩包（§6.2）
1. 用 D:\DSH Desktop\resources\office-runtime\...\python.exe 跑 tool/make_encrypted_zip.py 生成测试包
2. adb push 到 /sdcard/Download/，用 MEDIA_SCANNER_SCAN_FILE 广播让它出现在选择器里
3. 设置里给密码字典加 manga123 → 导入该包 → 应直接看到 3 张彩色测试图
4. 再测无字典时弹密码框、输错密码报错

二、遮罩翻页（§6.3）
打开一本书 → 点中间呼出菜单 → 点右侧边缘应翻页且菜单保持 → 点中间关菜单。

发现问题直接修，并在修完后更新 docs/HANDOFF.md 的对应章节。
注意 vivo 会弹「继续安装」确认框，需要另开命令点掉。
```

### 7.3 通用续作（不知道从哪继续时）

```
继续开发 inkScroll。先读 docs/HANDOFF.md，然后按 §6 的待做项继续。
（当前版本 0.13.1；构建/发布/踩坑清单都在那份文档里。）
如果我要你改的模块涉及用脚本批量改源码，请改用 edit 工具。
```

### 7.4 提速专项（如果还想继续优化导入速度）

```
继续优化 inkScroll 的网盘导入速度。当前实测 0.86 s/本（174 本 149 秒，并发 8 + 后台）。
已排除：合集嵌套串行扫描（已并发化）、减少抽样次数（无收益）、302 缓存直连 CDN（无收益，已回滚）。

下一步应该先**测准**时间花在哪，而不是继续猜：
做一个请求级计时探针（记录每次 Range 的 DNS / TLS / 首字节 / 传输 / 重定向跳数），
对真实 123云盘跑 20 个包，把分布打出来。再根据数据决定优化方向。
探针放 tool/ 下，只依赖 WebDavClient，不要引入 Flutter。
```

---

## 8. 常用工具脚本

| 脚本 | 用途 |
|---|---|
| `tool/push-to-gitcode.ps1` | 推 main + tags 到 GitCode（token 从环境变量读，推完自动清掉明文） |
| `tool/verify-gitcode-release.ps1` | 校验 GitCode release 的 APK 是否完整可下载（用 GET，不用 HEAD） |
| `tool/bench_import_concurrency.dart` | 串行 vs 并发导入基准 |
| `tool/bench_scan_nested.dart` | 合集嵌套扫描 串行 vs 并发基准 |
| `tool/probe_batch_archives.dart` | 连续导入 N 个真实压缩包，看成功率和单包耗时 |
| `tool/probe_encrypted_zip.dart` | 用真实加密 zip 验证 ZipCrypto 解密（三态：无密码/正确/错误） |
| `tool/make_encrypted_zip.py` | 用 Python 独立实现生成加密 zip（含交叉验证） |
| `tool/probe_update.dart` | CLI 验证更新解析（走真实接口） |
| `test/real_scan_manual_test.dart` | **手动**：对真实网盘验证「合并合集」扫描（默认 skip；用 `INKSCROLL_DAV_URL/USER/PASS` 环境变量启用）。CLI 版探针不行 —— 导入器经 `webdav_connection.dart` 拉进 Flutter，`dart run` 会报 `dart:ui` 不可用 |

---

## 9. 文档资产

| 文档 | 位置 |
|---|---|
| 帮助中心（28 篇） | `docs/help/index.html` |
| 图文教程（已并入帮助中心，旧链接跳转） | `docs/tutorial.html` |
| 官网首页 | `docs/index.html` |
| GitCode 流程 | `docs/GITCODE.md` |
| GitCode 实测结论 | `docs/GITCODE-VERIFIED.md` |
| 设计文档 | `DESIGN.md` |
| 本交接文档 | `docs/HANDOFF.md` |

图标征集（低调位置）：帮助中心页脚 + 官网底部，512×512 PNG 投稿 `jk968922@163.com`。
