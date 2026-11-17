# Android 安装交付记录 · 2026-11-16

## 最终交付 1.0.2（versionCode 3）

当前签名包 44,886,529 字节，SHA-256 `e30275f89f3f3b9f037ffc0f542dd162f9b68e3155f460b9b3ae85b187eefaee`。保留已验证的全部上传修复，并将原生工具返回的 file:// 链接渲染为关联附件名，不在对话中铺开电脑路径；代码块内的文字保留原意。已实际覆盖安装，查看新人物回复和极高档位，并点击正文里的「今日便笺.md」打开真实便笺内容。公开下载返回200，完整包大小、SHA与发布文件一致。最终界面证据为 `final-delivery-name.png`、`final-inline-attachment.png`。

以下1.0.1为上传修复过程的历史验证记录。

## 上传修复版 1.0.1（versionCode 2）

用户指出所有文件均无法上传。已确认旧 APK 未包含 Vite 未写入 manifest 的 hash worker；同时修正了 Android 网络桥不识别 Blob 分段为二进制文件的问题。构建现使用独立、全新的 `studio/dist-android`，完整打包所有产物；Android 分段通过 `File` 发送。

当前 APK：44,886,529 字节，SHA-256 `e3c9fbc0ac1474e82fb289858fe044c140011ee939e9cba6bdfd6b41100323a2`。TypeScript/Vite、Android release lint/编译、v2/v3 签名通过，已实际覆盖安装。

从 Android 系统文件选择器选取了 2,459,089 字节 PNG 及 44,886,529 字节 APK，完成上传、挂入草稿并发送到独立 Upload check 对话。大文件经 11 段 PUT 传完，complete 返回 200。读取服务器 CAS 原件后，两份 SHA-256 分别与原图、APK 完全一致。真实模型已在回复中正确列出两个附件名，并描述了图片中的窗边少女及房间场景。实际界面证据为 `runtime/android/upload-image-progress.png`、`upload-binary-result.png`。

以下为原 1.0 交付的历史记录，旧哈希不代表当前修复包。

本次交付范围：可直接下载的签名 APK、外网连接、真实聊天、连接恢复、手机界面与文件保存。没有将完整产品宪章标记为完成。

最终文件：`releases/hajisaki-android.apk`，45,002,524 字节（42.92 MiB）。SHA-256：

```text
ba8dea129a9674a76353eef21681935c723178706c9781c6b863076a52513728
```

已实际执行的检查：

- TypeScript/Vite 构建通过；Android `assembleRelease`、发布 lint 通过；`apksigner verify` 的 v2/v3 签名通过。清单包名 `com.hajisaki.android`，minSdk 24、targetSdk 36，无定位权限。
- 最终 APK 在独立 Android 15 / WebView 110 环境安装、启动成功。多次升级安装与重新打开后，AndroidKeyStore 中的连接可恢复；无需重新输入连接码。
- 通过 APK 的连接界面签发并保存独立设备凭据，经公网 HTTPS 入口加载主机状态、历史会话、模型、档案。正式用户包的首次连接码尚未被验证设备占用。
- 从 App 输入并发送 `Please reply only: Android app works.`，真实 Antigravity ACP 完成回复 `Android app works.`。切换 Gemini 4 Argon 与低强度后的消息收到 `Selected model connected.`，无活跃运行残留。
- 最终集成界面的浅色首页、聊天、档案、主机状态，以及模型家族面板、独立强度面板已查看实际截图。模型面板在底部限高滚动，强度显示为独立选项。
- Markdown 文件经手机打开并显示真实内容；点击保存后，在 Android 下载目录读回 1,072 字节。SHA-256 `c4c32ba294e7c1960582f648a37117364b5f85cf6c1313db2d5bc7a19723d5ef`，与服务器原件一致。验证时发现系统选择器未授予写权限，已采用 Android 10+ 标准 MediaStore.Downloads 保存路径并重查。
- 最终公开 HTTPS 下载入口返回 200；完整下载 45,002,524 字节，SHA-256 与上述最终 APK 一致。本地所有者配对入口经手机入口返回 403；未带设备凭据访问会话返回 401。

图像与原始界面树保存在 `runtime/android/`，主要记录为 `final-home.png`、`final-archive.png`、`release-chat.png`、`release-models.png`、`release-strength.png`、`release-host.png`、`download-result.png`。编译记录保存在 ASCII 构建目录 `build.log`。

边界：尚未在用户自己的手机、其实际运营商网络上安装验证；Android 7–9 的系统保存分支没有设备实测。录音、长文件、全部富文本格式、弱网恢复、持续性能等没有在本次 Android 交付中穷尽验证。当前 Quick Tunnel 地址依赖电脑和现有出站进程在线，重启后可能变化，不能称为长期稳定部署。

本次新增/修改的主要文件：`phone/android/` 工程与构建工具；`tools/mobile_gateway.py`、`tools/mobile_host.py`；`studio/src/android.ts`、`android.css`、`model-families.ts`、`api.ts`、`main.ts`、`style.css` 及对应依赖清单；最终 APK 与散列清单。原有 Harmony HAP、iPad 工程及其数据保留。

清理：已直接移入回收站 `runtime/android-signing/keystore-password.txt`（0.062 KB）、未采用的 `phone/android/tools/emulator.py`（3.417 KB），以及下载验证产生的三个零字节文件 `app-harness-handoff.md`、`app-harness-handoff (1).md`、`app-harness-handoff (2).md`（各 0 KB）。有效下载原件、编译记录、SDK 和诊断证据保留；这些是文件逻辑大小，并非已释放磁盘空间。

服务端只读运行记录确认所选模型为 `gemini-4-argon-low`、强度 `low`、运行状态 `completed`。验证用 MuMu 5 已通过正常关闭入口停止，手机 HTTPS 网关及出站连接继续运行。

1.0.1 本轮已直接移入回收站的传输副本：`HajiSaki-day-room.png`（2401.45 KB）、`HajiSaki-1.0.1.apk`（43834.50 KB）；服务器原件、聊天记录、实际界面和散列证据保留。Upload check 验证对话已归档，未删除。
