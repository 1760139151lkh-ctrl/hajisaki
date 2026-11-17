# 宪章落实与验收台账

最新收尾（2026-11-16）：按用户反馈将同模型的不同强度归组，模型面板45%限高，独立选择强度；425vp日夜、320vp和实际切换均已查看。选文附页已创建并取得真实回复，原乐章38条消息和模型会话保留。返回草稿显示及来源栏复用已修复并复查。普通64279942/预览64280782字节HAP已更新，各228份输入和摘要一致。具体证据见phone/docs/model-picker.md、native-branches.md。对照双方生成/投票和真机签名安装仍未完整验收，原始目标不据此宣称完成。


本台账保留原始范围，不把缺失能力改称完成。`product-charter.original.md` 是原文件逐字副本。用户后续要求：自主推进框架与可行的替代验证；缺少登录、签名或设备不阻止独立工作；人物必须保持少年感，参考“在场”原图。

状态只依据当前实际观察更新：**已检查**、**已实现待检查**、**进行中**、**待实现**、**需外部条件实测**。公开 OpenHarmony SDK 与华为 HarmonyOS SDK 分开记录。

最新手机阶段已接通 `/` 常用起笔、当前乐章语气和真实上下文整理。原生续聊确认74882→25976 tokens，正确保留钉选上限和预览模式判断；原始22条消息与模型会话均保留。原生命令即时计数可能延迟到下一轮，已修正确认时机且保留原先失败历史。425vp/320vp、日夜、模板草稿、结果阅读返回、离线缓存/重连与原生停笔已有实际观察。普通HAP为63918889字节、预览63919641字节，各222份输入无偏差，摘要与清单一致；详细证据见 `phone/docs/native-composer.md`。未签名诊断包与硬件验收分开，完整原始目标仍继续。

前一手机阶段已接通原生 `@` 代码/文件夹/历史引用、主人目录设置和既有中继，真实模型完成三类原件读取；修复实时消息不刷新、失败查询遗留旧结果、双击阅读被选字拦截及阅读返回跳到首条消息。最新页与上翻位置的返回前后截图均逐像素一致，详细证据见 `phone/docs/native-references.md`。桌面SDK配对与退出原生异常的日志和模块映射保留，根因未确认；真实模型的已完成回复不等于延迟或可靠性指标达标。

手机分支已按用户确认继续鸿蒙工程。新增原生画室与照片批注，笔迹、编号、马赛克、透视、旋转、增强、缓存历史、幂等导出和真实模型读图已有实际观察；实时正文缺字、失败重试和编辑返回阅读位置已修复复查。普通 RDB 大记录读取另按官方限制改用 LiteResultSet，只有编译证据，真机恢复仍待验证。详细证据和边界见 `phone/docs/native-image-studio.md`；下列原始范围没有缩减。

原生聊天内图片、图片墙、大图缩放/平移/柔光、嵌套批注保留倍率和原图追问已接入。真实 ACP 新工具取出图片及 PDF 第 2 页，留下有来源/页号的 L4 记录，普通页面可直接展开；授权外原件实际返回 403。已观察主机停止时缓存纸页重开、过程/聊天返回原位置、320vp 图片墙与未发送附件，以及新缩略图经过现有加密中继返回 200。手机现已直接解码 ThumbHash；真实不透明/透明来源的输出与官方参考四通道最大差均为 0。186 字节元数据已走通既有加密中继。原生录制显示占位、淡出和清晰帧，留边不一致已修复复查；真实两帧 GIF 的静态首帧、模型准确读取和离线新挂载阅读也已有观察。系统保存、完整动图播放和真机性能仍未验收；详细记录见 `phone/docs/native-images.md`。

最终复查另遇一次桌面 Previewer 配对中的原生异常 `0xc0000005` / 退出 `3221225477`；同一代码随后正常配对、读图续聊和原生显示成功，但该异常尚未稳定复现，保留为可靠性待查项。已增加截图子进程存活检查，冻结帧不算验收证据。最终真实模型运行已完成、主机认证为真且活跃任务为 0。

