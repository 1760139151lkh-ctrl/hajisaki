# 哈基祥 · HajiSaki

## 最新双端快照 · 2026-11-17

本仓库收录当前手机端、iPad 端及共享 Windows 主机的最新工作区源码和必要资源。

| 客户端 | 当前交付 | 入口 |
| --- | --- | --- |
| Android 手机 | 1.0.2（3），已签名 APK，Android 7+ | `phone/android/` |
| iPad | 0.1.0（7），未签名 IPA，iPadOS 18+ | `ipad/` |
| Harmony / OpenHarmony | API 26 常规及临时预览未签名 debug HAP | `phone/harmony/` |
| Windows 主机及网页控制台 | 共享网关、模型通道、文件与资料库 | `host/`、`studio/` |

安装包在[私有 Release](https://github.com/1760139151lkh-ctrl/hajisaki/releases/tag/snapshot-2026-11-17)下载；实际大小和 SHA-256 见 `releases/snapshot-2026-11-17.json`。iPad IPA 需要正常 Apple 签名；HAP 为诊断构建，安装与设备验收边界保留在各端文档。

仓库排除本机聊天数据库、配对凭据、签名私钥、SDK、依赖缓存、历史构建和可能包含会话内容的原始检查记录；这些文件保留在本机。Android 私有 APK 仍含既有的单设备限时首次连接码，不应公开分发。克隆后按下方及各端 README 安装依赖，并为自己的主机准备登录、配对和签名。

## 项目说明

私人陪伴琴房与 Windows 主机网关，包含 HarmonyOS 原生工程、可运行的本地控制台、持久化消息与文件仓。产品目标仍是完整宪章；当前实现和实测范围分别记录，不以演示替代验收。

人物以用户“在场”项目的少年感祥子原图为准：浅蓝长发、金色眼睛、柔和脸型与制服气质。原图来源和生成提示词在 `assets_pipeline/`；旧版成熟化候选不作为成品。

界面设计语言“公主的小客厅”（瓷白与玫瑰、古金细线、她的缎带与冠冕、火漆爱心，以及手机与 iPad 共用的色值与字体）见 `docs/ui-design-language.md`。

## 本机打开

本次工作已建立项目自己的 `.venv` 和前端构建产物。主控制台地址为 **http://127.0.0.1:8765**。初次打开选择“连接琴房 → 连接这台电脑”，不会把配对令牌放进网址。

双击 `HajiSaki.pyw` 可静默启动真实模型网关。当前项目配置选用 Antigravity ACP，复用本机 `agy` 的正常登录态，使用 `runtime/host-settings.json` 中的本机代理。无登录态时仍可保存记录，模型登录需要本人完成。不会自动使用额外付费 API 或额度。

显式启动本地演练（回复明确标为非 AI）：

```powershell
.venv/Scripts/python.exe tools/supervisor.py start --provider development
.venv/Scripts/python.exe tools/supervisor.py status
.venv/Scripts/python.exe tools/supervisor.py stop
```

切换运行模式前先停止当前网关，并用 `status` 确认已停止。`start` 会保留已运行实例，不会悄悄改变它的模式。浏览器和原生客户端独立保存草稿；主机数据库及原件位于 `runtime/`，不得作为临时缓存清理。

真实模型模式：

```powershell
.venv/Scripts/python.exe tools/supervisor.py start --provider agy --proxy-url http://127.0.0.1:10808
python tools/discover_models.py
```

代理地址必须对应本机实际可用代理。手机不需要访问 Google；真实外网手机连接还需完成私有通道部署。当前默认只监听环回。

## 从源码准备

需要 Python 3.12+、Node.js 22+；运行依赖均安装到项目本身，不依赖 Codex 会话。

```powershell
python tools/run.py -- python -m venv .venv
python tools/run.py -- .venv/Scripts/python.exe -m pip install -r host/requirements.lock.txt
python tools/run.py --cwd studio -- npm ci
python tools/run.py --cwd studio -- npm run build
```

主机 API、附件解析和交付桥详见 `host/README.md`。`tools/run.py` 和后台监督器采用无控制台进程启动，正常运行不会主动打开 PowerShell/CMD 窗口。

## 原生工程

`phone/harmony/` 是 ArkTS/ArkUI 原生源工程，目标是 HarmonyOS 26。`phone/harmony/tools/build.py` 支持真实 DevEco SDK 和单独标识的 OpenHarmony 兼容性构建。工具链拒绝中文或符号链接工程路径时，使用 ASCII 构建暂存目录，原源码仍保留本目录。`ipad/` 由独立平板任务维护；共享主机、资源和控制台留在外层。

```powershell
python phone/harmony/tools/sync_resources.py
python phone/harmony/tools/build.py --product default --sdk C:/path/to/HarmonyOS/sdk --build-dir C:/HajiSakiNativeBuild
```

华为 SDK、应用签名、手机调试和实况窗权益与公开 OpenHarmony 构建是不同条件。编译产物、离屏预览和设备性能应分别验收。MuMu 的 Android 环境只用于兼容路径，不能运行或验收原生 HAP。

已实际输出的两个 API26 未签名 debug HAP、构建日志与摘要清单在 `releases/`。普通存储包与显式临时预览包分别标识；当前实际交互和后续本人条件见 `phone/docs/README.md`。

手机输入区的 `@` 可选择电脑代码、文件夹或已有对话，收成可审阅的引用附件后再发送。主机控制台“可引用的代码目录”负责新增和停用目录；手机只看到主人开放的名称。用法、真实模型读取记录和当前验收状态见 `phone/docs/native-references.md`。

`/` 可选择常用起笔、当前乐章语气或整理长上下文。模板先进入草稿；语气随本轮消息保存。整理保留原始记录，使用模型声明的原生命令并核对实际用量；当前真实续聊已确认74882→25976 tokens且关键事实保留。确认过程与设备验收边界见 `phone/docs/native-composer.md`。

## 数据与边界

- 聊天、事件序号、记忆和设置使用 SQLite WAL；文件按 SHA-256 存储并支持分段续传。
- 真实 CLI 对话默认受严格工具权限约束。尚未接通手机批准链路的危险操作保持拒绝。
- “心声”只接收可公开的工作摘要；不生成或索取隐私推理过程。
- 删除记忆会转交系统回收站；不会声称永久粉碎。所有位置服务始终禁用。
- 目录 `docs/` 保留原始宪章、接口合同、平台依据与实测记录。完整功能与量化验收尚未全部完成，参见 `docs/acceptance-ledger.md`。
