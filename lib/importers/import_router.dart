/// 导入路由：先用魔术字节探测真实格式，再分派给对应的 Importer。
///
/// 为什么不用扩展名：现实中经常遇到改名文件、无扩展名文件、
/// .zip 实为 rar、.zip 其实是 docx。探测优先，扩展名只用于消歧。
library;


import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../core/magic.dart';
import '../data/archive/zip_archive_source.dart';
import '../data/byte_source.dart';
import '../data/byte_store.dart';
import '../data/importer.dart';
import 'archive_importer.dart';
import 'docx_importer.dart';
import 'folder_importer.dart';
import 'loose_image_importer.dart';
import 'pdf_importer.dart';
import 'txt_importer.dart';
import 'web_importer.dart';

class RoutedImport {
  RoutedImport({required this.importer, required this.probe, this.earlyFailure});

  final Importer? importer;
  final SourceProbe probe;

  /// 探测阶段就能判定失败（例如 rar 包）
  final AppError? earlyFailure;
}

class ImportRouter {
  ImportRouter({required this.store});

  final ByteStore store;

  late final FolderImporter _folder = FolderImporter(store: store);
  late final ArchiveImporter _archive = ArchiveImporter(store: store);
  late final TxtImporter _txt = TxtImporter(store: store);
  late final LooseImageImporter _loose = LooseImageImporter(store: store);
  late final PdfImporter _pdf = PdfImporter(store: store);
  late final DocxImporter _docx = DocxImporter();
  late final WebImporter _web = WebImporter();

  /// 探测来源。**只读头部字节**，绝不整文件读入。
  Future<RoutedImport> route(SourcePick pick) async {
    switch (pick.kind) {
      case SourcePickKind.webdav:
        // 网络来源由 AppState 直接分派给 WebDavFolderImporter，
        // 不会走到这里。留一个明确的失败而不是静默走错分支。
        return RoutedImport(
          importer: null,
          probe: const SourceProbe(formatName: 'webdav', entryNames: []),
          earlyFailure: const GenericError('网络来源应直接由 WebDAV 导入器处理'),
        );

      case SourcePickKind.folder:
        return RoutedImport(
          importer: _folder,
          probe: const SourceProbe(
            formatName: 'folder',
            entryNames: [],
            isContainer: true,
          ),
        );

      case SourcePickKind.url:
        return RoutedImport(
          importer: _web,
          probe: SourceProbe(
            formatName: 'web',
            entryNames: const [],
            isContainer: false,
          ),
        );

      case SourcePickKind.files:
        // 多选：全是图片 → 散图导入；否则只取第一个走单文件流程
        if (pick.paths.isEmpty) {
          return RoutedImport(
            importer: null,
            probe: const SourceProbe(formatName: 'unknown', entryNames: []),
            earlyFailure: const ImportEmptyError(),
          );
        }
        final allImages = pick.paths.every(_looksLikeImageExt);
        if (allImages) {
          return RoutedImport(
            importer: _loose,
            probe: const SourceProbe(formatName: 'images', entryNames: []),
          );
        }
        return _routeFile(pick.paths.first, pick);

      case SourcePickKind.file:
        final path = pick.path;
        if (path == null) {
          return RoutedImport(
            importer: null,
            probe: const SourceProbe(formatName: 'unknown', entryNames: []),
            earlyFailure: const ImportEmptyError(),
          );
        }
        return _routeFile(path, pick);
    }
  }

