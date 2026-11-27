/// 书目元数据。会被序列化成 JSON 存进 SharedPreferences。
library;

enum BookKind { comic, novel, mixed, pdf, web, doc }

/// 内容来源：阅读器靠它重建"页字节提供者"
sealed class BookSource {
  const BookSource();

  Map<String, dynamic> toJson();

  static BookSource fromJson(Map<String, dynamic> json) {
    switch (json['type'] as String?) {
      case 'folder':
        return FolderSource(json['path'] as String);
      case 'looseFiles':
        return LooseFilesSource(
          (json['paths'] as List).cast<String>(),
        );
      case 'webdav':
        return WebDavSource(
          connectionId: json['connectionId'] as String? ?? '',
          folderUrl: json['folderUrl'] as String? ?? '',
          folderName: json['folderName'] as String? ?? '',
        );
      case 'webdavArchive':
        return WebDavArchiveSource(
          connectionId: json['connectionId'] as String? ?? '',
          archiveUrl: json['archiveUrl'] as String? ?? '',
          archiveName: json['archiveName'] as String? ?? '',
          archiveSize: json['archiveSize'] as int?,
          password: json['pw'] as String?,
        );
      case 'webdavMerged':
        return WebDavMergedSource(
          connectionId: json['connectionId'] as String? ?? '',
          rootUrl: json['rootUrl'] as String? ?? '',
          members: [
            for (final m in (json['members'] as List? ?? const []))
              WebDavMergedMember.fromJson(m as Map<String, dynamic>),
          ],
        );
      case 'archive':
      default:
        return ArchiveSourceSpec(
          path: json['path'] as String,
          format: json['format'] as String? ?? 'zip',
          password: json['pw'] as String?,
        );
    }
  }
}

/// 压缩包：阅读时用 ZipArchiveSource 按需读条目
final class ArchiveSourceSpec extends BookSource {
  const ArchiveSourceSpec({
    required this.path,
    this.format = 'zip',
    this.password,
  });

  /// app 私有目录内的绝对路径（导入时从 file_picker 的临时位置复制过来）
  final String path;
  final String format; // zip | tar | rar | 7z

  /// 加密压缩包的密码（ZipCrypto）。
  ///
  /// 必须存下来：加密 zip 的**每一页**都要解密才能读，不存的话
  /// 每次翻页都得重新问一遍用户。
  final String? password;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'archive',
        'path': path,
        'format': format,
        if (password != null && password!.isNotEmpty) 'pw': password,
      };
}

/// 文件夹：阅读时直接按相对路径拼绝对路径
final class FolderSource extends BookSource {
  const FolderSource(this.path);
  final String path;

  @override
  Map<String, dynamic> toJson() => {'type': 'folder', 'path': path};
}

/// 散图：一批独立的图片文件
final class LooseFilesSource extends BookSource {
  const LooseFilesSource(this.paths);
  final List<String> paths;

  @override
  Map<String, dynamic> toJson() => {'type': 'looseFiles', 'paths': paths};
}

/// 网络（WebDAV / NAS）上的一个文件夹
///
/// 只记录**连接 id + 文件夹地址**，凭据单独存在连接表里。
/// 这样：
///   · 密码改了只要更新连接表，不用重导入每一本书；
///   · 导出的书目 JSON 里不会混进密码。
final class WebDavSource extends BookSource {
  const WebDavSource({
    required this.connectionId,
    required this.folderUrl,
    required this.folderName,
  });

  final String connectionId;

  /// 文件夹的绝对 URL（已编码）
  final String folderUrl;

  /// 文件夹显示名（书籍标题的来源之一）
  final String folderName;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'webdav',
        'connectionId': connectionId,
        'folderUrl': folderUrl,
        'folderName': folderName,
      };
}

/// 网络（WebDAV / NAS）上的一个**压缩包**
///
/// 和 [WebDavSource]（一个文件夹）并列：商用网盘上的漫画常常是
/// 一话一个 zip，那么"一本书 = 一个包"。
///
/// 阅读时靠 HTTP Range 只读中央目录 + 当前页的压缩数据，
/// **不会下载整个压缩包**。
final class WebDavArchiveSource extends BookSource {
  const WebDavArchiveSource({
    required this.connectionId,
    required this.archiveUrl,
    required this.archiveName,
    this.archiveSize,
    this.password,
  });

  final String connectionId;

  /// 压缩包的绝对 URL（已编码）
  final String archiveUrl;

  /// 压缩包显示名（书籍标题的来源）
  final String archiveName;

  /// 包总字节数（目录列表里就有，省一次 PROPFIND）
  final int? archiveSize;

