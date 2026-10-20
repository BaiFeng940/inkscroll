import 'package:inkscroll/data/update_service.dart';
import 'package:inkscroll/app_version.dart';

Future<void> main() async {
  print('当前版本: $kAppVersion');
  final svc = UpdateService();
  final r = await svc.check();
  print('是否完成检查: ${r.checked}');
  print('来源: ${r.sourceName}');
  print('远端版本: ${r.latest}');
  print('有更新: ${r.hasUpdate}');
  print('下载地址: ${r.downloadUrl}');
  svc.close();
}