后续窄屏与普通入口检查修复了文件名被按钮挤压、文件阅读返回首条消息、失败空回复卡片及 GIF 草稿附件无法预览。实际 PDF 开启/关闭前后截图逐像素相同；GIF 名称打开首帧、独立取消选中、消息数不增加均已观察。主机为离线缓存检查再次正常停开后，当前服务健康、任务为 0，认证状态重新等待当前进程的对话验证；之前已完成的真实模型读图记录保留。

| 维度 | 当前落实与观察 | 未完成的原始要求 |
| --- | --- | --- |
| 1 原生启动、帧率、功耗 | 公开 OpenHarmony API 23、26 均已真实编译；API26 的常规存储包和独立临时预览包已输出未签名 HAP。已观察原生隐藏预览的实际页面与 HTTP 数据 | 华为设备签名安装、Pura 冷启≤600ms、200ms预热、500消息/15000字95–120FPS、≤380MB、温升与一小时续航均需原生实测 |
| 2 流式节奏、打断、实况窗 | SQLite持久事件序号与补流；实际ACP运行通过普通UI停笔，已输出正文SHA256与两份成品均保留，授权随后结束。主机停开期间的待发消息自动送达一次，并在同一模型会话正常回复 | ≤16ms平滑与70%改善、≤50ms触屏停止、400ms实况窗、后台30分钟仍待对应条件验证；功能观察不替代这些计时指标 |
| 3 语音五重纠错 | 主机已有本地 Whisper、热词、低置信片段、原文保留与可撤回顺句；公开 JFK 音频已有真实转写。Studio 与原生手稿页已接入；原生未绑定音频的草稿离开再进入已复核保留 | 声学Top3、TTS、原音直投模型、端侧Opus、来电恢复、80样本95%理解率与完整5分钟零丢失尚未验收；预览临时存储不代表真机持久性 |
| 4 双模私有连接 | 默认环回、独立设备令牌与吊销；真实CLI/ACP复用本机登录。主机代理独立配置；加密中继、原生适配器、设备绑定资料导出/导入与安全存储路径已有实现。真实companion参考客户端经TLS/HSR1读取状态200；预览实际检查了导入结构、受限保存、主连接保留与输入清空 | 原生WireGuard/Mesh、设备端HMAC/Asset恢复/TLS正负向握手、实际外网部署、完整双向热切换、国内5G/跨城、RTT与1.5s恢复仍须完成和实测 |
| 5 大文件、安全、回滚 | CAS去重、分段续传、下载与导出已有正常API记录。根代理通过实际Studio上传3,671,263,766字节官方SDK档案，并完整读回CAS核对官方SHA256；ZIP边界检查已实现 | 500MB强杀/弱网、并行视频9图、防爆恶意包全矩阵、沙箱展开、主机编辑Diff/可信审批/一键回滚尚未全部实现验收；本机大文件上传不代表原生或弱网验收 |
| 6 混合富文本 | 共享离线渲染器已有KaTeX/化学、代码、表格、Mermaid、ABC、ECharts及部分实际观察。真实Markdown待办可持久勾选；新MCP生成的Markdown、CSV、HTML可在Studio打开，HTML计数/重置与桌面、392px窄屏已观察。原生新增1MiB文字成品翻阅/原文入口，实际显示了CSV和Markdown原文 | 40+完整语法、所有流式中间态、超长文虚拟化及手势/跳动指标仍待完整覆盖；Previewer不支持ArkWeb，这份Markdown排版及原生HTML脚本隔离仍需对应设备。HTML本地交互不等同于持久任务状态接口 |
| 7 四层过程与交付 | ACP专属MCP已实际读取约定、留下L3/L2并以L4交付Markdown、CSV、HTML、PDF、XLSX与ZIP。下载摘要匹配；Studio阅读与原生有界PDF纸页、工作表、ZIP目录已有真实操作。原生还检查了缓存重开、缺页保留旧页和重连重试 | 任意磁盘/命令/浏览器、高危审批与位图生成仍未开放；原生系统文件保存、较大原件解析、完整五步全层/所见同步、20次全格式交付及命令产物路径兜底仍待完成。L1仅限允许公开的摘要 |
| 8 后台与记忆 | 独立无窗监督器、3秒重启策略、SQLite WAL/FTS、记忆增改/回收、导出、持久提醒与每日加密备份已实现。正常状态入口读到已完成的34文件、3,679,186,184字节快照；这只是已有快照状态 | 系统服务/托盘、实际开机与崩溃演练、完整备份还原、手机系统通知、7×24运行、断电、180天恢复、向量检索/长期摘要与≤180MB尚未完整验收；当前备份没有异机副本 |
| 9 灵魂与声触 | 当前选用在场原图、少年感十态头像与自定义图标/场景/贴纸；日夜主题已实际显示。原生原音页与连接页已复看；钢琴WAV与默认关闭的声触入口已有实现 | 全页面/全状态最终视觉、200%边缘、盲测一致性、35异常文案、实际听感/马达同步、GPU与OLED0nit需继续检查；资源存在不代表声触实测 |
| 10 隐私与安全 | Bearer+设备ID、默认环回、同源本机配对、防位置权限、原始附件开放导出；危险CLI工具严格拒绝 | 生物识别到主机的可信审批、加密中继部署与公共Wi-Fi完整审计未完成；永久粉碎与当前回收站规则冲突，遵从回收站规则 |

