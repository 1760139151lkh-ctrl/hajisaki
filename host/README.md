# 哈基祥主机网关

Python 3.11+。从项目根目录安装 `host/requirements.txt`，然后使用项目的 `tools/supervisor.py` 启动。服务入口为 `hajisaki.app:app`，`PYTHONPATH` 指向 `host`。独立运行不需要 Codex。

```text
python tools/supervisor.py start --provider development
python tools/supervisor.py status
python tools/supervisor.py stop
```

`development` 是明确标记的固定文字演练，不调用 AI。默认提供者为 `acp`；`agy` 是兼容名称，也统一使用已安装的原生 Antigravity CLI harness，经ACP输入内容。复用CLI已有登录、系统指令、原生工具、设置与默认定制；哈基祥MCP只增加交付能力。没有底层模型API反代，也不因登录或网络失败退回演练。见`../docs/native-harness-contract.md`。

## 配置与配对

| 配置 | 含义 |
| --- | --- |
| `HAJI_DATA_DIR` | 数据目录；直接运行默认 `%LOCALAPPDATA%/HajiSaki`，项目监督器默认 `runtime/` |
| `HAJI_PROVIDER` | 原生CLI接入`acp`，兼容别名`agy`，或显式非AI演练`development` |
| `HAJI_PORT` | 与实际网关监听端口一致，专属 MCP 桥据此连接本次服务；监督器会自动传入 |
| `HAJI_AGY_PATH` | 可选 CLI 可执行文件路径，否则从 PATH 和用户默认安装位置查找 |
| `HAJI_PROXY_URL` | 真实 CLI 必需的本机 HTTP(S) 代理，例如 `http://127.0.0.1:10808`；只作用于子进程 |
| `HAJI_ALLOWED_HOSTS` | 已部署私有通道的额外 Host 名称，逗号分隔；不改变监听地址 |

首次运行生成私有 `pairing.json`，包含高熵 token 与设备标识。浏览器在本机页面明确点“连接这台电脑”后，向 `/api/local-pair` POST `{"consent":true}`。该入口要求实际来源为环回地址、Host 为环回字面地址、Origin 与页面匹配，并通过 Windows TCP 连接的实际客户端进程 PID 和账户 SID 确认与网关属于同一用户；转发头被拒绝。无法证明进程归属时保留手动配对。所有业务 API 都需要 `Authorization: Bearer ...` 和 `X-Haji-Device`。配对口令不能出现在 URL、截图、日志或版本库中。设备标识是软件配对标识，不应描述为硬件认证或生物识别证明。

生产隧道必须禁止代理访问 `/api/local-pair`；不能把外部请求重写成环回 Host/Origin 来调用它。网关默认只监听 `127.0.0.1`。软件不启用定位服务，浏览器地理位置策略为禁止。

## 已落地的主机行为

