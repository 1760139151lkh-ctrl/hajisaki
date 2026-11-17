# 平台环境核查

核查日期：2026-11-15（用户时区 America/Los_Angeles）。本文记录实际观察，不代表完整产品验收。

## 已实际运行的工具

| 工具 | 实际结果 | 位置 |
| --- | --- | --- |
| Antigravity 桌面 | 文件版本 2.32.1，已有运行进程 | `C:/Users/17601/AppData/Local/Programs/antigravity/Antigravity.exe` |
| Antigravity CLI | `--version` 返回 1.5.9 | `C:/Users/17601/AppData/Local/agy/bin/agy.exe` |
| Java | Microsoft OpenJDK 21.0.13.0.2 | `C:/Program Files/Microsoft/jdk-21.0.13.21-hotspot/bin/java.exe` |
| Node | `v24.18.0` | 现有系统 PATH |
| Hvigor | `--version` 返回 6.26.1 | `tooling/command-line-tools/hvigor/bin/hvigorw.js` |
| ohpm | `--version` 返回 26.0.0.410 | `tooling/command-line-tools/ohpm/bin/pm-cli.js` |
| HDC | `list targets` 返回 `[Empty]` | `C:/Users/17601/Documents/Codex/2026-09-09/wo-d/work/hdc-current/hdc.exe` |
| MuMu | 注册表版本 6.3.0；已有 Android 12、15 实例目录 | `C:/Program Files/Netease/MuMu` |

系统 Python 没有安装 `google-antigravity`。未找到完整 DevEco Studio 或已安装的 HarmonyOS API 26 SDK；检查了常见安装路径、注册表、Desktop、Documents、Downloads，但没有将有限搜索描述为整盘不存在。

历史 HDC 的配套清单为 OpenHarmony API 23 / 6.1.0.31；另有旧 API 9 / 3.2.3.6 工具链。HDC 能枚举设备不等于存在可用 SDK。

随后发现已有的完整 OpenHarmony 6.1 Release 公共档案，依据其原有官方 SHA-256 文件重新核验通过，并将 Windows `ets`、`native`、`toolchains`、`previewer`、`js` 五个组件解包至 `tooling/openharmony-sdk/23`。所有组件元数据均为 API 23 / 6.1.0.31。它用于单独的旧版公共平台编译诊断，不能冒充 HarmonyOS 26 验收。

## 下载与构建来源

`tooling/fetch_official.py` 仅下载官方公开档案到 `tooling/downloads`，检查旁侧 `.sha256`，记录来源和字节数，不更改全局 PATH、现有安装、服务或账号状态。

