# 原生图片墙、读图与所见画面

本页记录鸿蒙手机分支的图片链路。目标仍为 HUAWEI Pura 80 Pro、HarmonyOS 7 / API 26；隐藏的官方桌面 Previewer 只能提供原生渲染与普通网关操作证据，不能替代华为签名、手机硬件和生产存储验收。

## 手机入口与状态

- 聊天图片附件直接显示原生缩略图；点击展开大图。文件名、批注与保存入口保留。
- 档案的“图片”页使用 LazyForEach/Grid，两列窄屏、三列宽屏，只列真实图片。导入沿用系统文件选择与原件上传通道。
- 大图支持 100–300% 倍率、按钮复位、平移和捏合处理；柔光只影响当前显示，不修改原件。GIF 路径明确显示“动图首帧”。PDF 读取凭证可直接打开所取出的那一页。
- “围绕这张图追问”把同一原件加入当前乐章的未发送附件；没有当前乐章时创建一个空乐章。它不代写问题或自动发送。
- 图片页覆盖在现有聊天、过程页或图片墙上，关闭后底下的滚动位置保留；批注页再覆盖图片页，返回后倍率和平移保留。
- 预览失败可重新取图。缓存写入失败会说明尚未收进手机，保存原件失败由现有文件通道明确反馈，不显示虚假的已保存状态。

`ImagePreviews.ets` 合并同一来源/规格的请求，按 SHA-256、规格和 PDF 页号缓存已访问的实际图片及占位；24 项内存缓存只保存缩略图，大图不进入该内存缓存。生产路径仍是现有 S3 加密 RDB，临时预览产品只保留会话内记录。当前没有把这些有限缓存当作完整容量管理或 380MB 内存指标的证据。

## 网关合同

认证 `GET /api/artifacts/{id}/thumbnail?width=480` 支持 480 / 960 两种有界规格。参数范围为 160–960；不大于 480 选择 480，其余选择 960；图片不会放大。返回 `supported,width,height,mime,image_base64,source_sha256,thumbhash,placeholder_base64,animated`。

PNG/JPEG/WebP 以及 GIF 首帧经既有独立图片进程处理。源文件最多 64MiB，受限解码、512MiB 子进程、最多两路并行和 25 秒超时沿用画室。480 规格图像字节预算 128KiB，960 为 320KiB；PNG 优先，必要时使用 JPEG 或保留透明通道的 WebP，再按需缩小。原件不重写。不可变缩略图缓存位于主机 `image_previews` 表。

ThumbHash 由固定依赖 `thash==1.2.1` 的纯 Python 实现生成。认证 `GET /api/artifacts/{id}/image-info` 先返回 `supported,width,height,thumbhash,source_sha256,animated`，不携带图片字节；手机再请求实际缩略图。该路径已加入既有中继白名单。当前场景的元数据响应为 186 字节，GIF 为 189 字节。

手机端 `ThumbHash.ets` 按官方参考算法直接解码 hash，处理亮度、色度、透明通道和近似宽高比，再生成不依赖系统图片编码器的小 PNG。`picture_meta_v2` 只保存来源、尺寸和 hash，读取后在手机计算占位；旧版 PNG 元数据仍可回读。主机提供的预解码 PNG 保留给原有客户端兼容，手机优先使用本地算法。解码器及 PNG 写入器采用 Evan Wallace 的 MIT 许可实现，完整许可文本随 HAP 的 `rawfile/third-party-notices.txt` 交付。

真实图片保持可解码状态；收到原生加载完成回调后，上方占位层用 180ms 动画淡出。占位按真实元数据放入与图片相同的显示区域，保留相同留边；初版拉宽了占位，已通过实际录制发现并修正。手机不为展示动画延迟图片。当前已录到占位、混合及清晰帧；SDK 图像传输时间不能代替真机帧率或触屏时延验收。

新 GET 路径已加入既有中继白名单；不扩大到任意 URL、磁盘路径或主机命令。大图仍沿用画室有界预览，PDF 页面仍沿用 `page-image`，保存继续走原件下载。

## 真正的工具读图

ACP 专属 MCP 新增 `read_attachment_image({artifact_id,page?})`。`page` 从 0 开始；图片可省略。它复用当前运行的短期授权，只允许读取当前乐章已附带或钉选的原件，返回 MCP 的真实 image 内容块及来源、尺寸和页号。文字提取不算视觉读取。

工具成功返回后持久记录 L4 `image_tool_read`，状态为 `pixels_returned_by_tool`，以及 L2 动作说明。L4 包含原件、来源摘要、尺寸、PDF 页号及适用的首帧标志。这只是“授权工具已返回这些像素”的证据，不代表能证明模型注意力、理解或完整审阅。

手机分别显示“随消息附上的画面”和“工具取出的画面”；后者可展开对应图像或 PDF 第 N 页。内部事件名不进入普通文案。

