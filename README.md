# inkScroll

**本地与网盘（WebDAV）漫画 / 文档阅读器** —— Flutter 编写，Android 优先。

压缩包按需解压、网盘 zip 在线直读、虚拟长页、高刷新率适配。
不收集任何数据：只有你主动连接网盘时才有网络请求。

| 本地书架 | 阅读 | 网盘浏览 |
|---|---|---|
| ![书架](docs/library.png) | ![阅读](docs/reading.png) | ![网盘](docs/browse.png) |

- **当前版本：0.15.0**（项目重整批次一）
- 下载：[GitHub Releases](https://github.com/BaiFeng940/inkscroll/releases)
- 帮助中心（28 篇图文）：https://baifeng940.github.io/inkscroll/help/
- 许可证：[MIT](LICENSE)

---

## 特性

### 双来源书架

- **本地库**：文件夹 / 压缩包 / 散图导入，Android 走自研 SAF 通道直读复制，不要存储权限。
- **在线库**：连接任意标准 WebDAV 网盘（飞牛 fnOS、群晖、威联通、TrueNAS、123云盘、坚果云、Nextcloud、Alist），
  选中目录**批量导入整库**——实测 174 本 / 149 秒，支持后台导入 + 唤醒锁。
- **合集识别**：「漫画根目录 / 某某合集 / 第一话」自动嵌套识别；「合并合集」开关可把一个合集
  合成一本多章节的书，跨话页号连续。
- 百度网盘、阿里云盘等无 WebDAV 的网盘，可经 Alist 网关接入。

### 按需读取（三条铁律）

1. **不解压整个压缩包**：自研 ZIP 引擎只读中央目录，翻到哪页解压哪页（48/160/512KB 分级试探）。
2. **不合成超大 Bitmap**：解码宽度钳制到屏幕物理宽，一张 3000×4000 的页只占约 6MB 内存。
3. **不一次性加载所有图片**：双层缓存（原始字节 LRU 32 项/128MB + 解码位图 40 张/128MB）。

**网盘 zip 在线直读**：用 HTTP Range 把同一套 ZIP 引擎架到网盘文件上——开包 1~2 次请求，
翻页开销与包大小无关，196MB 的包 4 秒建好。看过的页自动落盘缓存，断网可看。

### 阅读器

- 两种模式：**左右翻页**（拖动 + 点击分区，可调分区宽度）与**上下滑动**（Webtoon 无缝长页）。
- **双指捏合 / 双击缩放**（2.5 倍、以落点为中心、带动画），缩放态平移，到边缘自动交还翻页。
- **竖屏翻页顶部留白**（默认开）：首张漫画上方预留状态栏 / 挖孔高度，不被通知栏遮挡，可关闭。
- 进度条拖动实时预览 + 松手三轮收敛精确跳转；进度按模式分别记忆，按书记忆阅读模式。
- 文本排版：字号 / 行距 / 边距 / 四色背景（白·羊皮纸·灰·黑）/ 标题样式，字符锚点改字号不丢位置。
- 章节跳转（合并合集的书跨话连续）；阅读亮度遮罩；屏幕常亮开关。
- 翻页动画三档（关 / 快 / 标准）；菜单浮层与进度条带过渡动画。

### 高刷新率

原生两层适配：窗口显示模式（`preferredDisplayModeId`，锁定分辨率选档）+ 首帧后
`Surface.setFrameRate(120, FIXED_SOURCE)`。**刷新率档位可在设置里选**：标准（最高 120Hz）/
拉满（用屏幕最高档，144Hz 设备不再被压到 60Hz）/ 跟随系统。
Dart 侧配套节流：进度通知万分位、预览 70ms、度量回填帧内合并。

### PDF 与加密压缩包

- **PDF**：Android 系统 `PdfRenderer` 按需渲染，APK 零体积增长；翻页 / 滚动自动预取前后各 2 页；
  密码 PDF 给出明确提示。
- **加密压缩包**：支持 ZipCrypto（中文漫画圈主流），可设密码字典自动尝试；AES-256 暂不支持。

### 更多能力

- **批量管理**：长按进选择模式，全选 / 批量收藏 / 批量删除。
- **缓存管理**：分类统计（网盘页 / 解压产物 / 封面），一键清理，不动书架与进度。
- **应用内检查更新**：GitCode 国内镜像优先 → GitHub 兜底，可跳过指定版本。
- **帮助中心**：应用内直达，28 篇图文覆盖导入、网盘、阅读、远程访问与常见问题。

## 支持格式与能力边界（诚实版）

| 内容 | 支持 | 说明 |
|---|---|---|
| zip / cbz | ✅ | 自研中央目录 + 按需 DEFLATE；ZipCrypto 密码（密码字典） |
| tar / cbt | ✅ | 512B 头索引 + 随机切片读取 |
| PDF | ✅ | 系统 PdfRenderer；密码 PDF 暂不支持 |
| TXT / MD / SRT / ASS / VTT / NFO | ✅ | UTF-8 严格校验 + 容错降级；GBK 文件目前仅提示不转码 |
| 图片 JPG/PNG/WebP/GIF/BMP/AVIF/HEIC/TIFF/ICO | ✅ | 单图或散图成书 |
| 文件夹 | ✅ | 图片自动成章、文本自动分章分页 |
| rar / 7z / gz / bz2 / xz | ❌ | 明确报错并给转换指引 |
| DOCX / 网页正文 | ⏳ | 骨架与接入指引已留，未启用 |
| 网盘厂商私有 API | ❌ | 只做标准 WebDAV（夸克等 Cookie 方案有 ToS 风险，不做） |

## 快速开始

1. 安装（见下方下载）。
2. **本地导入**：右下角「导入」→ 选择文件夹 / 压缩包 / 图片。
3. **添加网盘**：设置 → 在线库 → 添加 WebDAV 库 → 填地址、账号、密码 →
   选中漫画根目录 →「添加为库」。建议为阅读器单独建一个**只读**账号。
4. 想跑满高刷：系统设置里把 inkScroll 加入高刷应用白名单（应用内设置页有各机型路径）。

## 下载

到 [Releases](https://github.com/BaiFeng940/inkscroll/releases) 下载对应架构的 APK
（绝大多数现代手机选 `arm64-v8a`），配套 `SHA256SUMS.txt` 校验：

```bash
sha256sum -c SHA256SUMS.txt
```

安装包命名规范：`inkscroll-<版本>-<架构>.apk`，架构用 Android 官方 ABI 名。

## 从源码构建

```bash
# 工具链：Flutter 3.47.7 stable · JDK 17 · Android SDK（platform 36）
git clone https://github.com/BaiFeng940/inkscroll.git
cd inkscroll
flutter pub get
flutter analyze          # 0 issue
flutter test             # 107 用例（3 个手动真网盘用例默认跳过）
flutter build apk --release --split-per-abi
```

- 仓库已内置国内加速：Gradle 发行包走腾讯镜像、Maven 依赖走阿里云（`android/build.gradle.kts`
  与 `settings.gradle.kts`，海外环境可自行还原官方源）。
- 发布签名：把 `key.properties` 与 keystore 放到仓库外，`android/app/build.gradle.kts`
  会自动启用 V1+V2+V3 签名；找不到密钥时回退 debug 签名（仅限本机验证，不可分发）。

## 版本历史

| 版本 | 主题 |
|---|---|
| 0.1.0 – 0.3.x | 本地阅读器 → WebDAV 在线浏览 → 整库批量导入 → 网盘压缩包在线读 |
| 0.4.x – 0.7.x | 缓存管理 / 相册隐私、合集嵌套识别、帮助中心、批量管理 |
| 0.8.0 – 0.9.0 | 应用内检查更新（GitCode 优先）、网盘导入并发化提速约 3 倍 |
| 0.10.0 – 0.11.x | PDF 阅读（原生渲染零体积增长）、ZipCrypto 加密包 + 密码字典 |
| 0.12.x – 0.13.x | 遮罩下可翻页、嵌套扫描并发化、后台导入 + 并发 8（174 本 149 秒） |
| 0.14.x | 合并合集（合集 = 一本书，每话 = 章节）、版本号硬编码修复 |
| **0.15.0** | **项目重整批次一**：真机验证的流畅性与手势修复（双击缩放、垂直双击防锁死、二次导入失败、滚动 O(n) 缓存），设置新增 4 项（常亮 / 刷新率档位 / 翻页顶部留白 / 翻页动画），过渡动画，PDF 邻页预取，全库行尾统一 |

细节见 [dist/release-notes-0.15.0.md](dist/release-notes-0.15.0.md)。

## 架构

```
lib/
├── ui/          书架 · 设置 · 网盘浏览器 · 阅读器（手势仲裁 / 页面渲染）
├── state/       全局状态（书架 / 导入 / 网盘库 / 缓存 / 更新）
├── reader/      Document 模型 · 阅读状态机 · PageByteResolver×5
├── data/        ByteStore 缓存 · ZIP/TAR 引擎 · WebDAV 客户端 · PDF 通道
├── importers/   13 个导入器 + 魔数路由 · netdisk 抽象
└── core/        魔数识别 · 免解码取宽高 · 编码探测 · 自然排序 · 错误体系
android/         SafFolderPlugin · RefreshRateController · PdfPlugin（零第三方插件依赖）
```

设计决策与关键机制详见 [DESIGN.md](DESIGN.md)（按 0.15.0 实现重写）。
直接依赖仅 9 个 Flutter 包，ZIP / WebDAV / PDF / SAF 全部自研或走系统 API。

## 隐私

- 不收集任何数据，无统计 SDK、无广告、无第三方原生插件。
- 网盘凭据保存在应用私有目录；导入了什么书、看了多少页，只存在你的手机里。

## 反馈

- 帮助中心：https://baifeng940.github.io/inkscroll/help/
- 问题反馈：[GitHub Issues](https://github.com/BaiFeng940/inkscroll/issues)
- 图标征集：512×512 PNG 投稿 jk968922@163.com（帮助中心页脚同款）

## 许可证

[MIT](LICENSE)
