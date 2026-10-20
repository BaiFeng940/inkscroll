# 同步到 GitCode（国内镜像）

> **为什么需要这一步**：GitCode 的「从 GitHub 导入」需要**用 GitHub 账号授权登录**
> 才能读到你名下的仓库。OAuth 授权只能在浏览器里由账号本人完成，
> 自动化脚本无法代替 —— 所以仓库的**创建**必须你手动点一次。
> 创建完成后，后续所有推送都可以用脚本自动完成。

---

## 一、创建镜像仓库（一次性，约 2 分钟）

1. 打开 <https://gitcode.com>
2. 右上角 **登录** → 选择 **GitHub 登录**
3. 首次会要求授权 GitCode 读取你的 GitHub 公开仓库信息 → 同意
4. 登录后点右上角 **`+`** → **导入仓库**（有的版本叫「迁移 GitHub 仓库」）
5. 填：
   - 源仓库地址：`https://github.com/BaiFeng940/inkscroll`
   - 目标仓库名：`inkscroll`
   - 可见性：**公开**
6. 点 **导入**，等它拉完（几十秒）

完成后你的仓库地址是：

```
https://gitcode.com/BaiFeng940/inkscroll
```

> 如果 GitCode 占用了 `BaiFeng940` 这个名字，它会给你另一个路径。
> **把实际路径告诉我**，我改 `lib/app_version.dart` 里的
> `kGitCodeOwner` / `kGitCodeRepo` 两个常量即可。

---

## 二、验证镜像可用

导入完成后，用浏览器打开下面这个地址：

```
https://api.gitcode.com/api/v5/repos/BaiFeng940/inkscroll/releases/latest
```

- 返回 JSON（含 `tag_name`）→ **可以了**
- 返回 404 → 说明 GitCode 还没同步 release，需要**在 GitCode 上手动创建一次
  release**（tag 填 `v0.8.0`，附件上传 APK），或者等它自动同步

> 这一步很关键：应用检查更新时**先问 GitCode，失败才兜底 GitHub**。
> GitCode 上没有 release，就只能一直走 GitHub（国内可能很慢）。

---

## 三、之后每次发版：推送代码

仓库创建好之后，用脚本推：

```powershell
# 只需第一次设置 token
$env:GITCODE_TOKEN = '你的 GitCode 访问令牌'

# 推送 main
pwsh -File tool/push-to-gitcode.ps1
```

访问令牌在 GitCode：**头像 → 设置 → 访问令牌 → 新建**，勾选仓库读写权限。

脚本会自动：
1. 添加（或更新）名为 `gitcode` 的 remote
2. 推送 `main`
3. 推送当前所有 tag（release 靠 tag 关联）

---

## 四、每次发版：创建 release

GitCode 的 release 目前没有稳定的公开 API 文档，所以**手动创建**：

1. 打开 `https://gitcode.com/BaiFeng940/inkscroll/releases/new`
2. Tag 填和 GitHub 一致的：`v0.8.0`
3. 标题填 `inkScroll 0.8.0`
4. 附件上传 `dist/inkscroll-0.8.0-arm64-v8a.apk`
5. 发布

> 应用只依赖 `tag_name` 判断版本号、依赖附件名里的 `.apk` 找下载链接。
> 附件名建议保持 `inkscroll-<版本>-<架构>.apk` 的规范格式，
> 这样 `_pickDownload` 能优先挑出 `arm64-v8a`。

---

## 五、应用侧是怎么判定的

代码在 `lib/app_version.dart` 和 `lib/data/update_service.dart`：

```dart
const List<UpdateSource> kUpdateSources = [
  UpdateSource(name: 'GitCode（国内镜像）', apiUrl: '.../api/v5/repos/.../releases/latest'),
  UpdateSource(name: 'GitHub',              apiUrl: '.../api.github.com/.../releases/latest'),
];
```

- **顺序即优先级**：国内镜像先问，GitHub 兜底
- 版本比较走语义化比较，`0.10.0` 不会被判成比 `0.9.0` 旧
- 两个源都失败就当"已是最新"，**不会弹错误打扰用户**
- 一天最多自动检查一次；用户可「跳过此版本」