## 全页面与扩展能力

六类主要页面、日夜主题、透视度、模型档位、对话归档置顶、记忆调音、档案柜与主机状态已有实现。共享层已有Pin、分叉、双向待办、图片标注/透视校正、提醒、知识长图等功能及部分真实操作证据；不能自动视为原生手机端完成。原生 `@` 已接通主人开放的电脑代码/文件夹和实际历史消息，选中内容生成快照附件再发送；三类材料已由真实模型实际读取。320vp、日夜主题、40条历史翻页、取消/导航保留草稿、超限拒绝与断线重试已有实际观察。同步修复了消息行实时刷新与失败搜索显示旧结果的问题，真实后续回复已在同一挂载页面更新。合同、原始记录及设备边界见 `phone/docs/native-references.md`；无三个月前样本，不能将无时间截断接口当成旧数据实测。原生斜杠模板、当前乐章语气和模型声明的原生上下文压缩已有真实操作及续聊证据，详见 `phone/docs/native-composer.md`；不支持原生命令时的应用交接仍未取得合格长度的真实摘要。子线程/Arena、闪卡/决策卡、视频时间轴、会议说话人、万能卡片、跨端剪贴板、完整主动守护、周记与所有声触状态仍需按原始宪章继续完成。

## 原生原件保存续查（2026-11-15）

- 保存失败已保留准确阶段，档案卡片防重复保存，原音页保留文件错误；阅读页“重试”修正为再次保存。最终常规与临时预览API26均编译通过，未签名HAP已更新；字节数/摘要以`releases/`清单为准。
- 实际PDF保存与重试保留第2页/150%，最终画面`tooling/evidence/native-save-accepted-reader.png`、`native-save-accepted-retry.png`已查看。档案与原音保存错误布局也已实际查看；音频使用原有公开JFK原件，没有录制麦克风或自动发送。
- 当前Previewer首个16384字节块的`fileIo.writeSync`返回0；函数、FD与ArrayBuffer均可读，显式偏移/长度没有改变结果。未到系统文件选择阶段，未取得导出原件摘要。通过ASCII SDK入口消除路径警告后的HDC查询仍为`[Empty]`、退出0（`runtime/native-runtime-capabilities-ascii.txt`）。原件导出/取消、生产持久性与硬件指标继续未验收，不以阅读缓存或编译通过代替。
- 只读SDK帮助命令打印`PrintLog function error`，未被当作成功能力发现。计划加载新构建时正常退出预览应用所见的SDK0xc0000005也没有被当作模型运行时终止、会话恢复触发或崩溃率验收。未新建测试代码，未清理文件。

## 原生备用通道导入续做（2026-11-15）