已取得 [华为公开镜像的 Hvigor 6.26.1 工具包](https://mirrors.huaweicloud.com/harmonyos/compiler/hvigor/6.26.1/command-line-tools.zip)，77,819,058 字节，SHA-256：

```text
6db6883a6943649e1e84f155ef2151323e5e21ba3d2b7340fd1413bb0c756079
```

档案本身的 `version.txt` 标为 **Command Line Tools linux-x64 26.0.0.461 beta**；里面的 JavaScript Hvigor/ohpm 已在此 Windows 主机实际运行。此包没有完整 SDK 或随包 Node，不应称作完整 Windows DevEco 安装。

[OpenHarmony 7.0 Release SDK](https://mirrors.huaweicloud.com/harmonyos/os/7.0-Release/ohos-sdk-windows_linux-public_20260829.tar.gz) 已完整下载，3,671,263,766 字节，官方 SHA-256 核验通过：

```text
6bf6ae1efe8de0e8bd15ddbd7fac58bcb54d9620262a541b9b219439317a4c42
```

Windows `ets`、`native`、`toolchains`、`previewer`、`js` 五个组件已全部解包；实际清单均确认 `apiVersion: 26`、`platformVersion: 26.0.0`、`version: 26.0.0.38`、`releaseType: Release`，保存至 `tooling/openharmony-sdk/26.0.0`。API 26 起 SDK 管理器按 `platformVersion` 的点分版本查找目录，不能沿用 `/26`；已据工具自带代码修正解包目录，未改写任何 SDK 身份清单。

它与华为商业 HarmonyOS SDK 的供应内容不同；公共 ArkTS 编译检查不能证明华为专有 Kit、实况窗、分屏、锁屏、生物认证、功耗或实机帧率达标。API 23 与 API 26 的公共平台构建均已实际完成，日志包含 `BUILD SUCCESSFUL` 并生成未签名 HAP；正式设备安装仍需对应设备与签名。

官方下载中心页面能访问，但匿名元数据请求返回缺少 `X-HD-CSRF`；页面下载流程检查登录与协议状态。未绕过登录、未读取或输出用户凭证。[官方安装说明](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-software-install)要求通过华为账号获取 DevEco Studio。

## 平台契约

[DevEco 26 发布说明](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/deveco-studio-new-features-2600)确认 HarmonyOS API 26 确实可开发；26.0.0.821 配套 Hvigor 6.26.4、Node 24.14.1、SDK 26.0.0。构建不能把旧工具版本伪装成这一发行版。[命令行构建说明](https://developer.huawei.com/consumer/en/doc/doccenter-deveco-studio/ide-command-line-building-app/)建议 26 系列使用 JDK 21。

[Antigravity Headless 文档](https://antigravity.google/docs/cli/headless/)支持 `-p`、`--output-format stream-json`、`--conversation`、`--model`、`--effort`，输出 `init`、`step_update`、`result`。持续 stdin 模式只接受文本块；它没有可直接借用的 `control_response` 手机审批通道。需要审批但无法取得的操作会软拒绝，不能以跳过权限代替手机确认。

[SDK 官方入口](https://antigravity.google/docs/sdk/overview/)使用 `google.antigravity.Agent` / `LocalAgentConfig` 及 Gemini API 或 Vertex 凭据。桌面订阅与 SDK API 凭据不可混为一谈；现有订阅的集成优先使用已安装 CLI 的正常鉴权。

[MuMu 官方说明](https://www.mumuplayer.com/help/win/how-to-upgrade-mumuplayer.html)明确其支持 Android 15。MuMu 可辅助检查网页/Android 容器内容，不能作为原生 ArkUI/HAP/HarmonyOS 系统能力验收设备。

## 未完成的设备验收

当前无 HDC 设备，未安装运行原生 HAP，未进行系统权限或推送测试，未验证 120Hz、冷启动 600ms、温升、离线中断恢复、生物认证及 7×24 小时稳定性。以上仍须真实目标环境测量，不以浏览器截图或编译通过替代。

## 原生后台预览入口

`tooling/preview_native.py` 提供命名管道及本地 WebSocket 桥接，接收官方 Previewer 自身渲染的画面，保存原始 JPEG 和无损 PNG；交互模式可逐次发送其公开命令。它不调用宿主鼠标、键盘、窗口激活或置顶 API。必须传入真实编译后的 ETS 与资源目录，不用 HAP 代替目录。

[官方 Previewer 入口](https://github.com/openharmony/ide_previewer/blob/OpenHarmony-7.0-Release/jsapp/rich/JsAppImpl.cpp)请求隐藏 GLFW 窗口；[图片协议](https://github.com/openharmony/ide_previewer/blob/OpenHarmony-7.0-Release/mock/rich/VirtualScreenImpl.cpp)经本地 WebSocket 发送 40 字节头和 JPEG。原始 SDK 保留在工程内，实际 Previewer 需放在 ASCII 运行路径，本次使用 `C:/Users/17601/HajiSakiNativeBuild/previewer26/common/bin`；中文路径曾触发资源主题读取失败，换为 ASCII 副本后恢复，未修改应用控件或 SDK 资源掩盖问题。

已实际渲染 API 23 与 API 26 原生应用的 1276×2848 画面，并通过 Previewer 自己的命令管道操作 API 26 的页面导航、打开主题菜单、选择月下剧场和空地址连接验证。逐张查看了首页、主机配对页、记忆页、档案空状态及深色状态。`tooling/evidence/native-api26-final-*.png` 和同名 `.jpg` 保存实际画面；对 `native-api26-hub-settled` 的 PNG 与原始 JPEG 解码像素作直接比较，结果无差异。深色配对表单的占位文字低对比度问题已修复，复查图为 `native-api26-reviewed-host-dark.jpg`。

### 实际 HTTP 与模拟存储的边界

SDK 中的 `module/net/libhttp.dll` 使用真实 HTTP 实现，不能将所有系统接口笼统称为模拟。已通过原生表单输入开发网关 `http://127.0.0.1:8765`，私下从配对文件输入设备标识与令牌，普通点击完成认证。界面实际显示已接回琴房、开发模式与模型状态；随后通过原生“写一页新的乐章”按钮在服务器创建对话 `f448b415b46a42a3bbbe8ac1f84ea479`。截图为 `native-gateway-pair-attempt.jpg`、`native-created-chat.jpg`；令牌输入始终隐藏，连接后表单清空令牌。开发模式有明确“非 AI 回复”标识。

SQLite 与 Asset Store 在 Previewer 中仍为模拟实现。生产产品的原生发送操作清空输入框，但模拟待发数据库没有保存可读队列，服务器未收到该条消息。为区分接收与发送，另一个正常 API 客户端给上述同一对话发送普通消息；服务器存有已完成的用户消息（64 字）与开发模式回复（259 字）。

更新后的原生客户端保持数据库写入确认，并使用独立的已提交缓存；重新加载构建后，实际 HTTP 快照中的用户消息和回复外框已进入原生聊天页。双击回复确实打开“静谧手稿”页。当前明确的显示限制是 SDK 对 Web 组件显示 `Preview not available for this component.`，见 `native-final-received-chat.jpg`、`native-final-reader.jpg`。不能据此宣称 ArkWeb 富文本、生产版加密持久发送通过；没有改写 SDK 资源或预置假对话。

最终深色对比度修复另以 `native-production-memory-dark-final.jpg`、`native-production-host-dark-final.jpg` 复查：主题采用可读的三个按钮，密码显隐采用可读文字按钮，输入占位文字明确使用次级文字颜色。

在用户允许模拟和替代验证后，工程另提供有明确“临时预览 · 本机记录关闭后清空”标识的 `preview` 开发产品，使用真实网关与 UI、临时内存存储，包名与生产版分开。它的交互记录使用 `native-temporary-*` 文件名；其结果不能满足生产 RDB 加密、重启恢复或离线队列耐久性验收。未预置对话或模拟服务器回复来假装模型已接通，开发网关仍显示“非 AI 回复”。

此产品首次原生发送得到 HTTP 422；安全诊断实测 `util.generateRandomUUID()` 在 SDK 中返回长度为 0 的字符串。修复后，临时产品生成自己的唯一消息编号并在重试中复用，生产产品则验证系统 UUID 有效后才处理输入。正常原生点击“送出”已将 32 字用户消息写入服务器：消息 `7993c46d929943628fdbccdb248c0c21`，对话 `71feb4b2a9ac47e9a35ddd7e3c164fe1`；服务器对应运行 `4f5b606db5324cdf869e9817e022c7c4` 已完成，并存有 227 字开发模式回复。证据为 `native-temporary-send-success.jpg` 与服务器数据库读回。

原生点击“钉住”后，服务器返回对应消息锚点 `77e044e51f3d493cb3c73320d8709d97`，界面显示金边锚点胶囊（`native-message-pin.jpg`）。收尾检查另发现服务器完成后“停笔”仍显示，已交回原生状态同步修复；在修复并重查之前，不把停止/完成状态记为通过。

后续安全诊断进一步记录：SSE 回调实际收到 13–344 字节的数据块，但旧预览解码路径每次都得到 `decoded=0`，没有解析出的事件序号。HTTP 发送仍成功，消息 `51b69388c1534657a6798aff07e6533d` 已写入同一服务器对话。旧证据保留在 `native-sse-runtime-recheck.preview.log`，只含字节数、类型和状态码，不含配对令牌或消息正文。

更新临时产品的增量 UTF-8 适配后，已正常发送新消息 `98cc3f83d877425fa9117b554738c3f5`。实际日志显示非空解码（例如 324 字节对应 280 个 UTF-16 字符）、事件从 780 的 `message_created` 到 830 的 `run_finished`，最终 `committed=830, run_active=false`。服务器运行 `6a2735808bca4f6c87d447954b83e123` 完成；`native-utf8-send.jpg` 实际画面确认“停笔”消失，深色 Select 箭头清晰可见。这一结果覆盖真实 HTTP/SSE 与临时运行状态，不包含生产 RDB 耐久性。主动中断的部分内容保留仍需独立观察。

搜索重查以原生输入 `reaches` 完成，界面只显示包含该历史消息的一条对话（`native-utf8-search.jpg`）。这验证了当前联网搜索过滤；跨年离线索引仍不在 Previewer 的持久化证据内。

通过统一命令工具交互使用时需启用 `tty=true` 保留 stdin。长输入重查暴露了同步双向管道互锁，已通过不读取局部变量的堆栈检查定位（`preview-bridge-stack.txt`）。桥接改用 overlapped 命名管道和独立读写事件，并在异步写入完成前保留数据缓冲；修复后同一 883 字符草稿完整输入，`native-handoff-draft.jpg` 已查看，尚未发送。检查完成后可发送 `{"command":"exit"}` 关闭本任务拥有的预览器；本次交接按要求保留其运行。

当前交接会话为统一执行会话 `41812`，Python 桥接 PID `15196`、Previewer PID `14948`。原生渲染读自 `C:/Users/17601/HajiSakiPreviewBuild/harmony/entry/build/preview`，预览运行时位于 `C:/Users/17601/HajiSakiNativeBuild/previewer26/common/bin`。当前草稿及临时存储仅在该运行实例中保留，服务器记录单独持久保存。

在本 SDK 版本，普通 `KeyPress` 字符键输入已实际作用于原生 TextInput；`codePoint` 输入法通道未产生文字。桥接的 ASCII 输入映射遵循 SDK 的键码，作用域只在独立 Previewer 中。凭据采用 `--private-input` 与 `text_file`/`json_key` 入口，不回显正文；该模式不记录可能带输入内容的 SDK/管道诊断，仍记录桥接本身的错误。

## 根代理后续集成复核

原生语音页已由根代理在实际API26隐藏预览中观察；通过正常表单认证同一8765 ACP主服务，从档案选择`jfk.flac`后点击听写，主机真实Whisper任务`17104b4699324dbd9fb62083cdb0d370`完成。界面出现真实转写与完成头像；点击“放回输入框”后文字留在聊天草稿，数据库中新对话消息数为0。证据为 `native-speech-asr-progress-nov15.png`、`native-speech-asr-result-nov15.png`、`native-speech-draft-returned-nov15.png`。没有请求用户麦克风，不以该样本声称语音准确率矩阵或生产持久性通过。

根代理复现并修复了未绑定原音的便笺重进空白：原内容实际保存为`speech_draft/scratch`，旧初始化没有读取。修复后在同一预览实例离开并重新进入，实际文字完整显示，见 `native-scratch-restored-nov15.png`。语音档案选择增加“随手便笺”，使音频切换后仍能访问这份独立草稿。

最新常规与临时预览产品均已编译为未签名debug HAP，真实包与摘要清单位于项目 `releases/`。SDK参数使用现有ASCII目录别名；直接使用中文SDK路径仍会触发旧打包工具无法找到jar的环境限制，没有改写SDK清单。`runtime/native-speech-source-switch-production-build.log`、`native-speech-source-switch-build.log`保留最终构建结果。

受控关闭旧预览器以加载新构建时，SDK在退出阶段输出过`JsEngine Crash / 0xc0000005`；这属于外部预览进程诊断，不是模型响应终止或会话恢复依据。没有修改SDK或隐藏诊断来宣称无崩溃。后续设备生命周期仍需实际观察。

## 本任务清理

下载站调查所用 6 个临时 JavaScript 文件已直接移入回收站：`4306.af31d9ddf986df2b.js`（20.4 KB）、`common.08f1635681289b7c.js`（8.3 KB）、`env.20261102162616.js`（12.1 KB）、`huawei-download-main.js`（48.9 KB）、`huawei-runtime.js`（8.2 KB）、`huawei-vendor.js`（1901.1 KB）。保留工具档案、哈希/来源清单、解包组件与匿名下载错误证据 `tooling/discovery/latest-tools.json`；未删除任何既有用户文件。上述为文件逻辑大小，不代表已释放磁盘空间。