  Future<RoutedImport> _routeFile(String path, SourcePick pick) async {
    final src = await FileByteSource.open(path);
    try {
      final len = await src.length();
      final head = await src.read(0, len < 8192 ? len : 8192);
      final format = MagicDetector.detect(head, filename: p.basename(path));

      switch (format) {
        case ContainerFormat.zip:
          // zip 可能是 docx / epub。
          // 用**扩展名 + 目标结构**快速消歧，而不是解析中央目录：
          // 大包的中央目录要读几 MB，而这里只是为了选一个导入器，
          // 选错了影响也不大（DocxImporter 自己会再校验一次并返回明确错误）。
          if (_looksLikeDocxByExtension(path)) {
            return RoutedImport(
              importer: _docx,
              probe: const SourceProbe(
                formatName: 'docx',
                entryNames: [],
                isContainer: true,
              ),
            );
          }
          return RoutedImport(
            importer: _archive,
            probe: const SourceProbe(
              formatName: 'zip',
              entryNames: [],
              isContainer: true,
            ),
          );

        case ContainerFormat.tar:
          return RoutedImport(
            importer: _archive,
            probe: const SourceProbe(
              formatName: 'tar',
              entryNames: [],
              isContainer: true,
            ),
          );

        case ContainerFormat.rar4:
        case ContainerFormat.rar5:
          return RoutedImport(
            importer: null,
            probe: const SourceProbe(formatName: 'rar', entryNames: []),
            earlyFailure: const Rar7zNotImplementedError('RAR'),
          );

        case ContainerFormat.sevenZip:
          return RoutedImport(
            importer: null,
            probe: const SourceProbe(formatName: '7z', entryNames: []),
            earlyFailure: const Rar7zNotImplementedError('7z'),
          );

        case ContainerFormat.gzip:
          return RoutedImport(
            importer: null,
            probe: const SourceProbe(formatName: 'gzip', entryNames: []),
            earlyFailure: const GenericError(
              '暂不支持 .gz / .tar.gz（需要顺序解压建索引）。'
              '请先解压出 zip 或直接选文件夹导入。',
              action: ErrorAction.convertFile,
            ),
          );

        case ContainerFormat.pdf:
          return RoutedImport(
            importer: _pdf,
            probe: const SourceProbe(formatName: 'pdf', entryNames: []),
          );

        case ContainerFormat.docOle:
          return RoutedImport(
            importer: null,
            probe: const SourceProbe(formatName: 'doc', entryNames: []),
            earlyFailure: const GenericError(
              '旧版 .doc（OLE2 二进制格式）无法在 Flutter 端纯 Dart 解析。'
              '请用 WPS / Word 另存为 .docx 或 .pdf 后再导入。',
              action: ErrorAction.convertFile,
            ),
          );

        case ContainerFormat.jpeg:
        case ContainerFormat.png:
        case ContainerFormat.webp:
        case ContainerFormat.gif:
        case ContainerFormat.bmp:
        case ContainerFormat.avif:
        case ContainerFormat.heic:
        case ContainerFormat.tiff:
        case ContainerFormat.ico:
        case ContainerFormat.svg:
          return RoutedImport(
            importer: _loose,
            probe: SourceProbe(
              formatName: 'images',
              entryNames: const [],
              mimeHint: format.label,
            ),
          );

        case ContainerFormat.jxl:
        case ContainerFormat.psd:
        case ContainerFormat.qoi:
          // 能识别但 Flutter 不保证能解码 → 给出明确提示，而不是模糊的"无法识别"
          return RoutedImport(
            importer: null,
            probe: SourceProbe(formatName: format.name, entryNames: const []),
            earlyFailure: GenericError(
              '识别到 ${format.label} 格式，但 Flutter 的图像解码器不支持它。\n'
              '请转换为 JPG / PNG / WebP 后再导入（推荐用 XnConvert 批量转换）。',
              action: ErrorAction.convertFile,
            ),
          );

        case ContainerFormat.html:
        case ContainerFormat.plainText:
          return RoutedImport(
            importer: _txt,
            probe: const SourceProbe(formatName: 'txt', entryNames: []),
          );

        case ContainerFormat.bzip2:
        case ContainerFormat.xz:
          return RoutedImport(
            importer: null,
            probe: SourceProbe(formatName: format.name, entryNames: const []),
            earlyFailure: GenericError(
              '暂不支持 ${format.name} 压缩格式。',
              action: ErrorAction.convertFile,
            ),
          );

        case ContainerFormat.unknown:
          return RoutedImport(
            importer: null,
            probe: const SourceProbe(formatName: 'unknown', entryNames: []),
            earlyFailure: GenericError(
              '无法识别的文件格式（已按文件内容而非扩展名判定）。\n'
              '当前支持：zip / tar / txt / 图片（JPG、PNG、WebP、GIF、BMP、'
              'AVIF、HEIC、TIFF、ICO）。',
            ),
          );
      }
    } finally {
      await src.close();
    }
  }

  /// 只读 ZIP 的中央目录，拿到条目名列表。
  /// 当前路由流程未使用（改为扩展名消歧），保留给"需要精确识别 docx/epub"的场景。
  // ignore: unused_element
  Future<List<String>> _peekZipEntryNames(RandomAccessByteSource src) async {
    try {
      final zip = ZipArchiveSource(src);
      await zip.open();
      return zip.entries.map((e) => e.entryPath).toList();
    } catch (_) {
      return const [];
    }
  }

  static bool _looksLikeDocxByExtension(String path) {
    final name = p.basename(path).toLowerCase();
    return name.endsWith('.docx') || name.endsWith('.docm');
  }

  static bool _looksLikeImageExt(String path) {
    final ext = p.extension(path).toLowerCase();
    return const {
      '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.avif', '.heic', '.jfif'
    }.contains(ext);
  }
}
