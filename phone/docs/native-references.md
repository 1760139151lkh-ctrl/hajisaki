# 电脑代码与过往乐章引用

原始目标包括输入 `@` 检索电脑上的真实代码文件/文件夹及过去的对话。本实现通过主人开放的目录和用户明确选中的内容生成引用附件，复用当前乐章的既有附件、离线草稿与受限模型读取工具。斜杠模板、语气切换和真正的长上下文压缩仍属于原始范围，未由本页引用功能代替。

## 使用与数据合同

手机输入区的 `@` 按钮，或正文末尾独立的 `@`，打开原生选择页。电脑代码支持名称检索、目录切换、进入/上一级和当前文件夹引用；过往乐章支持正文/标题检索和 40 条一页的历史结果。原有草稿、模型运行和底下的阅读位置保留。选中内容先加入未发送附件，发送仍由用户操作；如果原来的输入已变化，不覆盖它。

引用是选取时刻的材料。Markdown 附件注明来源、收录时间、原文件摘要和完整可读内容。它不会自动跟随电脑文件之后的变化。文件夹只收录允许的代码和文字类型；依赖、构建缓存、配对资料和私有目录被排除。正文超过 1MiB、文件夹超过 64 份或展开超过预算时明确失败，并保留原文件；不把截断内容冒充完整文件夹。

主机浏览器“主机 → 可引用的代码目录”可新增/停用/开放目录。设备注册的 owner 身份才可修改。手机 companion 只能看到已开放目录的名称和标识，不接收电脑绝对路径。默认记录本工程目录；其他本机目录通过主人界面明确添加。原文件只读，AI 的 MCP 工具仍只读取本轮乐章实际分享/钉选的附件。

## HTTP

全部路径均要求现有设备认证：

- `GET /api/references/roots`：`roots` 和 `can_manage`；owner 返回实际目录路径，companion 只返回开放项的名称/标识/可用状态。
- `POST /api/references/roots`：owner 专用 `{name,path}`，路径为本机绝对目录；最多同时开放 12 项。
- `POST /api/references/roots/{id}/update`：owner 专用 `{enabled}`，不删除原目录。
- `GET /api/references/roots/{id}/entries?path=&q=&limit=60`：相对路径浏览；有 q 时在当前目录内递归查找。一次最多 100 项、10000 个候选/2 秒，未覆盖完时明确 `partial:true`，可缩小目录或关键词。
- `GET /api/references/history?q=&offset=0&limit=40`：实际公开消息及标题检索，没有三个月日期截断；分页返回来源消息 ID、角色、时间、标题和摘录。私密保险箱与正在生成的消息不列入引用。
- `POST /api/references/snapshots`：`{kind:file|folder|message,root_id?,path?,message_id?,operation_id}` → `{artifact,origin}`。同设备、相同操作号/参数返回同一附件；变更参数冲突。使用正常 CAS 上传/完成通道，无临时文件复制或源文件改动。

文件读取核对前后状态与字节摘要，支持严格 UTF-8/UTF-16；路径逃逸、私有运行目录与越界链接被拒绝。文件夹、查询分配和读取时长有界。长操作后再验证设备钥匙，避免已吊销设备继续接收结果。中继只增加 roots/history/entries 的 GET 和 snapshots 的 POST；目录管理没有加入中继白名单。

## 已观察的证据

- 主机代码 `host/hajisaki/context.py` 实际 9425 字节；检索返回正确相对路径，完整引用附件 9645 字节，`3a999c9752b742cca55b380f58cd7873`，SHA `5d97d145b82ed14a8d4743e664155812f108073ecf65b54e29d9d225bb4ed2a5`。CAS 文本包含完整当前源码和原文件 SHA；同操作重试返回同一附件。
- 实际 model 目录的引用附件 `ce7caac7dc154b5e91a734d6acea5d9c`、28743 字节；真实旧消息 `9d09871d58444b6da924d010ad311363` 引用附件 `143e37b80175432c898f5e50aa459f35`、521 字节。原请求和响应在 `runtime/reference-{file,folder,history}-receipt.json`。
- companion 请求运行资料目录实际 403；尝试新增目录实际 403。未读取或输出配对秘密。
- 现有主机浏览器后台正常新增“手机源码”目录 `53a342c37a0f4e94be06c4d3da5969f5`，实际路径为本工程 ArkTS 源码目录；680px 对话框已亲自查看 `tooling/evidence/reference-owner-roots.png`。停用后手机读取实际 404，重新开放后检索 Types.ets 实际 200，记录重启后仍保留。
- TLS/HSR1 参考客户端通过既有中继读取 `host/hajisaki` 下的 context.py：真实请求 `0f2ae6916c3a40f88e0e924bf8fcdc4c` 状态 200，返回相同相对路径与 9425 字节，执行不确定为假。

手机第一次输入 @ 能打开真实目录页；随后键入未进入搜索框，已通过应用内 UIContext FocusController 和输入框挂载后的焦点交接修正，并禁止隐藏输入区接收按键。修正后的 `native-reference-focused-query.jpg` 显示连续输入的 context.py 和真实结果。选中后实际加入未发送附件、清除触发符，`native-reference-file-attached.jpg` 已查看；生成附件 `e6ef9aadb55845079c06ac758ca34f0a` 为 9645 字节，消息数仍为 18。点击该附件实际显示来源、原摘要和完整代码，`native-reference-file-preview.jpg` 已查看。