- 主机正式导出2298字节设备绑定文件：加密PKCS8、客户端证书、CA、SPKI摘要、角色令牌及载荷钥匙；设备HMAC封签覆盖完整规范内容，原始网关令牌不入文件。实际HMAC读回一致，加密私钥/证书公钥摘要一致，ACL只含当前账户与SYSTEM。具体合同见`phone/docs/native-relay-import.md`。
- 新增`RelayVault`与`RelayRoom`，主机台区分另一条直连地址和加密备用通道。资料认证在新通道接收网关凭据之前；通过实际加密状态读取后才存钥匙并安装。安全绑定限制不同主机钥匙使用旧路径，配置锁和原子日志元数据保护未确认写操作。设备端认证与耐久性仍未实测。
- 原生实际日夜页、无效资料、真实绑定资料通过结构后被安全存储边界阻止、失败后主连接保留、离开重开输入清空均已查看，画面`native-relay-final-day/bound-result/primary-retained/source-cleared.png`。当前预览Base64调用返回0字节，结构解析改为等价的规范32字节Base64检查，密码/TLS验证继续使用系统接口。未以模拟结果报告安全保存成功。
- 本机生产模式TLS中继与出向connector当前运行；同一companion参考客户端请求`22a4d283f1054625a4ae5275ab48eb03`取得认证内层200、1327字节、uncertain=false。此为Python链路观察，不能计为原生或外网验收。
- 常规/预览API26最终构建通过，HAP分别63297914/63298514字节，真实摘要为`8e05c2e8a246465ee857a6c54a155fb25589de43a4fe6485e677f9804431ce7a`与`cb49e94a20b6f6a8c87377d53f7397e54402f8ad7876799936c930eff03968d0`；含实际Ark字节码及123份离线渲染资源。
- 备用通道依赖安装最初误用了主环境并降级三项，已恢复Host锁定的FastAPI0.163.1/Uvicorn0.54.0/cryptography50.0.2，主服务未重启且仍健康。通道现使用独立`relay/.venv`；两环境pip check通过。只将三份本轮过期元数据目录直接移入回收站：fastapi-0.137.1.dist-info 35.04KB、uvicorn-0.49.0.dist-info 14.54KB、cryptography-48.0.1.dist-info 79.99KB，合计132688字节/129.58KB。路径与字节数见`runtime/relay-dependency-recycle.json`；不将其当作释放磁盘空间数值。

## 本轮复核证据（2026-11-15，用户时区）

- 主服务8765通过正常配对与聊天界面完成ACP运行`2b6ceda7baad4367870d21e8a75f11df`，对话`3499af49cc4f41cb93dd7903b5115a90`；数据库终态`completed`，三项待办的第一项在刷新重进后仍为已勾选。截图`docs/evidence/chat-current-nov15.png`。
- `docs/evidence/reader-checkbox-fixed-nov15.png`和`mobile-reader-checkbox-fixed-nov15.png`覆盖修复后的宽窄阅读弹窗；`host-current-nov15.png`覆盖已翻译的真实主机状态。
- `tooling/evidence/native-root-scratch-before-nov15.png`、`native-root-scratch-reopened-nov15.png`记录原生手稿重进空白的原触发；`native-scratch-restored-nov15.png`记录修复后同一普通输入重新出现。使用显式临时预览产品，未宣称生产RDB重启耐久性。
- 最终构建在正常界面切换`随手便笺 → jfk.flac → 随手便笺 → jfk.flac`，两份分别输入的草稿各自保留，已查看 `native-source-scratch-retained-final.png` 与 `native-source-audio-retained-final.png`。没有靠切换来源丢弃另一份未发送文字。
- 通过原生正常按钮从网关档案选择`jfk.flac`并提交主机听写，任务`17104b4699324dbd9fb62083cdb0d370`真实完成；`python -m speech read`读回11秒原音与转写片段。`native-speech-asr-result-nov15.png`显示实际结果；`native-speech-draft-returned-nov15.png`显示放回输入框后的草稿，新建对话`cc7ad57fae7546fb964cb5aa1a50704d`的服务器消息数为0。没有录制用户麦克风、没有自动发送或声称音频模型直听通过。
- `runtime/studio-reader-layout-build.log`为实际TypeScript/Vite构建；`runtime/native-speech-source-switch-production-build.log`与`native-speech-source-switch-build.log`为最终API26编译。`releases/`包含两个约62.94MB的未签名debug HAP、构建日志与源码/产物摘要清单。