- SQLite WAL、FTS5 索引、对话/分组/置顶/归档/分叉、记忆与调音设置；消息与增量事件在同一事务中保存，按 `seq` 重播。
- 认证 SSE 连续传送：`/api/conversations/{id}/stream?after=N`，支持 `Last-Event-ID`，提交后通知、每批至多 64 条、15 秒心跳、断开清理。`/messages` 同一读事务返回快照与 `cursor`，客户端仅把大于该游标的增量追加到快照。轮询 `/events` 保留作恢复后备。
- `client_id` 去重；停止立即落盘终态，晚到的回复不能继续追加；重启将遗留执行标为中断并保留文字。
- 分块上传、偏移查询、续传、SHA-256 校验、内容寻址存储、重复内容共享；单文件容量配置上限 16 GiB，单请求块 8 MiB。容量支持不等于已经完成 2GB 弱网实测。
- ZIP 目录核验在分配目录索引前先检查目录边界与 4MiB 上限，再限制文件数、膨胀大小、压缩比、目录深度，拒绝越界路径、符号链接、大小写重叠路径、加密条目；不展开嵌套压缩包、分卷及 ZIP64 总目录，不执行上传内容。原件传输仍支持大文件。
- 文本、源码、日志可分页摘录和文字检索。PDF/Office 通过独立解析进程读取，限制输入 64MB、解析进程 256MiB 和 20 秒；使用 pypdf / defusedxml。扫描 PDF 不做 OCR，不假装理解图片。
- 主机使用公开的 CLI `init/step_update/result` 协议，保存中间人话和工具记录；没有原始思维链的伪造或读取。模型目录只来自实际发现结果或当前默认模型。
- 原生Antigravity harness保留自身系统指令、工具与权限规则；哈基祥读取附件、新建文字/PDF/XLSX/ZIP、进展说明与交付MCP同时提供。App交付协议为必须遵循的工作流，不是可有可无的候选。原生工具生成文件可使用本轮输出目录（通过CLI官方`--add-dir`接入），再挂载到App；`create_*`直接自动挂载。工作区内或本轮用户明确指定文件的原生只读请求可允许一次，其它尚未获准的操作不自动放行；完整高危确认界面尚未实现。
- ACP 实际传送用户附带的图像，按协商的模型/档位运行并保留会话标识；仅精确匹配本项目桥接工具的回调可逐次放行，其余拒绝。公开回复、动作胶囊与成品进入同一持久化流水。详见 `host/acp-notes.md`。
- Pin 锚点、用户实际勾选的待办状态在下一轮注入；文件锚点附带有界摘录，分叉保留对应状态。约定提醒持久化到本地收件箱，支持时区及每日/每周重复；不冒充手机推送。
- 可选本地 ASR 在独立隐藏进程中运行，保留原音、分段转写、字词时间戳、疑词概率和热词词典；缺少依赖或模型时报告不可用，不自动下载或付费。导出包含安全的语音记录与原件。
- 记忆删除把该条记录直接交给回收站后移出活动数据库；不提供永久粉碎。导出 ZIP 包含 JSON、Markdown 和原始附件。

## 附件读取与交付接口

基本接口见项目 `docs/implementation-contract.md`。补充接口：

| 接口 | 用途 |
| --- | --- |
| `GET /api/uploads/{id}` | 查询偏移、长度和已完成原件 |
| `POST /api/uploads/{id}/restart` | 将未完成片段交给回收站，重新开始该上传 |
| `GET /api/artifacts/{id}/inspect` | ZIP 安全目录检查 |
| `GET /api/artifacts/{id}/text?offset=0&limit=8000&page=0` | 文本按 UTF-8 字节读取；PDF/Office 按页和字符 offset 读取；ZIP 分页列目录 |
| `GET /api/artifacts/{id}/search?q=...&offset=0&limit=20` | 文本字面检索，每次扫描至多约 8MB，返回继续偏移；不是正则或全库查询 |
| `GET /api/artifacts/{id}/sheet?sheet=0&offset=0&limit=20` | XLSX工作表窗口；首行表头、从0开始的数据行偏移、每页最多50行/前64列、真实值与有限样式；不计算公式 |
| `GET /api/artifacts/{id}/page-image?page=0&width=2048` | 有界PDF纸页图像与原件摘要、页数/像素尺寸/MIME；保持原始PDF不变，供原生组件显示和缓存 |
| `POST /api/runs/{id}/deliver` | `{path,kind}`，只接收该次运行的专用输出目录内原件；持久化文件卡与 L4 事件 |
| `POST /api/runs/{id}/progress` | `{text}`，持久化公开进展短句 |
| `POST /api/conversations/{id}/update` | 原生 NetworkKit 的 PATCH 等效入口 |
| `POST /api/memories/{id}/update` | 原生记忆更新入口 |
| `POST /api/settings/update` | 原生设置更新入口 |

交付目录为 `HAJI_DATA_DIR/workspaces/<conversation_id>/outputs/<run_id>/`。ACP 通过私有 `HAJI_AGENT_GRANT_FILE` 接入 `hajisaki.bridge`，只传每次运行的短期工具授权，不传 owner 令牌。内部 `/internal/agent/{run_id}/...` 入口另行校验环回来源、授权摘要、期限和运行状态；结束、失败与停笔都会撤销授权。附带的读取工具不能越过当前会话，交付工具不能越过本次输出目录。