同一原生会话先后选择了真实 model 文件夹、context.py 和包含 marker 的旧提问。三个附件分别为 `c5ff36b7dfaf4745a4d3478fea10c3ba`（28847 字节）、`8d2e5a5f6c7e41519d743d72fdb6b384`（9645 字节）、`efc54f3c45e14fecb031b8c3c1b91699`（264 字节）；发送前没有新增消息。实际点击“送出”后，既有会话运行 `92239df4981a44cab242153101af0b00` 完成，五次附件搜索/读取事件分别命中了这些原件，正确回答 20 枚 pin、BuildMode.previewMode 和被引用提问的含义。原始运行/消息/事件证据为 `runtime/reference-model-receipt.json`。回复从提交到完成约 12 分 38 秒，这不是延迟指标达标的证据。

已亲自查看 425vp/320vp 的实际代码与历史页、日夜配色、活跃运行时分行工具栏。取消选择保留 `keep this thought @`，回到名录再进入仍保留，同一次临时预览内有效，不冒充设备重启持久性。实际引用整个工程目录得到 413；错误说明与“重试”完整显示，重试仍正确拒绝而未添加半份文件夹。零模型任务时正常停开手机网关，离线查询保留关键词和草稿，恢复后点重试取得 context.py；未中断模型会话或更改 iOS 服务。

最终检查发现并修复了两处缺陷：新查询失败时显示旧目录列表，现已在请求前清空结果；后台完整回复已保存且 SSE 已确认，但消息卡片经按值构建回调仍停在旧状态。已将消息正文和状态放回直接观察 MessagePart 的组件，避免跨构建回调丢失刷新依赖，依据[华为构建函数参数规则](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-builder/)。实际后续运行 `735a538369dd4af18607602816ad3f14` 从未生成状态开始，在同一个挂载中的聊天页接收 seq1158–1170，正文、内联代码和复制/引用操作随回复更新，等待提示与停笔按钮正确结束；`native-reference-live-row-corrected.jpg` 已亲自查看，原始记录在 `runtime/reference-live-row-receipt.json`。期间模型服务报告一次 attempt1 的五分钟流空闲超时，原请求继续并最终完成；没有将服务级重试信息当成 Codex 会话终止。最终代码又按相同入口复查断线：正常停开零任务网关后查询 context.py，错误页保留查询与重试，旧目录项已清空；实际画面 native-reference-offline-cleared-corrected.jpg 已查看。

检查时实际已有公开历史 84 条；40 条首屏页底“更多往事”进入下一页，第一条为 `98cc3f83d877425fa9117b554738c3f5`，与 offset40 的 API 结果一致，原始图为 `native-reference-history-first-pagination.jpg` 与 `native-reference-history-page-two.jpg`。这是实际已有日期的数据，没有伪造早期记录。

现有历史样本没有三个月前的记录，不能将无时间截断的接口等同于旧数据实测。桌面 SDK 另有配对原生异常 0xc0000005；本次两次相同地址的异常及后续正常实例均已保留。当前实例的地址映射指向 SDK 资源管理模块，但没有失败进程调用栈，根因尚未确认；记录为 `runtime/native-reference-crash-observations.json`。真机 IME/安全存储/权限/硬件性能及完整原始章程仍待相应实现和实际检查。

最终断线复查中，主机恢复后同一“重试”返回真实 context.py；选择形成附件 `531e4c27e6fa418fafe961d8664cd0f4`，保留 offline note 草稿并移除 @ 触发符。点击名称实际显示当前源码、来源和原始 SHA，`native-reference-recovered-code-view.jpg` 已查看；消息仍为 22 条，没有自动发送。

调整消息组件后，实际点击新回复的“引用”将完整最新正文放进未发送输入区，`native-reference-live-reply-quote.jpg` 已查看；读取的是已到达的回复而非初始等待文本。

双击正文原先会被子级文字选中手势拦下。将消息气泡的双击改为 `priorityGesture` 后，最终代码在 320vp 实际打开“静谧手稿”，完整显示刚才的新回复；`native-reference-priority-reader-result.jpg` 已亲自查看。

阅读返回首次复查发现跳到第一条旧消息，现已让进入阅读时保存现有阅读锚点，并由标题返回及“带回琴房”统一恢复。最终 320vp 先在最新回复打开/返回，再上翻到前面的内容打开/返回；两组前后完整截图均已查看，逐像素差均为空。原始图为 `native-reader-anchor-tail-{before,after}.png` 和 `native-reader-anchor-older-{before,after}.png`。

本次只把 `runtime/reference-browser-action.json`（167 字节，约 0.2KB）及新模块缓存 `host/hajisaki/__pycache__/references.cpython-313.pyc`（36427 字节，约 35.6KB）直接送到系统回收站，记录为 `runtime/reference-cleanup.json`。保留源码、引用原件、请求回执、故障映射、构建日志和原始截图；大小为文件逻辑大小。

该引用阶段的 API26 普通和临时预览构建均通过。以下记录对应当时的发布包；后续最新版见 `native-composer.md`。当时包已包含引用选择、实时消息行、双击阅读及位置恢复；实际读回摘要与各自清单一致，220 份构建输入均无摘要偏差，两个包均保留编译 ABC 与第三方声明。记录为 `runtime/reference-release-verification.json`。

- `releases/hajisaki-openharmony-api26-unsigned.hap`：63772928 字节，SHA-256 `6945868d27569abcff46b6fe9a161ebde3d06950a2d2269ea6434ccc1b5b6274`。
- `releases/hajisaki-preview-api26-unsigned.hap`：63773664 字节，SHA-256 `e4a25163b90c900d4cc9a0cf55ae3feaa70afba8f398179a04ae15ae33cd40f0`。

它们仍为未签名 OpenHarmony 诊断包，临时预览的存储声明保持独立。真实 Huawei SDK/签名/设备安装、安全存储和系统特权验收仍需对应条件；本阶段没有把整个原始宪章标为完成。