## 专属工具与成品交付续做（2026-11-15）

- 现成`AgentTools`路由已接入主8765与ACP。MCP子进程仅取得本次短期工具授权；授权检查运行状态、摘要和期限，读取限定本会话附件，写入限定本次输出目录，不能覆盖/执行文件。普通CLI仍全拒绝，旧inline ACP配置保留。实际版本的通用工具回调附带`toolSummary`，已按结构化工具名与参数名逐次匹配；不会依据展示标题或全局通配符放行。
- 会话`91270b3babf54f1bb5b1a931f243334f`的真实运行`49c9af932ef64f6a9f8a9c1a14c9cc6d`读取实际约定，留下进展与动作，生成`handoff.md`（3927字节，产物`b653a221916443e6984c615b5acf89ce`）和`handoff.csv`（701字节，产物`4201c55729b7492c860506fe1482c53e`）。MD通过真实UI下载，SHA256为`3757df137a8c9c050d3efa7457e5e7f5c96bc6a3450df532d9311f8315e705e8`，与服务端一致。预览与原文实际检查记录在`docs/evidence/agent-handoff*`。
- 该运行后来用于普通UI的停笔流程：状态为`stopped`，正文SHA256前后均为`ac355166d824b641a023eb13b6a54db5df165dbc388191f2a2526b8d43c9a63c`，两份产物仍在；工具授权随后`enabled=0, expires_at=0`。这不是模型运行时失败恢复，也没有替换模型会话。
- 主机正常停开期间，先观察到待发文字；主机恢复后未点重试，消息自动送达，服务器同文用户消息数为1。真实运行`6384073d0d2d4fb6ad19e8114176003d`随后`completed`，沿原provider会话接续回复。
- 另一个真实会话`2af13ccce28343799ba9ba749a3fd7ea`与前述运行并发工作。运行`48bedcdcfd4a44f9a5bde20680a1989a`创建9,017字节`study-card.html`（产物`18d121c0b6234f088c933c57ea3352ad`）并正常完成，`unexpected_tool_attempt=false`。Studio实际勾选到3/3再重置0/3，窄屏也勾选后读到1/3。截图`agent-html-card-complete.png`、`agent-html-layout-final.png`、`agent-html-mobile-final.png`已逐张查看。
- 最后权限形状防御更新后，沿该会话执行真实运行`b28c0b40deac4cc6a8470875651b9f06`，创建46字节`tonight.txt`（产物`0c9eb57583ab4cffb430db666e17ce47`）。普通UI预览读回指定寄语；运行正常完成，`unexpected_tool_attempt=false`，授权`enabled=0, expires_at=0`。当前已实际生成并交付四种文字格式，不声称覆盖20次全格式矩阵。
- HTML位于仅`allow-scripts`的Blob沙箱，实际`window.origin=null`，父文档和localStorage读取均为`SecurityError`；权限策略拒绝定位/相机/麦克风/剪贴板等。配置CSP限制连接和资源，父页面只允许Blob框架；没有把主机令牌或原件Cookie交给卡片。以上是聚焦观察，不是穷尽攻击或抓包审计。
- 实际旧授权与停笔授权写进展均被拒绝；运行中的授权读取另一真实会话的WireGuard PDF也被拒绝。没有通过开启任意命令或磁盘权限得到成功结果。
- 原生“翻阅”通过实际HTTP显示CSV（`tooling/evidence/native-agent-csv-reader.png`）；同一份MD排版走ArkWeb时预览器明确不支持，切换原文后实际可读（`native-agent-markdown-source-readable.png`）。未修改SDK或以原文替代原生富文本验收。
- 最后构建：`runtime/studio-artifact-layout-final-build.log`、`native-artifact-release-final.log`、`native-artifact-release-preview.log`。两份HAP已更新到`releases/`，约63.00MB；实际ZIP内的123份渲染资源与当前资源清单一致，未缺失或混入旧块，产物哈希与旁侧清单一致。主机锁文件补齐Markdown/时区/加密依赖；正常pip解析和pip check通过，未将其称为新电脑安装实测。
- 回收站清理仅覆盖确认不再被资源清单引用、且逐字节等同于Studio原始构建物的165份复制块，逻辑大小16,347,009字节（约15.6MB）。源目录与两处显式标记构建目录均核对边界；旧清理报告保留，新文件名/大小详见`phone/docs/native-renderer-cleanup-20261115T200205720609Z.json`。没有永久删除或检查恢复能力，未宣称释放等量磁盘空间。
- 逐项KB大小在`runtime/native-artifact-recycle.log`。另将本轮临时`runtime/bridge-current-action.json`（0.06KB）与三个新建编译缓存`agent_tools.cpython-313.pyc`（33.24KB）、`bridge.cpython-313.pyc`（12.81KB）、`sync_resources.cpython-313.pyc`（8.92KB）直接移入回收站，未清理原件、授权记录、日志或SDK。
- 任务自有浏览器配置目录发现另一Windows SID的继承读取权限后，已只收紧`.automation/hajisaki-root-review`，其Session Storage子目录读回仅当前用户、SYSTEM与Administrators；原浏览器会话继续可用。未改普通Chrome用户配置或项目共享父目录权限。

