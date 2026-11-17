# iPad 原生预览 0.1.0（2）· 本轮交接

本轮按完整宪章继续，遵从后续“主代理独立收束、优先前端与陪伴感”的要求，没有新建或续派子代理。目标仍为active；下述观察不代表120项全部通过。

## 可交付结果

- 安装输入：`ipad/outputs/install/HajiSaki-iPad-0.1.0-build2-ea8aec56-unsigned.ipa`，70,166,477字节，SHA256 `ea8aec569876c8eeaf46bc8c19b59080b4038316ce657654fc3b3bd50f13df22`。
- 平台/版本：arm64、iPhoneOS、iPad专用设备族2、最低iPadOS18.0、bundle `app.hajisaki.theater.ipad`、0.1.0（2）。这是未签名的设备包，不是模拟器包或已安装实机的结论。
- 原生预览：`ipad/evidence/final-native-theater.png`；原始像素方向截图同时保留在`final-native-raw.png`。
- 设备与模拟器快照的App/资产文件摘要逐项相同。完整源树摘要不同是因为工程说明/观察材料继续更新，不能用一个旧源树摘要冒充所有后续文件。

设备包回执：`ipad/outputs/device/build-receipt.json`、`root-verification.json`、`package-validation.json`；安装输入回执：`ipad/outputs/install/install-packet.json`。当前配对令牌的两项检查未在包内发现匹配值，包内无位置权限声明。令牌值、Apple账号与Mac密码没有写入本记录。

## 实际完成的流程与修复

| 流程/发现 | 实际结果与证据 |
| --- | --- |
| 带代码链接的真实回复卡在排版循环 | 主线程采样定位到UIKit/SwiftUI测量；TextKit2改为由SwiftUI负责高度，同一回复完整显示。采样CPU由约77.6%降到静置约0.1%，仅为本虚拟机单次观察。`layout-stall.sample.txt`、`runtime/ipad-layout-after.log` |
| 文件/源码引用 | 原生段落及含公式的离线复杂块均可定位原件；源码第15行蓝色高亮、PDF第2页定位和翻到第3页已看。`source-line-upright.png`、`pdf-page-two-rechecked.png`、`pdf-next-page.png` |
| PDF请求页被初始化通知覆盖 | 原先定位第2页却回第1页；屏蔽安装文档时的初始通知并在布局后导航，原触发复查为第2页 |
| 昼夜和窗口关系 | 日间/夜间真实内容已看；夜间经设置保存、API读回和重开保留。第3页及柔光状态经横屏→竖屏卷宗→横屏保留，辅助弹层按宽度退场。`rotation-fix-portrait-inspector.png`、`rotation-fix-back-to-landscape.png` |
| 批注底图空白 | 使用有值的sheet条目、Core Graphics原页绘制和画布底图刷新后，第2页真实图像可见，可画蓝线、关闭重开、导出PNG并回到草稿。`annotation-page-image-fixed.png`、`annotation-reopened-ink.png` |
| 更新后笔迹引用失效 | 365字节原笔迹仍在，旧标识含绝对沙盒URL；改为资料库+原件SHA+页码，并将已明确识别的本轮旧文件迁移为稳定名称。保留其他两笔草稿。`document-ink-migration.json`、`ink-restored-after-update.png` |
| 模型误认原图绿色箭头为手写 | 导出PNG附笔迹区域/颜色/笔数，主机有界读取ImageIO写出的XMP Description并仅转发白名单数据。相同提问、相同可见像素的新回复只将深蓝线认作新增笔迹，下方图表称为原有图表。旧回复/旧文件保留。`ink-provenance-artifact.json`、`provenance-model-reply.json` |
| 原件与图像保真 | PDF缓存与“文件”App保存副本均为8,517,356字节、SHA `9fb106645f7d952aaaabdefdc3cc3fefd63898ed95c0c0d0d413a057dfac6264`。旧/新元数据PNG均1800×2400，像素比较无差异，实际图像均看过。`native-final-data-receipt.json` |
| 本机导出和重新导入 | 卷宗“导出”直达原生文件保存器，按原名存到本机哈基祥目录；从原生文件选择器导入副本后首次批注后台计算摘要，第2页复用原可编辑蓝线。安全作用域及NSFileCoordinator读取已接入。`native-save-hajisaki-folder.png`、`imported-copy-ink-reused.png` |
| Pin与摘要 | 正确的实际回复已固定，API读回目标message；重开仍在，折叠摘要不露Markdown URI，整行可点，展开的文件链接实际打开原图。`context-pins-current.json`、`pin-preview-final-clean.png`、`pin-image-final.png` |
| 离线取回与恢复 | 主动断开客户端后打开已有Pin和缓存原图，离线读取也校验摘要；随后用已保存Keychain配对恢复连接。不是锁屏15秒弱网压测。`offline-original-image-open.png`、`connection-restored-final.png` |
| 滚动与消息落盘 | 真实图像回复过程中上翻看旧PDF消息，完成后仍保留阅读位置，有回到最新入口。12条原生与主机正文SHA全部相同，游标均126、无活动运行。`reading-lock-after-vision.png`、`final-message-integrity.json` |
| 常用面板 | 模型选择时档位随之改变并恢复默认；重命名经UI保存、主机读回；记忆空面板、文件柜、设置、语音初始面板已看。没有启动麦克风。`model-high-selection.png`、`rename-saved-final.png`、`voice-panel-not-recording.png` |

