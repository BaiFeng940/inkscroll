# GitCode 镜像实测结论（0.8.0）

## assets 实测

`GET /api/v5/repos/BaiFeng940/inkscroll/releases/tags/v0.8.0?include_assets=true`

手动上传的两个 APK 会以 `type: "attach"` 出现在 assets 里：

```json
{"browser_download_url":"https://gitcode.com/BaiFeng940/inkscroll/releases/download/v0.8.0/inkscroll-0.8.0-arm64-v8a.apk",
 "name":"inkscroll-0.8.0-arm64-v8a.apk","type":"attach","id":260317}
```

源码包是 `type: "source"`（`v0.8.0.zip/.tar.gz/.tar.bz2/.tar`），
**任何有 tag 的仓库都会自动生成，不是安装包** —— 别被文件名骗了。

## 下载行为（重要）

| 请求方式 | 结果 |
|---|---|
| `HEAD` | **401**（GitCode 拒绝 HEAD，不代表文件不可用） |
| `GET` | **200**，重定向到 CDN |
| `GET` + `Range` | **206**，`application/vnd.android.package-archive` |

重定向后的真实地址：

```
https://file-cdn.gitcode.com/<repoId>/releases/untagger_<hash>/<name>?auth_key=...
```

实测（家宽）：**18.62 MB / 2.7 秒 / 56 Mbps**，SHA256 与本地构建产物一致。

## 结论

- 应用内「检查更新」→ GitCode 拿版本号 ✅
- 应用内「去下载」→ 交给系统浏览器 GET，浏览器会跟重定向 ✅
- **不要用 HEAD 探测**，会得到误导性的 401

---

# 0.14.0 追加实测（2026-10）

## release **对象**可以用 API 建（附件仍然不行）

`POST /api/v5/repos/BaiFeng940/inkscroll/releases?access_token=…`

```json
{"tag_name":"v0.14.0","name":"inkScroll 0.14.0","body":"<UTF-8 正文>",
 "target_commitish":"main","prerelease":false}
```

- 返回 **200**，`tag_name` / `name` / `body` / `target_commitish`（这里是 commit sha）都正确落库
- 响应里**依然没有 `release_id`**（老结论继续成立），所以后续要拿 id 的地方没法做
- 附件上传实测仍是 **404**：`POST /releases//assets`、`/releases//attach_files`、
  `/releases/assets` 全部 404 —— **APK 只能网页手传**
- 建完 release 后，`GET /releases/tags/v0.14.0?include_assets=true` 的 `assets`
  里只有 4 个 `type:"source"` 的源码包（`v0.14.0.zip/.tar.gz/.tar.bz2/.tar`），
  **没有 attach**，也就是"页面看着有文件，但不是安装包"

> 另外：截至 0.14.0，GitCode 上只有 **v0.8.0** 和 **v0.14.0** 两个 release
> （0.9~0.13 只发了 GitHub）。应用内更新检查是「GitCode 优先 → GitHub 兜底」，
> 所以缺版本不会导致更新检查失败。

## 核对内容别用 `/raw/`

`GET https://gitcode.com/BaiFeng940/inkscroll/raw/main/pubspec.yaml` 现在返回的是
**SPA 的 HTML 外壳**（HTTP 200，5792 字节，`<!DOCTYPE html>`），不是文件内容 ——
拿它比对"代码推上去了没有"会得到假结果。

可靠做法是比对 **git 对象的 tree sha**（内容寻址，天然逐字节）：

```powershell
git fetch --no-tags https://gitcode.com/BaiFeng940/inkscroll.git `
    "+refs/heads/main:refs/remotes/gc/main" "+refs/tags/v0.14.0:refs/tags/gc-check/v0.14.0"
git rev-parse "refs/remotes/gc/main^{tree}"   # 与 GitHub 同 commit 的 tree 比即可
```

0.14.0 实测：两侧 `main` 都是 `63fa0a2`，tree 都是 `9e01ad0`，`git diff` 为空。

## 强制对齐的实际形态

GitCode 的 `main` 原来停在 `1cee232`（**本地链**），而 GitHub 走 API 后是另一条链
（`e5ee7ce` → `63fa0a2`）。所以推 main 必须 `push -f`：

```
+ 1cee232...63fa0a2 gh/main -> main (forced update)
```

推 tag 不需要 force（`refs/tags/v0.14.0` 是新增）。