## PDF、工作簿与归档交付续做（2026-11-15）

- 新增三种可信导出工具，未开放任意模型代码。项目依赖包含ReportLab4.5.1与openpyxl3.1.5；数据输入最多1MiB，2个并行进程、384MiB/45秒，结束或停笔复核授权。PDF100页/12列表格、XLSX10000格、归档64MiB等具体边界见`host/README.md`。新ACP配置为`gateway-tools-v2`，旧配置原样保留。
- 同一真实provider会话`acp:3ac93481-a1da-4e23-88ed-b06ef41fda65`连续完成运行`b67f0080c4324704953c63365d9e7e26`、`2e8c463012f346cc92627b3c75b275a0`、`333b9565b8ff4f3f87c6c35c83ae25d9`。最初XLSX受OpenBLAS线程内存分配影响，限制库线程后正常生成；未替换模型会话。错误的原件ID被边界拒绝，模型改用本会话真实分享的原件`f36b16ff0d2c42e2b0eed460140c985a`。
- 修订PDF为`7e6c868b8ea649608cbbbd11f975f6b7`，328418字节，SHA256`9aaaf0a50d94ad07ee56f3640f3cf08d8b8535f5eb7089d5f181475ed3289872`。修复长表前异常空白、窄编号列、普通行跨页碎片与代码竖线丢列；API-29完整角色与返回语义可读。Poppler120dpi渲染的`binary-report-revised-page-1.png`至`-6.png`全部亲自查看；并实际用Studio翻至第2页、切换柔光与保存。下载在`docs/evidence/hajisaki-handover.pdf`，摘要与CAS一致。旧版PDF和截图保留作诊断。
- 最终XLSX`23a8d90ed54a4e5d9ca8d8497be49343`共9991字节，包含“接口目录”31行5列、“交付边界”7行4列（均含首行表头）；与首次成功工作簿的全部单元格逐格一致。工作表XML改为内存写入，避免创建后删除临时工作表；表头样式、B2冻结和筛选保留。最终ZIP`94f35240755447e9a51a403b658d139d`共331887字节，真实目录含最终XLSX、修订PDF与原约定，内置ZIP完整性读取无坏条目，三个条目摘要均匹配原件。真实UI下载ZIP位于`docs/evidence/hajisaki-handover-delivery.zip`。
- Studio新增实际XLSX切表、20行分页、独立双向滚动与固定首行首列；修复CAS摘要无扩展名的读取失败。真实30行接口目录翻到21–30行，切至6行交付边界；长格内容保留。窄屏固定列曾遮挡末列，调整列宽后重新横滑查看完整文字，截图`binary-workbook-mobile-final.png`、`binary-workbook-mobile-boundary-final.png`。ZIP真实目录的桌面与窄屏已观察；窄屏采用modal元素截图`binary-archive-mobile-modal.png`，避免外层iframe全页截取造成的布局重算。
- PDF使用固定标题/操作栏，页码不再分成两行；换页回到顶部，加载/绘制中禁用翻页，关闭时释放解析。内嵌窄屏原件相对地址曾造成展开失败，按文档基址解析后同一原件正常打开。新增100–300%放大与独立横纵滚动，实际第2页250%阅读截图`binary-pdf-mobile-reading-final.png`已查看；随后缩小至200%，读回页面2、628×889画布和空错误状态。柔光截图`binary-pdf-soft-final.png`已查看。最后构建记录`runtime/studio-binary-reader-final-build.log`，TypeScript与Vite通过；项目`pip check`通过。上述仅为主机与Studio交付观察，未将其计为原生PDF/XLSX、20轮全格式、弱网或Pura性能验收。
- 最后只将本轮三个编译缓存直接移入回收站：`exports.cpython-313.pyc`11.76KB、`export_worker.cpython-313.pyc`28.00KB、`sheet_preview.cpython-313.pyc`5.11KB；精确相对路径与字节数在`runtime/binary-export-cleanup.json`。保留原件、任务诊断与复现资料，没有备份/恢复检查或释放空间声明。
- 最后桌面PDF截图`binary-pdf-desktop-accepted.png`与主机能力面板`binary-export-capabilities.png`也已查看；三个新增格式如实显示已接通，实况窗/审批等未完能力仍显示尚未接通。PDF、XLSX与ZIP都经实际UI保存且摘要匹配CAS。结束时主8765正常、活动运行数0、三轮授权均失效，手机端未改包。
- 复核原始宪章时发现项目存档曾缺失部分行末转义符，已直接按附件原始字节校正。当前附件与`product-charter.original.md`的SHA256均为`9d32f8e6795462fa329db89b12887efa4f1085a05c9b07bd77cd65935beced31`；未删减任务内容，未创建备份。