Mac拖PDF到Simulator时由系统Preview接管并退出，哈基祥原有数据/会话继续使用。没有据此新建VM、聊天或重下SDK，也没有把失败算作应用跨App拖拽通过。改用原生保存/选择器完成导入流程。误触发的命令行工具安装提示已取消，后续继续用已有Xcode。

## 本轮变更文件

- `ipad/App/Sources/Views/NativeMessageBody.swift`：原生高度测量、源引用回调；`ConversationStage.swift`：引用桥接、输入提示对比度、完整按钮命中区；`ContextPinsPanel.swift`：可读摘要和原件链接。
- `ipad/App/Sources/Views/TheaterRootView.swift`：下载反馈、来源/意图守卫、页码/柔光状态归属、窄窗弹层衔接、外部文件协调读取。
- `ipad/App/Sources/Core/ArtifactLocation.swift`：已配对附件定位协议；`GatewayClient.swift`：能力头及可复用后台摘要；`TheaterModel.swift`：离线缓存摘要核验。
- `ipad/App/Sources/Platform/DocumentInspector.swift`：PDF初始导航、稳定批注身份、原页绘制、柔光与原生原件保存；`ScratchpadView.swift`：底图刷新与PNG笔迹来源数据。
- `ipad/renderer/entry.ts`、`vite.config.mjs`：仅平板启用的有界本地文件链接净化例外，普通URI策略保留。
- `ipad/tools/prepare_project.py`及生成工程：版本2和标准文件共享声明。`host/hajisaki/app.py`、`provider.py`、`documents.py`、新增`ink_metadata.py`：兼容能力声明及笔迹来源解析/约束；不更改设备授权含义。`tools/supervisor.py`：所选数据目录的默认配置及Windows中文输出修正（编码部分与手机聊天整合）。

使用了现有Xcode构建、TypeScript严格检查、Vite构建、Python语法检查、正常UI/API和数据读回，没有新增测试套件、断言案例、夹具或功能测试运行器。

## 外部条件与仍未通过的项目

Windows只读USB枚举当前没有Apple/iPad设备；实际安装还需正常Apple签名与本人设备信任/开发者模式。模型已复用现有Antigravity登录完成真实回复，不需因本轮再索取账号。当前18767是开发SSH转发，未把它当作国内外网双通道部署。

完整活体姿态、Pencil Pro硬件/触感、Spotlight系统搜索、跨渲染区连续拖选、系统扩展/外屏、全量原生笔迹归档、所有媒体与互动卡、私网热备部署，以及45项语法/35异常/80语音/7天/各量化门槛仍按120项台账保留。没有测到的项目不算通过；有些仍需继续实现，并非全部只差硬件。

## 清理

一次性脚本已直接送入Windows回收站：`type-guest-secret.py` 0.39KB、`inspect-qemu-input.py` 0.93KB、`mac-guest-pointer.py` 1.71KB、`inspect-mac-input.sh` 0.20KB、`runtime/guest-secret-input.py` 0.54KB。没有为删除创建备份、检查恢复性或永久删除；这些是逻辑文件大小，不等于释放的磁盘空间。保留SDK、原件、笔迹、诊断与复现材料。
