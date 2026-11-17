# 哈基祥 · HarmonyOS 原生客户端

主目标是 HarmonyOS 7 / API 26。ArkTS / ArkUI 承担页面和基本富文本，复杂公式、表格、图表与乐谱使用本地打包的 ArkWeb 渲染页。

## 工程入口

- `entry/src/main/ets/pages/Index.ets`：记忆长廊、对话、手稿阅读、记忆调律、档案和主机页面。
- `services/Companion.ets`：真实网关接口、离线待发、历史同步、事件重放、停止、分叉和设置。
- `services/LocalStore.ets`：S3 加密 RDB、本地历史、草稿和待发队列；写入串行化，事件与 cursor 在同一事务保存。
- `services/EventStream.ets`：认证 SSE、分块 UTF-8 解码、12ms 合并窗口与按序重放；消息、事件和游标在同一事务确认后更新。
- `services/Gateway.ets`：Bearer + 设备绑定、私有地址限制、安全读取备用重试、加密中继适配与保留原请求编号的回执重查。
- `platform/`：Asset Store 安全配对凭据、文件选择、分块上传/校验下载、AAC 录音、生物识别，以及默认关闭的有线/USB 耳机琴音和触觉反馈。能力和 API 来源见该目录 README。
- `components/NativeManuscript.ets`：原生标题、段落、列表、引用、基础行内排版、代码横滑/行号/折叠/复制，以及绑定服务器状态的待办复选框。
- `components/ArtifactRoom.ets`：1MiB以内文字/源码成品翻阅、按原件摘要缓存、Markdown排版/原文切换；HTML使用独立无主机桥的ArkWeb，禁用网络、文件、存储、定位和权限请求。
- `components/ReferenceRoom.ets`：输入 `@` 或点击同名按钮，在主人开放的电脑目录中找代码/文件夹，或搜索实际历史消息。选中后生成带来源和摘要的快照附件，先审阅，再由用户发送；原文件保持只读。目录在主机页面配置，合同与证据见 `../docs/native-references.md`。
- `components/CommandRoom.ets`：`/` 常用起笔、当前乐章语气与真实上下文整理。模板插入保留未发送内容，语气随待发消息保存；整理沿用实际运行、原始记录附件、停止和状态恢复。合同与当前检查见 `../docs/native-composer.md`。
- `components/MessageRow.ets`：直接观察语义消息行的正文与状态，渲染增量回复、附件和相关操作；数据源复用稳定的行标识。
- `components/StudioRoom.ets`：原生草稿纸和照片批注，画笔／编号即时落笔，主机处理马赛克、旋转、四角拉正与纸张增强；操作和图像检查点写入既有 LocalStore，导出 PNG 放回未发送附件。合同、容量与实际观察见 `../docs/native-image-studio.md`。
- `components/PicturePreview.ets`、`ImageRoom.ets`、`services/ImagePreviews.ets`：聊天图片、图片墙、按来源摘要缓存的真实缩略图/占位、大图缩放/平移/柔光、原图追问与 L4 工具读图凭证；关闭图片页保留原阅读位置，批注返回保留倍率。合同与验收边界见 `../docs/native-images.md`。
- `components/PdfReader.ets`、`WorkbookReader.ets`、`ArchiveReader.ets`：原生二进制成品阅读，支持真实纸页、工作表/行分页、固定表头首列和ZIP目录；已打开的页按原件摘要缓存，恢复页码/工作表/倍率。纸页由主机受限进程解析，原件仍独立保留；详见`phone/docs/native-document-readers.md`。
- `resources/rawfile/renderer/`：从 `studio/dist` 复制的离线 Markdown、公式、图表和乐谱渲染器，无网关认证或文件访问桥。

图片只从 `assets_pipeline/native-resources.json` 的已选资产复制。保留了用户指定的年轻祥子参考形象，原图未缩小替代。

## 构建

使用 DevEco Studio 26 打开本目录，配置本机 HarmonyOS SDK 和开发签名。`default` product 始终是 Huawei HarmonyOS 26，不能用下面的诊断包声称完成真机验收。

```text
python phone/harmony/tools/sync_resources.py
python phone/harmony/tools/build.py --hvigor <DevEco中的hvigorw.js> --sdk <HarmonyOS-SDK目录> --java <JDK21目录>
```

Hvigor 要求工程路径仅含受支持的 ASCII 字符，并检查实际路径，不接受项目 junction。原工程路径含中文时，使用 `--build-dir <ASCII暂存目录>`；脚本只同步本工程到带专属标记的构建目录，不移动原项目。SDK 的打包器对非 ASCII 路径也可能有编码限制，SDK 应使用 ASCII 安装路径或有效目录别名。

项目另有 `openharmony`（API 26）和 `legacyDiagnostic`（API 23）两个公开 SDK 诊断 product。暂存构建仅将这些诊断 product 的设备类型转为 OpenHarmony 的 `default`，原始 Huawei `phone/tablet/2in1` 配置保持不变。

```text
python phone/harmony/tools/build.py --product openharmony --build-dir <ASCII暂存目录> --sdk <OpenHarmony-SDK根目录>
```