## 原生二进制阅读续做（2026-11-15）

- 新增原生`PdfReader`、`WorkbookReader`、`ArchiveReader`与按原件摘要隔离的`ArtifactPages`缓存/阅读位置；共享`ArtifactRoom`保存与返回。主机新增认证`page-image`，PDFium5.15.2在最多2个独立384MiB/20秒进程中解析，宽度最多2048/600万像素，输入原件64MiB上限，派生图像与JSON保持在既有4MiB中继载荷内。原件不改写；真实边界见`phone/docs/native-document-readers.md`，不称作设备端PDF Kit或全容量解析。
- 同一份修订PDF通过真实API产生6张2048×2897纸页，`docs/evidence/native-pdf-pages/page-1.png`至`-6.png`逐张查看。原生实际显示第1/2/6页、输入页码跳转、150/250%放大与柔光/原色。最初拖动不移动，已改用API26`ScrollDirection.FREE`并关闭Image默认拖拽；`native-pdf-pan-fixed.png`实际显示横纵位置均变化，标题/操作栏固定。
- 原生XLSX实际第一页/21–30行、横滑/纵滑时表头首列保留、切至6行交付边界与长格均已观察。修复固定列标题切表不更新、夜间菜单过亮；实际标题切为边界编号，菜单呈深色，柔光可切回原色。相关最终画面`native-workbook-header-updated-final.png`、`native-workbook-menu-final.png`、`native-workbook-soft-final.png`均已查看。
- SDK原始ZIP经Studio正常上传，27725579字节，原件/CAS摘要`ee7ad339154504ddde74d07325ae378ead95a0bf357b62edf0c08d6b6d150688`一致；实际48项、展开46742041字节。原生翻到1–20、21–40、41–48，目录名、长名换行、大小、前后页状态正确。源文件已存在，未新造夹具或放宽10000项/路径/膨胀检查。
- 当前原生用独立companion设备`device-144d4dfad9664fadafb53a1c3337a28b`，真实owner API签发并在原生表单连接成功。令牌仅在私有`runtime/device-provisioning/harmony-reader-preview.json`，未输出到日志/画面，也没有把主机引导钥匙复制进这次原生实例。它仍只是软件设备凭据，不是硬件指纹或生物识别批准。
- 无活动模型运行时正常停止主8765，状态明确显示process_alive=false/health=null。实际离线重开ZIP第41–48项并回翻21–40、工作簿交付边界、PDF第2页/150%，均有内容；只证明当次预览内缓存，不能算生产RDB重启耐久性或全部原件离线。未缓存第3页失败后页码仍2、旧内容仍在；文件断网文案与陈旧在线灯已修复，缓存读取不会假报联网。
- 主机正常恢复后，同一重试按钮真正取得第3页，提示消失；返回档案页连接灯由待连接恢复在线。`native-pdf-offline-final-settled.png`、`native-vault-offline-status-fixed.png`、`native-archive-offline-reopened.png`、`native-archive-offline-previous.png`、`native-workbook-offline-reopened.png`、`native-pdf-offline-reopened.png`、`native-pdf-third-page-ready-retry.png`、`native-vault-reconnected-status.png`均已亲自查看。一次重试早于服务就绪，未将其计为恢复成功；确认健康后再走相同按钮才成功。
- 最后公共API26常规/预览编译分别记录在`runtime/native-document-link-production-corrected-build.log`与`native-document-link-preview-corrected-build.log`，均成功，未声称零警告。`pip check`通过。重载只针对已改构建，预览器主动退出时的SDK0xc0000005已保留，不属于模型运行时失败或无崩溃证明。未创建新聊天/子代理、测试代码、测试夹具或运行器，未触及iPad/Mac/8767与定位权限。
- 两份HAP已实际更新到`releases/`：常规63179112字节/SHA256`365824bca497ea3aebf98ae8cd2a9ccf36704573c8712e4e335ff71ed02ab601`，临时预览63179676字节/SHA256`96ff143048a7071c6e8c953c63d357982ace551bcc91db3ad74d64a40f7a3e1c`。摘要与旁侧清单一致，含实际Ark字节码，123份渲染资源闭包无缺失/额外项。只将新编译缓存`pdf_page.cpython-313.pyc`（4.10KB）直接移入回收站；正常重载的`supervisor.stop`状态文件观察为41字节，也由既有监督器直接回收。清理详见`runtime/native-document-cleanup.json`，未清理原件、凭据、SDK、依赖或诊断证据，未作恢复测试或释放空间声明。

