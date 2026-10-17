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
      case 'archive':
      default:
        return ArchiveSourceSpec(
          path: json['path'] as String,
          format: json['format'] as String? ?? 'zip',
        );
    }
  }
}

/// 压缩包：阅读时用 ZipArchiveSource 按需读条目
final class ArchiveSourceSpec extends BookSource {
  const ArchiveSourceSpec({required this.path, this.format = 'zip'});

  /// app 私有目录内的绝对路径（导入时从 file_picker 的临时位置复制过来）
  final String path;
  final String format; // zip | tar | rar | 7z

  @override
  Map<String, dynamic> toJson() => {'type': 'archive', 'path': path, 'format': format};
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
        source: BookSource.fromJson((json['source'] as Map).cast<String, dynamic>()),
        pageCount: json['pageCount'] as int? ?? 0,
        chapterCount: json['chapterCount'] as int? ?? 1,
        importedAt: DateTime.tryParse(json['importedAt'] as String? ?? '') ?? DateTime.now(),
        coverPath: json['coverPath'] as String?,
        author: json['author'] as String?,
        isFavorite: json['isFavorite'] as bool? ?? false,
        lastReadAt: DateTime.tryParse(json['lastReadAt'] as String? ?? ''),
        description: json['description'] as String?,
      );
}
