/// 网页链接导入 —— **骨架 + 接入指引**（尚未实现）。
///
/// 流程：抓原始字节 → 自己解码 → Readability 提取正文 → 逐块生成 PageNode。
///
///   1) pubspec 加 `dio: ^5.7.0` 与 `html: ^0.15.4`
///
///   2) 抓取时**必须 responseType: ResponseType.bytes**，
///      不要依赖 dio 的自动解码（中文站点经常 charset 标错或缺失）：
///
///        final resp = await dio.get<List<int>>(uri.toString(),
///          options: Options(
///            responseType: ResponseType.bytes,
///            headers: {'User-Agent': _mobileUA, 'Accept-Language': 'zh-CN,zh;q=0.9'},
///          ),
///          cancelToken: ctx.cancel);
///        final encoding = fromContentType(resp.headers)   // charset=...
///                      ?? fromMetaCharset(resp.data!)      // <meta charset>
///                      ?? CharsetDetector.detect(...);
///        final html = decodeBytes(resp.data!, encoding);
///
///   3) Readability 启发式（Mozilla 简化版）：
///        a. 清理：移除 script/style/noscript/iframe/nav/footer/aside/form
///           class/id 黑名单：comment|sidebar|footer|header|nav|ad|promo|share|related
///        b. 打分：对每个 <p>/<pre>/<td>
///             score = 1 + min(3, text.length ~/ 100) + 标点数量
///             score[parent]      += score
///             score[grandparent] += score / 2
///           类名加成（中文站点同样有效）：
///             命中 article|content|post|entry|main|正文|内容 → *2
///             命中 comment|meta|foot|nav|sidebar|ad          → *0.3
///        c. 取最高分节点的祖先链中"内容最完整"的一个作为 article root
///        d. 按阅读顺序抽取：p / h1..h6 / blockquote / pre / figure,img / table
///
///   4) 图片引用重写（懒加载站点是重点）：
///        src / data-src / data-original / data-lazy-src / data-actualsrc
///        srcset 取最大宽度那条
///        data:image/...;base64 也要支持
///        相对路径 → base.resolve()
///      ★ 用 NetworkRef 而不是下载到本地：网页插图动辄几百张，
///        NetworkRef 走图片库的磁盘缓存与懒加载，正好满足"图片懒加载"。
///
///   5) 兜底：HTTP 抓取失败（403 反爬 / SPA / Cloudflare）时，
///      用**隐藏的** flutter_inappwebview 注入 Readability.js 拿回正文 HTML。
///      ★ WebView 只用于网页链接导入，绝不用来渲染漫画或 PDF。
///
/// 合规提醒（必须写进 UI 文案）：
///   - 只做"用户输入单个 URL"的按需抓取，不做批量爬取
///   - **不实现反爬绕过**；403 就直接提示"该站点不支持导入"
///   - 抓取内容仅供个人阅读，不提供分享/导出/再分发能力
library;

import '../core/errors.dart';
import '../data/importer.dart';

class WebImporter implements Importer {
  WebImporter();

  @override
  String get id => 'web';

  @override
  bool canHandle(SourceProbe probe) => probe.formatName == 'web';

  @override
  Future<ImportOutcome> run(ImportContext ctx) async {
    return const ImportFailure(GenericError(
      '网页导入尚未启用。\n\n'
      '接入步骤见 lib/importers/web_importer.dart 顶部注释：\n'
      '  1. pubspec 加 dio 与 html\n'
      '  2. responseType: ResponseType.bytes 抓原始字节，自己按 charset 解码\n'
      '  3. 实现 Readability 启发式（打分 + 类名权重）\n'
      '  4. 图片重写 data-src/srcset → NetworkRef（天然懒加载）\n'
      '  5. 失败时用隐藏 WebView 注入 Readability.js 兜底\n\n'
      '在此之前，可以用系统浏览器把正文另存为 TXT 后导入。',
    ));
  }
}
