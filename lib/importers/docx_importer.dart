/// DOCX 导入 —— **骨架 + 接入指引**（尚未实现）。
///
/// DOCX 本质是 ZIP + XML，所以实现路径是清晰的：
///
///   1) 用现成的 ZipArchiveSource 读这三个条目（我们的按需读取能力直接复用）：
///        [Content_Types].xml              确认是 DOCX
///        word/document.xml                正文
///        word/_rels/document.xml.rels     关系表：rId -> media/imageN.png
///
///   2) pubspec 加 `xml: ^6.5.0`，用 XmlDocument.parse 解析：
///
///        final body = doc.rootElement.findElements('w:body').first;
///        for (final node in body.childElements) {
///          switch (node.name.local) {
///            case 'p':   addParagraph(node); break;
///            case 'tbl': addTable(node);     break;
///          }
///        }
///
///   3) 段落内逐层提取：
///        w:pPr → w:pStyle/@w:val（'Heading1' → 标题层级）、w:jc、w:ind
///        w:r   → w:rPr（w:b 粗体 / w:i 斜体 / w:u 下划线 / w:sz 半磅 / w:color / w:rFonts）
///                w:t 文本（注意 xml:space="preserve"）、w:tab、w:br
///                w:drawing | w:pict → a:blip/@r:embed → 关系表 → 包内图片
///
///   4) 内嵌图片要**复用尺寸嗅探**（只解前 256KB），这样虚拟长页能立刻算高度：
///        final info = zip.byPath('word/media/image1.png');
///        final head = await zip.readEntry(info, maxBytes: 256 * 1024);
///        final dim  = ImageHeaderParser.tryParse(head);
///
///   5) 结构识别 → 统一模型：
///        Heading1 起新章，Heading2 起新节
///        段落累积到 ~1200 字或遇到图片 → 一个 PageNode(kind: text)
///        内嵌图片 → PageNode(kind: image)
///
/// 支持范围（诚实说明）：粗体/斜体/下划线/字号/颜色/标题/对齐/缩进/图片/表格（降级为等宽文本）。
/// 不支持：文本框、SmartArt、图表、分栏、页眉页脚精确定位。
/// ★ UI 上必须提示"部分排版已简化"，不要假装完美还原。
library;

import '../core/errors.dart';
import '../data/importer.dart';

class DocxImporter implements Importer {
  DocxImporter();

  @override
  String get id => 'docx';

  @override
  bool canHandle(SourceProbe probe) => probe.formatName == 'docx';

  @override
  Future<ImportOutcome> run(ImportContext ctx) async {
    return const ImportFailure(GenericError(
      'DOCX 导入尚未启用。\n\n'
      '接入步骤见 lib/importers/docx_importer.dart 顶部注释：\n'
      '  1. pubspec 加 xml: ^6.5.0\n'
      '  2. 用 ZipArchiveSource 读 word/document.xml 与 .rels\n'
      '  3. 解析 w:p / w:r / w:t / w:drawing，转成统一的 TextContent / ImageContent\n\n'
      '在此之前，可以先在电脑上把 DOCX 另存为 PDF 或纯文本导入。',
      action: ErrorAction.convertFile,
    ));
  }
}