新运行使用 `tool_profile:3`、`gateway-tools-v3`，共 14 个精确允许的工具。已有不带版本的授权继续使用 13 工具旧目录，旧策略文件不改写，避免干扰独立 iOS 主机的既有运行。模型会话标识保持原有值；策略版本迁移不创建替代模型会话。

## 本轮实际观察

- 新场景元数据直连返回 186 字节；真实 TLS/HSR1 中继请求 `fd2ef249bf3c446695688a35a96c270c` 返回相同 186 字节、状态 200、执行不确定为假。未配对调用新接口实际返回 401。
- 手机生产解码函数对现有场景 hash 生成 32×23 RGBA，对现有透明月星图 hash 生成 32×32 RGBA；与官方 JS 参考输出逐像素相同，四通道最大差均为 0。真实透明输出 alpha 范围为 0–217。对应 PNG 为 `native-thumbhash-local-scene` / `reference-scene` 和 `local-alpha` / `reference-alpha`，位于 `tooling/evidence/`，已查看实际图片与差值。
- 正常原生操作的第一次 GIF 加载录制保存了 17 份原始 SDK JPEG；发现占位留边问题后修复，重新冷启动录制保存 9 份 JPEG。最终 `native-thumbhash-fit-gif/` 的 679.510ms 帧显示本地占位，783.151ms 帧显示混合，880.112ms 帧已清晰；相邻控件位置保留。三个实际图像均已亲自查看。`frames.json` 保存全部顺序与传输时间，属于 SDK 捕获序列，不是硬件 FPS 读数。
- 公开参考原件来自 [NASA's Scientific Visualization Studio / Moon Essentials: Parallax](https://svs.gsfc.nasa.gov/5320/)，保留在 `assets_pipeline/reference-media/moon-parallax.gif`。实际 1,179,533 字节、1024×1024、2 帧，SHA-256 `2ea7e2783b32fb985d9268eda21da4142ec346bfc02a1905a73725648a741d5c`。正常上传所得原件 `3e1093b3b82a45949a3c91c87233515d`，主机报告 `animated:true`，原生查看页明确显示“动图首帧”。
- 真实运行 `e67474626760491988c341b64a19eb13` 在同一应用乐章读取该 GIF，L4 序号 1124 记录 960×960 首帧与 animated 标志；模型准确描述满月、日期/UTC 和 Tokyo/7 PM，并在序号 1133 正常完成。等待期间保留原有模型会话，没有因等待创建替代请求或会话。
- 主机确认无活跃模型运行后正常停止。离开档案再重新进入，新的原生图片组件从缓存重开；之后新挂载的大图也能显示同一首帧。`native-thumbhash-offline-loaded.png` / `native-thumbhash-gif-offline-viewer.png` 已亲自查看，界面仍正确显示断连状态。离线重开捕获的 6 份原始帧另行保留。临时预览观察不代表生产 RDB 重启持久性。
- 320vp 复查发现文件名被同排操作挤压，PDF 名称只显示几个字、大小也换行；已把窄屏文件信息和操作分成两行，并保留 44vp 操作高度。`native-thumbhash-compact-inline.png` 为原始问题，`native-attachments-compact-after.png` 已显示完整名称和单行 320.7KB；同一卡片的翻阅实际打开正确 PDF，见 `native-attachments-compact-reader.png`。
- 该翻阅路径另暴露原有页面切换会丢失对话位置：返回后跳到最早消息，原始观察在 `native-attachments-compact-reader-return.png`。文件阅读已改为覆盖在原页面上，底下的对话、过程或档案保持挂载；关闭后直接露出原页面。初版误用了会阻塞子控件的 `HitTestMode.Block`，返回未生效；已对照[官方触摸测试说明](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/arkts-interaction-basic-principles/)改为允许子控件响应、阻止兄弟节点穿透的默认模式。原始失败帧保留。
- 修正后的默认模式已实际从同一 PDF 卡片打开阅读，再由其返回按钮关闭；`native-reader-fixed-before` / `open` / `after` 的原始 JPEG 均已查看，前后 PNG 的逐像素差异为空，原来的阅读位置保持不变。
- 历史中的真实失败回复 `68a535691ccb4809b155d67fe1e1856e` 状态为 failed、正文为 0 字，原来只呈现空卡片。现为这一状态显示“这一页暂时没能写完，你的话和原件都还在。”，空正文不显示复制/引用，分叉和钉住保留。Pura 尺寸的实际历史已查看：`native-failed-reply-readable.png`。
- 最终 Pura 源码中，从档案 GIF 大图选择追问后回到原有乐章，出现独立文件名和移除按钮；点文件名实际展开同一首帧，未移除附件。`native-gif-chip-unsent.png` / `native-gif-chip-open.png` 已亲自查看。数据库仍为原乐章 18 条消息、9 次运行，没有自动发送。
- 随后由独立“×”取消选中该草稿附件，实际输入区恢复空草稿并禁用发送，原件仍在档案，见 `native-gif-chip-cleared.png`。最终两个包均含许可文本，实际摘要匹配清单、219 个暂存源码摘要无差异。

- 公共场景原件 `a6ab8739956f4ad2b6961842b48b897b` 的 480×320 JPEG 响应为 76,444 字节；ThumbHash 为 `3jgKFYREg6dPd4h8dlemaJ6wtQhb`。现有 TLS/HSR1 参考客户端经真实中继返回相同尺寸、字节数和 hash，状态 200，回执不含不确定执行；请求号 `888c5eeea6034955b0e3e038f349e934`。
- 真实运行 `aafedcb9d27b43cc8767f2eedda16e13` 用工具读回带编号/马赛克照片及说明 PDF 第 2 页，留下 L4 序号 1072 / 1074。模型准确指出编号和遮挡区域，并给出页面标题“二、HTTP 接口目录（Contract v1）”。兼容处理后的真实运行 `c9aa86e56271496698a3073e247597fc` 再次完成第 2 页读取，L4 序号 1095。两者均沿用原有 ACP 会话。
- 同一有效授权对未分享的原件返回 403：“这份原件没有交给当前乐章，暂时不能读取。”没有临时放宽权限。
- 初次迁移遇到 ACP 本地旧策略检查拒绝，在模型请求发起前失败；修正为独立 v3 策略后，在同一会话恢复。保留该诊断，不把工具错误说成模型会话终止。
- 已亲自查看原生聊天图片、图片墙、透明图、100/150% 大图、平移、柔光、嵌套批注后保留 150%、第 2 页凭证和直接打开。过程页打开/关闭前后处于同一滚动位置。主机正常停止后，已缓存的 PDF 第 2 页在新挂载的图片页仍可展开；随后恢复原主机。
- 冷启动 960×2048 / 480dpi（320vp）后实际显示图片墙和完整大图操作。“围绕这张图追问”建立空乐章 `7ae7257f7e374d5ca7ffbec6949108ff` 并显示原图草稿附件；数据库消息数和运行数均为 0，未自动发送。
- 日间 320vp 图片墙的透明图、白色纸页与大图操作已查看。实际滚动图片墙后打开纸页再返回，`native-images-day-wall-scrolled-before.png` / `after.png` 处于同一位置；`native-images-day-viewer.png` 保留可读按钮。
- 点击“保存原件”走到当前桌面 SDK 的真实首块文件写入，返回 0 并明确显示失败；未进入系统保存窗口，没有宣称导出完成。
- 最后的另一轮 Pura 冷启动在配对期间发生桌面 SDK 原生访问异常 `0xc0000005`，本地进程退出 `3221225477`；配对中的冻结帧不作为成功证据。保留 `native-images-pura-final-start.preview.log`，继续诊断同一代码的正常入口。此前成功的窄屏操作和模型/API证据仍有效，但不能据此宣称原生长时间稳定。截图桥已增加子进程存活检查，避免把退出后的最后一帧当作当前界面。
- 同一代码的下一轮正常配对成功，原生进程继续响应。`native-images-process-copy-final.png` 已亲自核对：显示真实照片、中文来源说明和 1244×827 工具返回尺寸，内部事件名已消失。此前异常尚未稳定复现，未宣称修复。
- 主机离线检查并恢复后，真实续聊 `5cc028c10e2a408a9bad8833efbe3a11` 完成，L4 序号 1109 记录实际取图，回复再次准确描述编号和马赛克位置。当前服务认证为真、活跃运行数为 0。最终 Pura 布局的 `native-images-pura-viewer-final.png` / `native-images-pura-followup-final.png` 已亲自查看：新增操作完整，追问返回已有乐章并保留未发送原图，实际模型回复完整显示。

当前图像证据在 `tooling/evidence/native-images-*.png`，原始 JPEG 同名保留。已查看的关键文件：`wall-final`、`zoom-final`、`nested-editor`、`zoom-return`、`pan-final`、`soft-final`、`chat-inline-upper`、`chat-after-viewer`、`process-mid`、`process-return`、`process-pdf2-open`、`pdf2-offline`、`save-preview-limit`、`compact-wall`、`compact-viewer-final`、`compact-ask-unsent`。前缀均为 `native-images-`。

常规和临时预览产品已真实编译 API26，HAP、准确字节数、源码摘要与日志以外层 `releases/*.manifest.json` 为准。未编写新的测试代码或临时测试运行器；本页依据正常 API、实际模型工具调用及原生交互。

仍未验收：实际华为设备上的加载帧率与耗电、真机捏合、生产 RDB 重启恢复、系统文件保存/取消、华为签名与其余原始性能指标。桌面 SDK 的偶发原生异常仍保留诊断。GIF 当前提供静态首帧阅读；完整动图播放、媒体库的视频、代码精华和收藏金句等原始范围仍需继续实现与检查。

依赖与协议的原始资料：[thash 1.2.1](https://pypi.org/project/thash/1.2.1/)、[ThumbHash 算法](https://github.com/evanw/thumbhash)、[MCP 工具及 image 内容](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。