## 口径

- `#05070F`不是零发光黑色；0nit仅可能对应真正纯黑区域且需屏幕测量。
- 200ms秒传以已计算的可信摘要查重计；首次2GB哈希耗时单独计量。
- 本地停止绘制与远端任务取消分开测量，不把局部瞬停当成跨网50ms完成。
- 离线全量文字与有限媒体缓存分别承诺；只有缩略图时不能声称离线原件齐全。
- 公共摘要流与隐私推理不是同一数据；只展示提供方允许公开的内容。
- 计时与长时稳定性保持原目标，未实测不填造合格数值。

## 依据

- Huawei HarmonyOS26版本与ArkWeb说明：https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/overview-2600/
- Antigravity CLI事件、续聊与无头权限：https://antigravity.google/docs/cli/headless/
- CLI严格权限与优先级：https://antigravity.google/docs/permissions/
- SDK独立认证/计费入口：https://antigravity.google/docs/sdk/overview/
- MuMu平台范围：https://www.mumuplayer.com/

具体文件、工具版本、命令及检查结果见 `platform-environment.md` 与 `gateway-verification.md`；后续集成后继续更新本台账。

本轮清理仅将自建临时动作参数 `runtime/current-browser-action.json`（0.18 KB）和编译缓存 `phone/harmony/tools/__pycache__/package_release.cpython-313.pyc`（5.4 KB）直接移入回收站。原始数据、项目依赖、SDK、构建产物和诊断证据保留；以上为文件逻辑大小。