  /// 加密包（ZipCrypto）的密码。导入/开书时从密码字典试出后固化到这里，
  /// 下次开书直接可用，不再逐个试字典或弹框。
  final String? password;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'webdavArchive',
        'connectionId': connectionId,
        'archiveUrl': archiveUrl,
        'archiveName': archiveName,
        if (archiveSize != null) 'archiveSize': archiveSize,
        if (password != null && password!.isNotEmpty) 'pw': password,
      };
}

/// 同名合并书的成员：一个 WebDAV 上的文件夹或压缩包。
///
/// 合并书 = 这些成员各占一个章节。成员列表同时承担两个职责：
/// 兜底重建（缓存文档丢失后逐成员重建再拼接）与判重（重新扫描时
/// 成员 URL 已在库中则跳过）。
class WebDavMergedMember {
  const WebDavMergedMember({
    required this.url,
    required this.name,
    this.isArchive = false,
    this.archiveSize,
    this.password,
  });

  /// 成员的绝对 URL（文件夹目录 / 压缩包文件）
  final String url;

  /// 显示名（章节标题来源；压缩包保留后缀以区分重复下载）
  final String name;

  final bool isArchive;
  final int? archiveSize;

  /// 加密包密码（导入时试出后固化）
  final String? password;

  Map<String, dynamic> toJson() => {
        'u': url,
        'n': name,
        'a': isArchive,
        if (archiveSize != null) 's': archiveSize,
        if (password != null && password!.isNotEmpty) 'pw': password,
      };

  static WebDavMergedMember fromJson(Map<String, dynamic> json) =>
      WebDavMergedMember(
        url: json['u'] as String? ?? '',
        name: json['n'] as String? ?? '',
        isArchive: json['a'] as bool? ?? false,
        archiveSize: json['s'] as int?,
        password: json['pw'] as String?,
      );
}

/// 网络上多个**同名来源**合并成的一本书（同名漫画自动合并）。
///
/// 例：网盘上同时存在 `海贼王.zip` 与 `海贼王.cbz`（或同名文件夹与包），
/// 导入时合并为一本书，每个来源一个章节。缓存文档丢失时按成员重建。
final class WebDavMergedSource extends BookSource {
  const WebDavMergedSource({
    required this.connectionId,
    required this.rootUrl,
    required this.members,
  });

  final String connectionId;

  /// 导入时扫描的库根目录（记录用；兜底重建按成员进行，不重扫根目录）
  final String rootUrl;

  /// 成员列表（≥2；各占一章，顺序 = 合并时的章节顺序）
  final List<WebDavMergedMember> members;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'webdavMerged',
        'connectionId': connectionId,
        'rootUrl': rootUrl,
        'members': [for (final m in members) m.toJson()],
      };
}

// ---------------------------------------------------------------------------

class BookMeta {
  BookMeta({
    required this.id,
    required this.title,
    required this.kind,
    required this.source,
    required this.pageCount,
    required this.importedAt,
    this.chapterCount = 1,
    this.coverPath,
    this.author,
    this.isFavorite = false,
    this.lastReadAt,
    this.description,
  });

  final String id;
  String title;
  final BookKind kind;
  final BookSource source;
  final int pageCount;
  final int chapterCount;
  final DateTime importedAt;

  /// 封面缓存文件路径（由首次阅读时生成，见 CoverExtractor）
  String? coverPath;
  String? author;
  final String? description;
  bool isFavorite;
  DateTime? lastReadAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'kind': kind.name,
        'source': source.toJson(),
        'pageCount': pageCount,
        'chapterCount': chapterCount,
        'importedAt': importedAt.toIso8601String(),
        'coverPath': coverPath,
        'author': author,
        'isFavorite': isFavorite,
        'lastReadAt': lastReadAt?.toIso8601String(),
        'description': description,
      };

  static BookMeta fromJson(Map<String, dynamic> json) => BookMeta(
        id: json['id'] as String,
        title: json['title'] as String,
        kind: BookKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => BookKind.comic,
        ),
        source: BookSource.fromJson(
            (json['source'] as Map).cast<String, dynamic>()),
        pageCount: json['pageCount'] as int? ?? 0,
        chapterCount: json['chapterCount'] as int? ?? 1,
        importedAt: DateTime.tryParse(json['importedAt'] as String? ?? '') ??
            DateTime.now(),
        coverPath: json['coverPath'] as String?,
        author: json['author'] as String?,
        isFavorite: json['isFavorite'] as bool? ?? false,
        lastReadAt: DateTime.tryParse(json['lastReadAt'] as String? ?? ''),
        description: json['description'] as String?,
      );
}