未签名 HAP 不能直接替代用户设备签名安装。签名配置由 DevEco 的实际账户和设备生成，不在仓库保存密码或私钥。

另有显式 `preview` product。它通过官方生成的 `BuildProfile.PRODUCT_NAME` 和 `DEBUG` 常量选择临时内存存储，使用不同包名，并持续显示“临时预览 · 本机记录关闭后清空”。它使用真实 HTTP/SSE 和正常用户操作，不注入示例对话。其他 product 始终使用加密 RDB，不因数据库错误自动降级。该模式用于绕过桌面 Previewer 的 RDB 模拟实现，不能验证持久性。参数用法依据[官方 BuildProfile 文档](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-hvigor-get-build-profile-para-guide/)。

## 使用链路

主机台输入主通道 HTTPS 地址、可选的另一条直连地址、设备编号和主机配对令牌。独立加密备用路径从“配置备用琴房”导入。原生端不会开启系统定位。HTTP 仅接受显式私网开发地址；是否准许开发明文流量仍服从设备网络安全策略，生产使用 HTTPS。

连接后，模型与档位来自网关真实目录。发送前先提交本地 outbox，成功确认后才标记已送出；重试沿用同一 `client_id`。已打开和同步过的历史、草稿可离线读取。连接时预取其余对话文本；附件原图仍需下载，不能声称全部媒体自动离线。

首次同步使用服务端事务快照及其事件水位，之后用 SSE 增量更新。健康 SSE 不轮询；断开后使用 REST 补齐并重新建立流。停止时界面立即冻结，后续接收仍基于独立的已提交内容缓存，避免覆盖已收到的字。离线接续、历史分叉、上下文钉选和待办状态使用真实 API。上翻阅读时停止跟随，保留回到最新页入口。

消息按语义分块进入 LazyForEach，未变化的内容复用解析结果；围栏、公式和表格保持完整。带脚注、跨段引用或待办索引的文档保留完整文档作用域，不能据此声称所有长文结构都已充分虚拟化。

配对凭据保存在系统 Asset Store 的加密 SECRET 中，包含主地址、备用地址和设备绑定，禁止同步；需要设备锁屏密码。保存不可用时只维持当次会话，并准确提示需要重新配对。原生生物识别目前用于本机私密分组，不等于远端危险命令的可验证签名。

加密中继从“配置备用琴房”进入`Companion.importRelay`，实现主机设备绑定导出、文件/密码字段导入、HMAC封签、安全钥匙存储及恢复。它要求可信CA、客户端证书/加密私钥、服务器SPKI固定摘要、通道令牌和载荷密钥；通过HTTPS TLS1.3+mTLS承载AES-GCM帧，请求在加密日志落盘后才发送。提交前实际读取认证状态，设备钥匙更换后停用不匹配路径；不确定旧写操作的钥匙不被丢弃。中继使用事件查询和有界Range下载。普通第二直连地址与该路径分开。预览器已实际检查结构校验、受限保存和主连接保留；设备端HMAC/安全存储恢复/TLS正负向握手仍需实测。详见`../docs/native-relay-import.md`。

`POST .../update` 是 PATCH 的等价网关入口，因为当前 NetworkKit 的 HTTP 方法枚举未提供 PATCH；不是绕过认证。原生生物识别目前用于本机私密分组进入，不冒充服务端可验证的敏感命令批准。

## 当前验证边界

已用公开 SDK 23 和 26 执行真实 Hvigor / ArkTS / 资源打包，并通过桌面原生 Previewer 查看页面、切换主题、进入表单和读取实际主机数据。预览器的 HTTP 为实际实现，RDB/Asset Store 和部分系统 API 有模拟限制；ArkWeb 在该预览器显示不支持提示。复杂渲染器另在浏览器观察，不能替代原生设备验收。端侧 RDB 持久性、录音中断恢复、文件选择、生物识别、声触、原生 ArkWeb 高度桥及硬件性能仍待设备观察。

受管MCP实际生成的CSV已通过原生“翻阅”取得并显示，Markdown原文也已实际显示。该份Markdown含复杂结构而走ArkWeb排版，在本预览器仍显示不支持；原文切换提供独立可读路径，不将它视为原生富文本已验收。HTML卡片在Studio实际交互通过，原生ArkWeb脚本隔离仍需对应目标设备确认。

手机端尚未完成的范围包括：原生Mesh VPN、中继设备端验收和完整自动双向切换、实况窗/Push Kit、桌面卡片、UDMF分享拖拽、系统级剪贴板、端侧五重语音纠错/Opus、原生图像拉直与画板、双模型竞技场、完整富文本AST虚拟化/预热容器池，以及知识长图和主动提醒的系统通知接入。共享主机/Studio已实现的能力不自动等于手机端完成。

12ms 合并窗口不是对实际额外延迟、高刷帧率、600ms 冷启或50ms远端取消的通过声明；帧率、功耗、温升、录音延迟和实况窗性能保持待测。原始 WAV 已随包保存；音色与声触同步没有经过实际听感或设备测量验收。产物和来源清单由 `tools/package_release.py` 复制到仓库 `releases/`。
