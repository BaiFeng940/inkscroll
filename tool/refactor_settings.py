# 把设置页里的三段超长内联文本改成「点击弹窗」的紧凑条目。
# 用行号做精确手术（自底向上改，避免行号漂移）。
import io, os, sys

PATH = r"D:\DSH Desktop\work\flutter-comic-reader\lib\ui\settings_screen.dart"
with io.open(PATH, encoding="utf-8") as f:
    lines = f.read().split("\n")


def splice(start, end, new_text):
    """把 1-based 闭区间 [start, end] 换成 new_text 的行。"""
    new_lines = new_text.split("\n")
    lines[start - 1:end] = new_lines
    return len(new_lines) - (end - start + 1)


# ── 3) 在线库说明 → 弹窗（原 415..440）────────────────────────────────
ONLINE = '''          // 说明收进弹窗：这段文字原来占了近 3 屏，把连接列表挤到看不见
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('支持哪些网盘？'),
            subtitle: const Text('WebDAV 通用：私有云与商用网盘都能连'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showInfo(
              title: '支持的网盘',
              body: '任何标准 WebDAV 服务都能连：\\n\\n'
                  '· 私有云：飞牛 fnOS、群晖、威联通、TrueNAS\\n'
                  '· 商用网盘：123云盘、坚果云、Nextcloud、Alist\\n\\n'
                  '百度网盘、阿里云盘这类「不自带 WebDAV」的，需要先用 '
                  'Alist 之类的网关转成 WebDAV 再连。\\n\\n'
                  '连接后选一个目录：它下面每个含图片的子文件夹都会成为一本书；'
                  '目录里的 zip / cbz 压缩包也算一本。',
            ),
          ),
'''


# ── 2) 通过压缩包导入说明 → 弹窗（原 318..361）────────────────────────
ARCHIVE = '''          // ── 压缩包 ──
          ListTile(
            leading: const Icon(Icons.folder_zip_outlined),
            title: const Text('压缩包导入说明'),
            subtitle: const Text('支持格式、网盘压缩包、导入耗时与加密'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showInfo(
              title: '通过压缩包导入',
              body: '支持的格式：.zip / .cbz（推荐）、.tar\\n'
                  '包内图片支持 JPG / PNG / GIF / WebP / BMP / AVIF。\\n\\n'
                  '网盘上的压缩包也能直接导入：不用先下载到手机。'
                  '导入时只读目录结构，翻到哪一页才下载那一页 —— '
                  '200 MB 的包通常几秒就能建好，也不占手机空间。\\n\\n'
                  '需要一点耐心：每本压缩包都要联网读目录并抽样测量尺寸，'
                  '导入几十本的库通常要几分钟。进度条会显示处理到第几本；'
                  '请保持应用在前台，中途退出会中断这一批导入。\\n\\n'
                  '加密压缩包（ZipCrypto）需要密码，可以在下面的「密码字典」里'
                  '预先添加，导入时会自动按顺序尝试。'
                  'AES-256 加密暂不支持。',
            ),
          ),
'''


# ── 1) 屏幕刷新率说明 → 弹窗（原 273..316）────────────────────────────
REFRESH = '''          ListTile(
            leading: const Icon(Icons.speed_outlined),
            title: const Text('屏幕刷新率'),
            subtitle: const Text('想跑满 120Hz，需要你在系统设置里加白名单'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showInfo(
              title: '屏幕刷新率',
              body: 'inkScroll 会主动向系统申请高刷新率，但 Android 默认只给'
                  '系统允许列表里的应用开高刷。\\n\\n'
                  '需要你手动把本应用加进去：\\n'
                  '打开 系统设置 → 显示与亮度 → 屏幕刷新率，'
                  '找到「使用高刷新率的应用」（有的机型叫「高刷新率应用列表」'
                  '或「选择应用」），把 inkScroll 打开。\\n\\n'
                  '常见机型位置：\\n'
                  '· vivo / iQOO：设置 → 显示与亮度 → 屏幕刷新率 → '
                  '使用高刷新率的应用\\n'
                  '· OPPO / 一加：设置 → 显示与亮度 → 屏幕刷新率 → 选择应用\\n'
                  '· 小米 / Redmi：设置 → 显示 → 高刷新率 → 应用列表\\n'
                  '· 华为 / 荣耀：设置 → 显示与亮度 → 屏幕刷新率\\n\\n'
                  '找不到这个选项也不影响使用：不动它照样能正常看书，'
                  '只是滑动可能停在 60Hz。系统不允许应用自己绕过这个限制。',
            ),
          ),

          const Divider(height: 24),'''

# 自底向上手术
splice(415, 440, ONLINE)
splice(318, 361, ARCHIVE)
splice(273, 316, REFRESH)

src = "\n".join(lines)

# 加 _showInfo 辅助方法
HELPER = '''  /// 统一的「说明」弹窗。
  ///
  /// 设置里原本把几段长说明直接铺在列表里，最长的一段占了三屏，
  /// 把真正要操作的东西（连接列表、开关）挤到了看不见的地方。
  /// 现在一律收进弹窗：列表只留一行标题 + 一行摘要。
  Future<void> _showInfo({required String title, required String body}) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Text(
              body,
              style: const TextStyle(fontSize: 13.5, height: 1.7),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 管理压缩包密码字典。'''

anchor = "  /// 管理压缩包密码字典。"
if anchor in src and "_showInfo({" not in src:
    src = src.replace(anchor, HELPER, 1)
    print("已插入 _showInfo")
else:
    print("警告：_showInfo 未插入（锚点缺失或已存在）")

with io.open(PATH, "w", encoding="utf-8", newline="\r\n") as f:
    f.write(src)
print("完成，总行数:", len(src.split("\n")))
