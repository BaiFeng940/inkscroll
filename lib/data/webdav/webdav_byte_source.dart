/// 基于 **HTTP Range** 的随机访问字节源。
///
/// ## 为什么需要它
///
/// 这是"网盘上的压缩包也能在线读"的物理基础。
///
/// 已有 `FileByteSource` 让本地 zip 可以只读中央目录 + 单个条目；把同一套
/// `ZipArchiveSource` 嫁接到"能任意偏移读取的远端对象"上，网盘上的 zip 就
/// 自动获得同样能力 —— 完全不用改 ZIP 解析代码。
///
/// ## 商用网盘的关键坑：GET 会 302 到 CDN
///
/// 实测 123云盘：`GET` 返回 `302` 跳到 CDN 签名地址，再由 CDN 返回内容。
/// 好消息是 `package:http` 默认跟随重定向，且**Range 头会被带过去**，
/// 所以调用方拿到的就是 `206` + 正确字节数。这条链路已在真机数据上验证：
///
/// ```
/// 文件 1,335,522 字节
///   → Range 尾部 64KB        206, 65536 字节
///   → Range 读中央目录        206, 265/265 字节
///   → Range 读单条目压缩数据  206, 267,010/267,010 字节
/// ```
///
/// ## 省流量的数量级
///
/// 一个 500MB 的漫画包：只读目录约 1~10KB，之后每翻一页才拉那一页的
/// 压缩数据。**不需要下载整包**。
library;

import 'dart:typed_data';

import '../../core/errors.dart';
import '../byte_source.dart';
import 'webdav_client.dart';

/// 用 WebDAV（+ Range）实现任意偏移读取。
///
/// 每次 [read] 就是一次 HTTP Range 请求。`ZipArchiveSource` 打开时
/// 只发 1~2 次（读 EOCD + 中央目录），之后每个条目一次。
class WebDavByteSource implements RandomAccessByteSource {
  WebDavByteSource({
    required this.url,
    required this.client,
    int? knownSize,
  }) : _length = knownSize;

  /// 文件的绝对 URL
  final String url;

  final WebDavClient client;

  int? _length;
  bool _closed = false;

  /// 统计：发了多少次请求、拉了多少字节 —— 用来在日志/诊断里证明
  /// "确实没有下载整包"。
  int requestCount = 0;
  int bytesFetched = 0;

  @override
  Future<int> length() async {
    if (_closed) throw StateError('WebDavByteSource 已关闭');
    final cached = _length;
    if (cached != null) return cached;
    final len = await client.contentLength(url);
    _length = len;
    return len;
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (_closed) throw StateError('WebDavByteSource 已关闭');
    if (offset < 0) throw ArgumentError('offset 不能为负: $offset');
    if (length <= 0) return Uint8List(0);

    // 越界钳制：ZIP 解析器会用"文件尾附近"的范围读 EOCD，
    // 但个别实现会多要几个字节，钳一下避免服务器返回 416。
    final total = await this.length();
    if (offset >= total) return Uint8List(0);
    final end = (offset + length).clamp(0, total);
    final want = end - offset;

    requestCount++;
    final bytes = await client.getRangeAt(url, offset, want);
    bytesFetched += bytes.length;

    if (bytes.length > want) {
      // 服务器忽略了 Range 返回全量 —— 截断即可，调用方只关心那一段
      return Uint8List.sublistView(bytes, 0, want);
    }
    return bytes;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  String toString() =>
      'WebDavByteSource($url, 请求 $requestCount 次, '
      '${(bytesFetched / 1024).toStringAsFixed(1)} KB)';
}

/// 诊断信息，供 UI/日志展示"这次读包花了多少流量"。
class WebDavByteSourceStats {
  const WebDavByteSourceStats({
    required this.requests,
    required this.bytes,
  });
  final int requests;
  final int bytes;
}

/// 把异常转成项目内统一的 [AppError]（便于 UI 给出可读提示）。
AppError mapToAppError(Object error, String url) {
  if (error is AppError) return error;
  return NetworkUnreachableError(address: url, detail: '$error');
}
