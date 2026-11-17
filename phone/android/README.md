# 哈基祥 Android 安装包

真实 Android APK，包名 `com.hajisaki.android`，Android 7 / API 24 起，目标 API 36。它与 `phone/harmony` 的诊断 HAP 分开构建。APK 使用本工程固定发布密钥签名；后续更新需保留该密钥。

安装 `releases/hajisaki-android.apk` 后，点「连接我的琴房」。私有安装包内含仅能绑定一台设备的七天首次连接码；成功连接后的设备凭据通过 AndroidKeyStore AES-GCM 保存。不要公开转发此包或私有下载链接。

## 网络与主机

手机访问独立 HTTPS 入口，不要求数据线或同一 Wi-Fi。电脑主网关 8765、手机入口 8766 和出站连接都需在线。当前使用 Cloudflare Quick Tunnel：地址在进程重启后可能变化，属于临时交付入口，没有长期可用性保证。客户端通过现有消息快照/事件接口轮询；不依赖该通道不支持的 SSE。

启动/查看入口：

```text
.venv\Scripts\python.exe -X utf8 -B tools/mobile_host.py start
.venv\Scripts\python.exe -X utf8 -B tools/mobile_host.py status
```

网关代码更新后加 `--restart-gateway`，保留原出站连接。`--invite-name <name>` 可签发新的首次连接码文件。运行凭据及下载口令位于受 ACL 保护的 `runtime/mobile/`；源代码中只留空白配置模板。电脑重启后需重新启动入口、更新安装包内的入口地址，或通过 App「主机 → 重新配对」输入新的 base64url JSON 连接码（`origin`、`code`）。此版本没有新增系统服务或开机自启。

手机入口限制 API 路由，保留主网关认证；本地所有者配对、设备管理、代理工具内部端点不对外提供。

## 构建

需要 Python 项目环境、Node 24、JDK 21。SDK 从 Google 官方仓库下载并核对其官方校验值；当前构建工具统一使用 36.0.0。

```text
.venv\Scripts\python.exe -B phone/android/tools/prepare_sdk.py
.venv\Scripts\python.exe -B tools/run.py --cwd studio -- npm ci
.venv\Scripts\python.exe -B tools/run.py --cwd phone/android -- npm ci
.venv\Scripts\python.exe -X utf8 -B phone/android/tools/build.py
```

构建脚本先将前端完整编译到独立的 `studio/dist-android` 并打包所有产物，包括上传校验和图片透视 worker；不再从 Vite manifest 猜测完整文件集合。

Windows Java 工具对本机中文路径处理不一致，因此构建使用有归属标记的 ASCII 暂存目录 `C:/Users/17601/HajiSakiAndroidBuild`。发布密钥和口令在受 ACL 保护的 `C:/Users/17601/HajiSakiAndroidSigning`。签名校验、最终大小与 SHA-256 写入 `releases/hajisaki-android.manifest.json`，完整编译记录保存在暂存目录 `build.log`。

界面沿用现有琴房资源。模型按家族显示，思考强度另选，发送时保留真实服务端模型别名；底部模型面板不超过视口高度 45%。Android 10 起直接流式保存到系统下载目录，较早版本使用系统文件选择器。麦克风在用户使用录音时请求权限；不申请定位权限。

当前安装验证使用单独 Android 15 设备。验证结果不等同于已在用户自己的手机或所在运营商网络实测，也不代表原产品宪章的所有能力已完成。