---

## 常见问题

**Q: 导入后 GitCode 一直显示"同步中"？**
A: 大仓库首次导入需要几分钟，去仓库页刷新看看。

**Q: 想让 GitCode 自动跟随 GitHub？**
A: GitCode 的镜像仓库支持「同步」按钮，但不能定时自动拉取。
   要么每次发版手动点同步，要么用上面的推送脚本。

**Q: 一定要用 GitCode 吗？**
A: 不一定。`kUpdateSources` 是个列表，加任何返回同类 JSON 的源都行。
   GitCode 只是目前国内访问最稳的选择。
---

## 六、发布流程（实测可行，照这个做）

> 以下流程已在 `0.8.0` 上完整跑通并验证。

### 谁做什么

| 步骤 | 谁做 | 命令 / 操作 |
|---|---|---|
| 1. 构建 + 发布到 GitHub | 我 | `flutter build apk --release --split-per-abi`，然后打 tag 推 GitHub |
| 2. 推代码 + tag 到 GitCode | 我 | `pwsh -File tool/push-to-gitcode.ps1` |
| 3. **在 GitCode 网页建 release 并一起上传 APK** | **你** | 见下 |
| 4. 校验镜像资产 | 我 | `pwsh -File tool/verify-gitcode-release.ps1 -Version x.y.z` |

### 第 3 步：为什么必须你来

**GitCode 的 release 附件上传接口没有公开文档，实测不通**：

| 尝试的端点 | 结果 |
|---|---|
| `POST /releases/{tag}/attach_files` | 404 |
| `POST /releases/{tag}/upload_assets` | 404 |
| `POST /releases/attach_files` | **405**（存在但不收 POST） |
| `PUT /releases/attach_files` | 405 |
| `POST /releases/{id}/attach_files` | 404 |
| `api.gitcode.com/...` 同路径 | 404 Route Not Found |

而且 release 对象**不返回 `release_id`**，所以连"按 id 上传"这条路也走不通。

**结论**：创建 release 时在网页上把 APK 一起传，是唯一可靠的方式。
所以**不要用脚本预先创建 release** —— 空 release 建出来之后还要回头编辑补附件，
不如直接一步到位。

### 网页操作要点

1. 打开 <https://gitcode.com/BaiFeng940/inkscroll/releases/new>
2. Tag 填 `v<版本>`（和 GitHub 一致，tag 必须先推上去）
3. 标题填 `inkScroll <版本>`
4. 说明复制 GitHub 上那份（保持两边文案一致）
5. **同一个表单里把两个 APK 一起拖进去**：
   ```
   dist/inkscroll-<版本>-arm64-v8a.apk
   dist/inkscroll-<版本>-armeabi-v7a.apk
   ```
6. 发布

### 第 4 步：必须校验

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tool/verify-gitcode-release.ps1 -Version 0.8.0
```

它会检查四件事：

1. release 的 tag 是否等于目标版本
2. assets 里有没有 **`type=attach` 的 `.apk`**
   （`v0.8.0.zip` / `.tar.gz` 这些是 `type=source`，**任何 tag 都自动生成，不是安装包**）
3. 每个 APK 能否真的 GET 到（206/200）
4. 下载下来的文件 SHA256 是否与本地 `dist/` 一致

> ⚠️ **脚本一律用 GET，不用 HEAD。** GitCode 对 `HEAD` 返回 **401**，
> 看起来像"文件下不了"，实际 `GET` 是 200 并重定向到 `file-cdn.gitcode.com`。
> 用 HEAD 判断会得出完全错误的结论。

### 只有第 3、4 步都过了，才算真正闭环

应用侧的顺序是 **GitCode → GitHub**，只要 GitCode 上版本号够新，
就不会再回落到 GitHub。所以镜像上的 APK 必须是**完整可下载**的，
否则用户点了「去下载」会卡在 GitCode 的 401/404 上。

代码里也做了兜底：镜像的 assets 里如果**没有** `.apk`，
`downloadUrl` 会按命名规范推导 GitHub 同版本直链 —— 但这只是保底，
国内下 GitHub 依然慢。
