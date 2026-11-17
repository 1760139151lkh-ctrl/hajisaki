# 哈基祥 · iPad 剧场版工程合同

审计日期：2026-11-15（America/Los_Angeles）。本文件是平板版的设计和集成合同，不是完成声明。原始目标为用户附件 `goal-objective.md` 中的完整 iPad 宪章；逐项状态见 [验收台账](acceptance-ledger.md)。主机、手机和素材仍在并行演进，接口以所列源码及实际 API 响应为准；现主机禁用 `/openapi.json`，不能依靠该网址发现接口。新增能力必须集成后再更新状态。

## 产品边界

平板的主工作流是「聊天推演 ↔ 原文/代码/手写 ↔ 祥子陪伴」，不是把手机界面放大。横屏同时保留名录、对话、工作台的空间关系；竖屏和窄窗优先连续阅读；进入 PDF 或草稿时保留对话上下文、滚动位置和未发送内容。人物遵从用户“在场”素材中的少年感祥子：浅蓝长发、金色/琥珀色眼睛、柔和脸型、制服气质。不得用成年化候选替换母版。

可共用的是身份母版、原件、消息/附件/记忆语义、主机能力、传输协议和纯内容渲染依赖。三栏布局、Pencil 操作、场景生命周期、窗口调度、离线数据库和无障碍语义由 iPad 原生端独立承担。手机 ArkUI 控件、手势和版面不是 iPad 的设计模板。

## 目录与所有权

目标目录如下；这是迁移目标，不能据此声称所有旧目录已经移动。

```text
phone/                 手机原生应用及仅手机使用的构建配置
ipad/                  SwiftUI/UIKit 工程、Pencil/窗口/扩展、平板资源装配
host/                  两端共同使用的 Windows 网关与模型适配
relay/                 共同的加密反向通道协议及主机连接器
speech/                共同的主机离线语音处理
shared/                协议/语义、身份母版、可共用原件与内容资源
studio/                Windows 本地管理入口；不是任何原生端的替代品
assets_pipeline/       素材来源、提示词、生成清单与资源装配入口
tools/                 项目独立启动与维护工具
docs/ipad/             平板合同、功能状态、平台依据与实测记录
runtime/               私有持久数据；不是可清理的构建目录
```

审计时手机代码仍在 `harmony/`，另一个手机任务正在编辑和构建它。先在独立 `ipad/` 开发；实际迁入 `phone/` 时应在写入边界同步修正 `tools/`、README、资源同步、原生构建暂存和所有依赖相对路径，再运行原有构建入口与读取原有数据。不能在另一任务写文件时移动它的源目录，也不复制出两套竞争的手机源码。迁移不移动 SQLite/CAS 或更换原生应用标识，不通过卸载“验证”。确认目标绝对路径在本项目内后才移动目录。删除始终直接进入回收站。

## 原生职责分层

| 层 | 职责 | 必须保留的行为 |
| --- | --- | --- |
| App / Scenes | iPad 主窗口、阅读窄窗、外接显示器、深链与系统命令 | 每个场景独立的选择/滚动位置，内容数据共享；断开外屏不丢草稿 |
| Theater | 名录、消息舞台、Living Portrait、Inspector | 工作台切换不销毁对话，侧幕可收起，键盘导航与 VoiceOver 可用 |
| Document / Ink | PDFKit、代码行锚点、PencilKit、图片标记 | 原件不改写；笔迹/批改为独立图层，保存坐标系、页码和原件摘要 |
| Content | 原生可选文字与分块富内容 | 跨段选择、正文不泄漏未闭合源码；复杂图表离线资源受限沙箱 |
| Domain Store | 会话、消息、事件、附件、草稿、笔迹、发送队列 | SQLite 事务保存游标与数据；已读到的内容不因断流消失 |
| Transport | 直连与中继、认证、断点传输、恢复 | 保留消息 client_id、上传偏移和不确定请求；未知结果不自动重做修改 |
| Platform | Keychain、LocalAuthentication、Core Spotlight、WidgetKit、ActivityKit、AVFoundation | 权限按实际功能使用；无任何位置权限；平台不可用时保留用户内容 |

