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