`create_text_artifact` 新建并自动挂载 Markdown、CSV、SVG、HTML、源代码等文字原件，每份至多1MiB UTF-8。`deliver_file_to_phone`、`deliver_image_to_phone`、`deliver_interactive_card` 与其 client 别名只交付已有受管输出；`send_progress_note` 写入公开过程。每轮所有类型合计至多64个输出名字，使用排他创建，不覆盖原件；失败保留诊断与已占用名字。

三种二进制成品工具接收结构化数据，交给项目自身的可信导出进程：

| 工具 | 成品与边界 |
| --- | --- |
| `create_pdf_artifact` | A4中文文字报告，嵌入主机中文字体；段落/标题/列表/代码/最多12列表格，重复表头与自然分页，最多100页。当前不嵌图或绘制LaTeX；缺字形会明确失败，不静默丢字 |
| `create_spreadsheet_artifact` | 真正XLSX，1–12张表、每表最多32列/1000行资料，合计10000格；表头、换行、列宽、筛选与冻结首行首列。文本按字面保存，不执行公式或宏；过高单元格要求拆行 |
| `create_zip_artifact` | 从当前会话已分享/钉选的真实原件中选1–64份，合计最多64MiB；核对字节数/SHA256，同名原件置于不同编号目录。不嵌套其他压缩包或读取任意路径 |

每份结构化输入最多1MiB UTF-8，导出进程最多2个并行、384MiB内存、45秒，生成文件最多80MiB；等待和生成中持续检查运行授权。停笔后只终止所拥有的导出进程，原有资料与私有诊断保留。XLSX工作表XML写入内存，不创建再删除临时工作表。导出依赖由项目`requirements.lock.txt`提供；PDF还要求本机可嵌入中文字体。`/api/status`分别报告`pdf_export`、`xlsx_export`、`zip_export`是否可用。

Studio可翻阅PDF、按20行切页/切表阅读XLSX、固定表头首列，以及显示ZIP目录。原生新增ArkUI纸页、工作簿和归档目录阅读，按不可变摘要缓存已打开的页与阅读位置；具体合同及当前实际观察见`phone/docs/native-document-readers.md`。PDF纸页处理依赖项目本地PDFium，不依赖Codex，也不表示设备端PDF Kit或大文档解析已完成。保存仍走独立设备鉴权的原件通道；原生系统文件导出和生产RDB重启耐久性仍需对应设备检查。位图生成、普通CLI工具桥和高风险批准仍待实现；不得用全局MCP放行替代精确匹配。

## 尚待集成与验收

原生图片墙与聊天缩略图使用认证的 `/api/artifacts/{id}/thumbnail`，主机通过固定 `thash==1.2.1` 纯 Python 实现返回真实 ThumbHash 和小 PNG 占位。新 MCP `read_attachment_image` 能实际返回本会话图片或指定 PDF 页，并记录精确来源/页号的 L4；它不把文字摘录或附带图片说成已完整审阅。新旧工具目录按私有授权版本区分，保护既有独立主机。容量、协议与实际记录见 `phone/docs/native-images.md`。

主机安全基线不等于已经完成实机生物识别审批、任意磁盘代码编辑、快照回滚、原生双通道隧道、Live View、手机推送、原音模型理解、说话人区分、自动 OCR、向量长期记忆或每日加密归档。当前未配置这些能力时，状态接口返回不可用，不能宣称成功。实际订阅登录、模型连通和代理出口以成功运行的真实证据为准；代理端口可连接也不等于出口路径已经抓包验证。

全量长历史返回和导出仍可能随资料规模增大而占用更多资源。60 轮上下文重建只是有界近期记录及显式记忆注入，尚不是完整的向量检索或自动长期摘要。7×24 稳定性、2GB 丢包续传、50ms 停止、原生帧率和温控均保留待测。