尚未存在的模块不能仅因列在本表中而算作已实现。构建目标、系统最低版本和扩展 entitlement 必须在工程落地后记录。

## 版面与物理约束

11 寸 2360×1640 是物理像素；按 @2x 排版的全屏参考画布是 1180×820 pt，实际还要扣除安全区和系统窗口装饰。Apple 官方规格确认 IPS、P3、True Tone、Pencil Pro/hover 和顶部 Touch ID；用户尚未明确具体芯片代次，不据显示分辨率替用户猜型号。[Apple iPad Air 规格](https://www.apple.com/ipad-air/specs/)

- 横屏名录目标 18%–22%；陪伴侧幕目标 22%–32%；进入 Inspector 时目标 34%–42%。这些是不同工作状态，不把两种右栏宽度同时套用。
- 三栏 20% + 38% 时，中间约 496 pt，扣除内边距后无法装入 65–75 个 17 pt 中文全角字。原宪章的三栏比例和严格中文字符数不可同时满足。实现可用阅读最大宽度约 70 个拉丁等宽字符，并让中文按可用宽度自然换行；这是明确的适配取舍，原严格 65–75 字符验收仍列为待定，不暗改为已通过。
- 窄窗由实际可用宽高决定，不能只按“横/竖”硬切。名录改为抽屉；正文和文档之间保留可逆切换。Dynamic Type 放大时先减少同时呈现的栏数，不截断内容。
- 外接显示器应区分可交互 `windowApplication` 场景与非交互外屏场景。不能把全屏投影当成可点击的三栏工作台。Windows/模拟器画面不能证明 4K 双屏实机工作。[Apple 桌面级 iPad 应用](https://developer.apple.com/documentation/uikit/building-a-desktop-class-ipad-app)
- iPadOS 26.2 的 Slide Over/分窗属于系统窗口行为，应用响应窗口尺寸而非自行伪造系统侧拉窗。[Apple 多任务说明](https://support.apple.com/en-ie/125309)

颜色 token 保留用户数值，但 `#RRGGBB` 本身不携带色域信息。SwiftUI 应显式声明 `.displayP3` 或用带色彩空间的资产颜色；图片是否 P3 需检查 ICC/色彩标记，不能因设备支持 P3 就把全部 PNG 称为 P3。sRGB 截图也不能验收真机广色域。[SwiftUI Display P3](https://developer.apple.com/documentation/swiftui/color/rgbcolorspace/displayp3)

## 已有主机 HTTP 合同

读取范围：`host/hajisaki/app.py`、`store.py`、`config.py`、`provider.py`、`bridge.py`、`context.py`、`reminders.py`、`speech_routes.py`。现默认网关仅监听环回。远程 iPad 的 `127.0.0.1` 指向 iPad 自身，不能作为家中主机地址；模拟器和真机网络地址分别配置。

业务认证为请求头 `Authorization: Bearer <token>` 与 `X-Haji-Device: <device>`。当前主机仅保存一组令牌和设备字符串；字符串匹配不是设备证书绑定、多设备注册或每设备撤销。凭据只能保存在客户端受保护存储，不能进入 URL、源码、截图或工作记录。

`POST /api/local-pair` 是同源、本机拥有者引导入口；中继禁止转发，不能当作远程免认证配对方式。原生端需要受保护的明确配对配置导入或后续真正的设备注册协议。无需登录时仍可完成离线编辑、保存、渲染和明确标识的本地演练；缺少签名或通道配置只影响相应外部联调。

| 接口 | 请求和返回约定 | 原生使用要点 |
| --- | --- | --- |
| `GET /api/health` | 粗粒度存活 | 不能据此声称登录、代理出口或模型可用 |
| `GET /api/status` | `provider`、`host`、`reminders`、`capabilities` | 按真实能力启用操作；`provider.available`、`authenticated`、`simulated` 含义不同 |
| `GET /api/models` | `{models:[{id,name,efforts}]}` | 只提供发现过的模型和档位；不可承诺每模型都有 XHigh |
| `GET /api/conversations?q=&group=&archived=` | `{conversations:[…]}` | 对话含 `id,title,group,pinned,archived,updated_at,preview`；当前无列表分页 |
| `POST /api/conversations` | `{title,group}` → 对话对象 | 默认标题“新的乐章”，默认组“专属日常” |
| `PATCH /api/conversations/{id}` | `{title?,group?,pinned?,archived?}` | 同形 `POST …/{id}/update` 可用 |
| `GET /api/conversations/{id}/messages` | `{messages,active_run,cursor}` | 同一数据库事务取快照和该会话事件游标；目前是全历史返回 |
| `POST …/{id}/messages` | `{content,client_id,model,effort,attachments:[artifact_id]}` → `{message,run_id,assistant_message_id?}` | `client_id` 创建后持久化，重送保持不变；每会话仅允许一个活动运行；重送应允许 `assistant_message_id` 缺省 |
| `GET …/{id}/events?after=N&limit=M` | `{events,cursor,has_more}`；1≤M≤1000 | 事件全局序号在会话内可能有间隙，不能要求每个整数都出现 |
| `GET …/{id}/stream?after=N` | SSE：`id: seq`、`event: haji`、`data: event JSON` | 也支持 `Last-Event-ID`；15 秒空闲心跳；中继 v1 不转发此流 |
| `POST /api/runs/{id}/stop` | `{status}` | 本地停止动画与远端结束分开；部分文本保留，终态从事件/快照确认 |
| `POST …/{id}/fork` | `{message_id,title?}` → 新对话 | 当前复制截至节点的消息、附件、任务勾选状态和适用的Pin；没有完整 Thread/双模型 Arena 语义 |
| `GET/POST …/{id}/pins` | 返回 `{pins}`；创建 `{kind:message/artifact/text,target_id?,content?}` | 最新共享源码已加入；每会话最多20枚，文字最多4000字符；尚未确认原生/中继集成 |
| `DELETE /api/pins/{id}` | `{status:recycled}` | 移除Pin记录进回收站，不删除原消息/附件 |
| `GET /api/messages/{id}/tasks` | `{tasks:{index:checked},items:[{index,text,initial_checked}],editable}` | 从Markdown任务项提取，独立持久化勾选状态；队列/流式阶段不可改，结束或停止后可改 |
| `PATCH …/{id}/tasks/{index}` | `{checked:bool}` → 上述任务对象 | 也支持 `POST …/{id}/tasks/{index}/update`；更新产生L4 `widget_updated`，不是完整通用卡片协议 |
| `GET/POST /api/memories` | 查询 `q`；创建 `{content}` | 更新用 `PATCH /{id}` 或 `POST /{id}/update` |
| `DELETE /api/memories/{id}` | 删除活动记录，并转交系统回收站 | 不实现或宣称永久粉碎；与用户回收站规则一致 |
| `GET/PATCH /api/settings` | `theme:auto/night/day`、`transparency:companion/balanced/studio`、`sound`、`personality` | personality 为 formality/detail/teasing，0–100；已有设置是主机共享，不可悄悄当成每设备配置 |
| `GET /api/artifacts` | `{artifacts:[{id,name,size,mime,sha256,url,…}]}` | URL 为鉴权内容接口；不是本地文件路径；目前无列表分页 |
| `POST /api/uploads` | `{name,size,sha256,mime}` → 上传对象或已存在附件 | 主机默认最大16 GiB、chunk8 MiB；中继更小，见下 |
| `PUT /api/uploads/{id}?offset=N` | 原始二进制 → `{offset}` | 从文件流读取一块，失败后先查已确认偏移，不整文件装内存 |
| `GET /api/uploads/{id}` | `{id,offset,size,complete,artifact}` | 进程重开后按主机偏移续传 |
| `POST /api/uploads/{id}/complete` | 完成摘要校验 → 附件 | 校验通过才可用附件 ID 发消息 |
| `POST /api/uploads/{id}/restart` | 从零重新上传 | 主机将旧片段送回收站；不是普通重连必需操作 |
| `GET /api/artifacts/{id}/content` | 原件、ETag=`"sha256"`，支持 Range | 大文件应下载到文件；不能从 thumbnail 推断原件已离线 |
| `GET …/{id}/inspect` | 附件元数据/解析状态 | 实际格式和解析器能力为准 |
| `GET …/{id}/text?offset=&limit=&page=` | 有界摘录与接续信息 | PDF 原页显示仍需客户端取得原件；摘录不是原版排版 |
| `GET …/{id}/search?q=&offset=&limit=` | 解析内容命中 | UI 锚点需有 artifact ID 与页/行，不解析任意磁盘路径去打开 |
| `GET /api/export` | 当前生成全库 ZIP | 没有稳定导出 artifact；中继当前禁止；不是已实现精装 PDF 手账 |

消息 `role`、`status` 和事件 `kind` 应可容忍未知未来值并保留原始字段；不能因为未认识一个事件就清除整个对话。`attachments` 在主机快照中是附件对象数组，发送请求中才是 ID 数组。

### 文件引用的跨栏定位

平板发送 `X-Haji-Features: artifact-links-v1`。主机只把已识别的格式能力标记写入该轮已有的 `message_created` 事件，并据此提供模型引用约定；这枚头不授予任何访问或工具权限。未声明的手机、浏览器及旧请求保持原有格式，不要求新增数据库列或请求体字段。

引用使用 Markdown 链接：`[文件名 · 第17页](hajisaki://artifact/<artifact_id>?page=17)` 或 `[文件名 · 第45–48行](hajisaki://artifact/<artifact_id>?line=45&end=48)`。页码、行号均从1开始，末行包含在范围内；不确定位置时只链接原件，不编造定位。客户端仅接受已配对资料库实际存在的附件ID，不解析或打开主机路径。页与行不可混用；非法、重复参数及未知文件显示可恢复的中文提示。原生段落和离线复杂排版共用这条路由。

定位仍通过现有鉴权下载并核验原件摘要。PDF在原页添加临时蓝色轮廓，源码高亮对应行并滚到附近；文本位置扫描逐块读取并离开主线程，不把整份大文件装入内存。高亮不改写导出的原件。找不到页或行时明确说明，保留原件浏览、批注和导出入口。此协议的功能观察与120ms门槛分别验收。

### 笔迹身份与图像来源

文档笔迹使用 `document:v3:library:<资料库作用域>:sha256:<原件摘要>:page:<1起始页码>`；图像使用相同前缀的`:image`。实际文件名为该标识的SHA256加`.drawing`。不使用会随安装而变化的沙盒绝对URL。相同资料库内相同原件内容共用笔迹；原件内容改变后保留旧原件对应的笔迹，不盲目套到新版页面。已下载原件复用已核验摘要；本机导入尚无摘要时在后台流式计算，避免占住UI或网关actor。PKDrawing仍是独立可编辑文件，合成PNG不覆盖它。

PNG导出通过ImageIO的Description保存`hajisaki-ink-v1`：图像像素尺寸、左上原点的归一化笔迹区域、笔数、RGBA颜色和有无底图。没有用户目录、主机路径或凭据。此数据作为客户端声明的对照资料，不能证明作者、审阅或授权。主机按PNG文本块读取并校验CRC，限制文本和解压长度，只返回白名单数值/颜色；不转发任意说明文字。图像像素仍由真实图像通道发送。模型应区分指定笔迹与原页插图，不主动向用户罗列内部坐标字段。格式依据为[Apple PNG Description](https://developer.apple.com/documentation/imageio/kcgimagepropertypngdescription)和[PNG文本块规范](https://www.w3.org/TR/png/#11textinfo)。

### 持久化与恢复顺序

1. 获取消息快照，将消息、活动运行和 `cursor` 放入一个本地事务。初次进入若已有缓存，先显示缓存，再合并主机快照。
2. 从该游标接 SSE；备用通道分页读取 events。只处理 `seq > 本地已提交游标` 的已鉴权事件，保存内容和游标在同一事务。
3. 断流时保留文本/图层/输入状态；显示正在接续，不伪造新回复。恢复从最后提交游标继续。终态到来后可用快照核对最终内容。
4. 每封信先生成并保存稳定 `client_id` 与附件关系，再乐观上屏和发送。同一 ID 的不确定请求只重试同一内容。现去重比较内容及附件，不能借重试暗换模型或档位。
5. 对话创建、fork、记忆创建等目前没有通用幂等键。遇到网络结果不确定，不自动用新 ID 在另一个通道再次创建；先读取核对或保留待确认状态。

`events.seq` 为全库自增，不同会话会交错；过滤后跳号正常。重放完整性应比较实际增量顺序和最终正文摘要，不能靠“序号连续”断言。

### 四层语义流

| 层 | 可显示的数据 | 禁止混淆 |
| --- | --- | --- |
| L1 | 提供方允许公开的工作/推理摘要 | 不能索取、伪造或声称暴露隐私思维链 |
| L2 | 工具名、阶段、状态、可授权查看的细节 | 内部日志和临时源码不裸露在主回复；实际未执行的工具不画成完成 |
| L3 | 顺序叙事、`reply_delta:{message_id,text}`、主回复 | 阶段旁白与最终结论都应保留 |
| L4 | 实际交付附件、已提供给模型的视觉资料、可核实审阅记录 | 当前 ACP `visual_input.status=prepared_for_model` 只表示准备送入，不证明模型已看完某页 |
| system | message_created、run_started/finished/stopped/failed 等 | 用于恢复和状态管理；不能伪装成祥子正文 |

主机 `bridge.py` 目前注册 `deliver_file_to_phone`、`deliver_image_to_phone`、`deliver_interactive_card`、`send_progress_note`。它们绑定单次 run 的 outputs 目录。iPad 宪章所称 `deliver_*_to_client` 尚需兼容别名或平台中性命名，且默认 CLI 策略未启用这组 MCP 工具。现 `POST /api/runs/{id}/deliver` 和 `/progress` 是主机内部交付入口，中继刻意拒绝，客户端通过 L4 和附件读取接收。

## 中继复用边界

协议来源 `relay/README.md`、`hajisaki_relay/protocol.py` 与 `connector.py`。现 v1 为 TLS1.3 + 客户端证书 + 角色令牌的 WSS 外层，内容再用 AES-256-GCM 加密；配对凭据在端到端密文内，relay 不持有载荷密钥。它是反向出口基础，尚不等于已部署的 WAN 热备。

- 每 channel 只容纳一个 `phone` 和一个 `host` 连接，第二个相同角色会被拒绝。手机与 iPad 同时使用需要真正的每设备 channel/配对支持；不能共享 `phone` 配置后宣称多端并发。角色名虽为 phone，二进制协议本身与设备 UI 无关。
- Frame：`HSR1` + uint16 大端 header 长度 + canonical ASCII JSON header + AES-GCM ciphertext/tag。header 含 v/kind/id/iat/exp/nonce；32位小写十六进制请求 ID；12 字节随机 nonce；方向隔离 HKDF-SHA256；AAD 为 channel + NUL + 原 header。原生应严格按已有协议实现，不能临时设计另一套“兼容”编码。
- 单块 body 上限4 MiB；上传采用 `min(主机 chunk_size,4 MiB)`。非上传请求上限2 MiB；响应体也受4 MiB限制。原生不得把2 GB文件 Base64成单一请求。
- 附件下载必须有明确起止且≤4 MiB的单 Range；校验 Content-Range、强 ETag、最终 SHA-256。无界 Range/多段 Range/后缀 Range 均被拒绝。
- 备用通道用 `/events` 轮询，不通过现 v1 长连接代理 SSE。现 allowlist 的查询参数不含 `archived`，不能带该参数直接复用直连会话列表；需调整共享协议后才支持远程归档筛选。
- `/api/export`、`/api/local-pair`、内部交付接口、任意 URL、`/artwork` 和未知未来路由均被拒绝。末次检查时新加入的Pin/任务卡接口也尚未进入中继allowlist，需同协议一起接通。原生装配自己的显示资源，不依赖通过 relay 加载 studio 静态文件。
- 已持久化请求 ID 和内容摘要提供 at-most-once forwarding。崩溃留下 pending 时返回 `outcome_uncertain:true`，并不保证“没执行”。不能为了恢复1.5秒指标就并发重发有副作用请求或抛弃 pending journal。
- 目前主机单组设备令牌与 relay 的每设备证书不是完整绑定。需扩展设备注册、吊销、token→certificate/channel 关联，再验收零信任与同时在线。

## 语音、提醒与主机能力的真实范围

已有 `/api/speech/status|hotwords|transcriptions|clean`；上传原音 artifact 后 `POST /transcriptions {artifact_id,language?,cleanup?}` 返回202任务对象，轮询 `/transcriptions/{id}`，停止用 `POST …/{id}/stop`。faster-whisper 工作进程提供文件转写、真实词概率、用户词典和保守口语清理。当前默认上限512 MiB/30分钟，无声学 Top-3、说话人分离、350ms实时采集转写或原音直投模型。`candidates:[]` 不得拿词典建议假扮声学候选。iPad AVAudioEngine/Opus 分段录音与断点缓存需另外实现。

已有 `/api/reminders` GET/POST、`PATCH /{id}` / `POST /{id}/update` 与 `/api/inbox` GET、`POST /{id}/read`。创建字段为 content、带时区的 due_at、IANA timezone、repeat(once/daily/weekly)、可选 conversation_id。5秒调度写入持久 inbox，当前不是自动浏览网页总结的 Agent 哨兵，也不是 APNs 送达证明。

旧聊天由主机有界近期记录和显式记忆辅助恢复。末次检查时共享 `context.py` 已加入消息/附件/文字Pin与任务勾选状态，`provider.py` 将它们注入模型上下文；这是源码集成，尚未由本次审计完成运行验证。消息Pin摘录上限12000字符，附件Pin含元数据及最多8000字符的受支持文本摘录，不等于全文语义索引。完整长期摘要、附件语义索引和30/180天时间跨度尚未验收。文件写入、危险命令、可信生物审批、快照回滚不得因为存在 Diff 面板或一个 Touch ID 按钮而视为实现。

## 消息分块与原生滚动

`ConversationLayout`在后台按语义块解析并复用未变源，助手标题、活动、文字/代码/公式、附件和状态为稳定ID的平面行；不生成空活动或完成状态占位行。`ConversationList`使用UITableView复用这些行，UIHostingConfiguration只负责承接既有SwiftUI/TextKit/WebKit内容。每个单元格保留独立可观察内容模型；同一行更新模型，换行才替换hosting配置，避免在菜单呈现或高度更新中重建其他行的状态。[Apple UIHostingConfiguration](https://developer.apple.com/documentation/swiftui/uihostingconfiguration)

正文普通段落仍为原生选择面，复杂块使用离线WebKit与按源/宽度/字号/主题登记的有界高度缓存；含真公式的待办正文也走同一数学渲染器，勾选保持原生按钮和主机持久状态。UITableView负责自适应高度，拖动解除跟随；阅读锚点保存可见行ID与相对位置，触摸/拖动/减速期间不强行调整。回到最新使用列表内的44pt原生控件，坐标始终按视口定位，水平偏移固定为0。尺寸测量、语义锚点与最终实机性能分别验收，原生复用本身不代表500条/15000字/60FPS指标通过。[Apple selfSizingInvalidation](https://developer.apple.com/documentation/uikit/uitableview/selfsizinginvalidation-swift.property)

## 独立 HTML 交互微剧场

Inspector 将已通过配对资料库取回或由用户选择的 `.html` / `.htm` 作为独立演示打开。输入为最多2MiB的UTF-8单文件；读取在后台进行，原件不改写。页面内联脚本可以处理曲线、滑杆等演示，外部库和联网资源不在该模式的合同内。源码通过原生有界文字阅读器显示，原件沿用文件保存器导出。

这一路径使用独立、非持久的WKWebView，不复用富文本池的链接/复制处理器，也没有通往主机、凭据或原生文件的脚本消息接口。原文位于只含`allow-scripts`的sandbox srcdoc iframe，保持opaque origin；外层和内层CSP、内容规则及导航delegate共同限制外部资源/导航。位置、摄像头、麦克风、运动、文件选择和新窗口均不作为页面能力开放。脚本是附件内容，不能因模型生成就取得原生应用权限。

当前卷宗拥有一个`InteractiveDocumentSession`，源码切换及横竖屏重新挂载复用同一DOM，保留参数和内部滚动位置；换成另一份卷宗或重开应用会开始新的演示会话，不宣称跨重启保存任意网页内部状态。Web内容进程终止时展示可重试状态；这类局部内容失败不影响主机对话或构成Codex会话恢复触发。

沙箱标志与srcdoc转义依据[WHATWG iframe规范](https://html.spec.whatwg.org/multipage/iframe-embed-object.html#attr-iframe-sandbox)，内容规则采用[WebKit支持的规则格式](https://webkit.org/blog/3476/content-blockers-first-look/)。实际运行证据和未完项仍以验收记录为准；源码约束不能替代所有恶意内容/硬件组合的运行验证。

## Apple 原生边界

| 能力 | 实现合同 | 验收界限 |
| --- | --- | --- |
| Pencil squeeze / hover / roll | UIKit `UIPencilInteraction` 或 SwiftUI `onPencilSqueeze`；尊重用户 squeeze 偏好；roll 用于笔刷角度/形状 | 系统偏好为快捷指令时 app 可能不收到 squeeze；触摸/鼠标替代操作不证明 Pencil Pro 实测 |
| Pencil 触感 | `UICanvasFeedbackGenerator(view:)`、`pathCompleted(at:)` / SwiftUI `.sensoryFeedback(.pathComplete,…)` | 是系统反馈请求，实际可能为触觉、声音或无输出；不能承诺自行控制马达波形或20ms同步 |
| PencilKit | 保存 PKDrawing 原始数据与坐标/页关联，显示单独批改图层 | 模拟器画线不证明压力、悬停高度、倾斜、roll 或≤12ms硬件延迟 |
| Touch ID | LocalAuthentication 按实际设备能力显示 Touch ID/密码 | iPad Air 不标 Face ID；只有本地成功回调不能授权未经绑定的远端任意命令 |
| Widget | WidgetKit扩展 + AppIntent；共享容器中的待办状态 | 需要工程签名/entitlement与真实持久状态；静态图片不是交互小组件 |
| Live Activity | ActivityKit + WidgetKit扩展；状态由 app 更新或 APNs 更新 | 活动本身不能联网，数据体积受4 KB约束，通常最多活动8小时；不是7×24常驻任务后台 |
| Spotlight | Core Spotlight 索引可公开条目和稳定深链 | 私密内容的索引策略必须明确；未解锁保险箱不能泄漏正文 |
| Share / drag | 系统文件导入、安全作用域资源、NSItemProvider/Transferable | 大文件按流处理；导入结束前不把临时 URL 当永久原件 |
| Tailscale / WireGuard | 优先系统已安装客户端，隧道配置由本人确认；内嵌 Network Extension 是单独能力 | 应用挂起后不能靠普通前台 SSE 保持永不掉线；恢复靠耐久重放 |

Pencil 接口与平台反馈边界据 [Apple WWDC24 Pencil 会话](https://developer.apple.com/videos/play/wwdc2024/10214/)；Live Activity 约束据 [ActivityKit 官方说明](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)；交互 Widget 据 [AppIntent 按钮与开关](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)。使用新 API 时以项目实际安装 SDK 的 availability 为准，不将较新文档符号强塞进旧编译目标。

## 验收与继续推进

登录、签名、USB信任、设备权限或网络部署待完成时，继续可独立实现的源码、资源、离线存储、平台适配、真实构建和可用环境中的直接操作。演练模式必须明确标注非真实 AI；它能验证协议/状态处理，不能证明模型正确率、WAN可达或硬件性能。正常命令/API/UI操作、现有检查和必要截图是允许的；未经用户明确要求，不新增测试套件、夹具、断言脚本或临时测试运行器。

每项通过必须有源码版本/产物、实际入口、观察状态和证据范围。构建、静帧、浏览器操作、模拟器操作、真机 Pencil 和 Instrument 指标各自独立记录。任何页面、未完成 Promise、说明文案或“已准备”资源均不能代替原宪章中的功能完成。

本次文档审计未移动或删除文件，未变更主机/手机运行状态，未读取凭据内容，未启用定位服务。
