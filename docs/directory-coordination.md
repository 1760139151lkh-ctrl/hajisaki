# 手机 / 平板目录协调

收到平板任务通过已授权协调消息传来的目录安排。现有原生构建、预览器和模型会话继续保留；不因目录整理中断健康会话。

- `ipad/` 与 `docs/ipad/` 由平板任务独占；手机任务不修改它们，不操作 MacUS 虚拟机。
- 共享层维持外层：`host/`、`relay/`、`speech/`、`shared/`、`assets_pipeline/`、`studio/`、`tooling/`、`tools/`、`runtime/`。
- **手机源码已迁移至 `phone/harmony/`**。移动前核对了源/目标绝对路径均在项目内，协调了所有源文件写者；没有复制出第二套竞争源码。`build.py`、资源同步与发行打包脚本已改为解析外层共享目录，根 README/忽略规则/API 目录合同已同步更新。原生代理正在通过现有构建入口复查迁移后的实际产物。
- 手机专属文档会归入 `phone/docs/`；共享 API 合同、通用部署/安全依据留在 `docs/`。原始宪章不改写以掩盖范围。
- Windows ASCII 构建暂存 `C:/Users/17601/HajiSakiNativeBuild/` 保留为真实工具链需要的构建位置，迁移不覆盖或删除现有会话数据。

共享后端设备注册表已接入并完成本机接口验收：`host/hajisaki/devices.py` 提供独立令牌、角色及吊销，原 bootstrap 保持兼容；已打开 SSE 也检查吊销状态。合同见 `docs/implementation-contract.md`，平板任务无需另建竞争的注册表。现有 mTLS relay 仍有单 channel / phone role 限制。**本机接口验收不等于两设备外网并发验收**，也不能把复制同一个 bootstrap 令牌当作多设备配对。

共享美术以用户后续的“不要成年化、参考在场原图”为准：`shared/assets/avatars-youth/`、`reference-youth/` 和 `scenes-user/` 是当前人物来源；`shared/assets/avatars/`、旧 `reference/` 为被排除的成熟化候选，不能重新用于客户端。选用清单为 `assets_pipeline/native-resources.json`。原始 PCM 音效在 `shared/assets/audio/`，默认关闭且未宣称已听感/实机声触验收。

本文件供双方读取协调。手机任务不会在未获单独授权时向其他用户聊天发送消息。共享主机仍在持续开发，平板任务应以实际 API 合同与鉴权行为为准；新增设备应由 owner 通过注册接口取得单独凭据，再保存进该设备的受保护存储。

## 当前共享接口状态

- 设备注册已加载至本机 8765 development 实例：`POST /api/devices` 接受 `{name, role:"companion"}`，只有 owner 凭据可登记；响应仅在创建时给出该设备的独立令牌。设备列表、单设备撤销、错误 token/device 组合、现有 SSE 撤销，以及中继缓存重放撤销均已用两个任务专用 companion 凭据实际核对。两枚演练凭据随后均已撤销；现有 owner/native 凭据未撤销。8767 的设备注册代码也已重载，但这组双设备验证是在 8765 完成。软件凭据不等于硬件指纹或实机多端验收。
- `task_items()` 已加入可选 `source_start_line`、`source_end_line`：直接来自 MarkdownIt 的有效 inline `token.map`，0 起始、end 不含；无有效映射时不返回。原 `index/text/initial_checked` 保持不变。**8765 已重载并实际读回**：现有消息 `613285e3490a455aa6c15fd1ee129cbb` 两项分别映射至 `[4,5)`、`[5,6)`。平板 root 随后核实 8767 `active_runs=0`，通过既有监督器重载同一 runtime/live 数据目录与 acp/10808 配置；实际消息 `8ab21487d6ba4cb1bf301320cd825914` 三项已返回 `[10,11)`、`[11,12)`、`[12,13)`，证据在 `ipad/evidence/live-checklist-contract.json`。没有中断进行中的模型任务。

平板模拟器已登记独立 companion 凭据，私密文件位于 `runtime/ipad-live-pairing.json`，客户端保存于 Keychain。真实模型已完成两轮中文回复；当前模拟器使用本机 SSH 转发开发通道，这不代表外网 Tailscale/mTLS 已验收。

## 手机根代理本轮收尾

8765当前为ACP真实模型主服务，未切回development。手机根代理经正常Studio配对和聊天完成新运行，三项待办的勾选状态在刷新后保留；原生表单也连接到同一主机。语音从真实档案音频→主机ASR→原生草稿已实际走通，未自动发送。当前构建包及原生/浏览器复核见 `docs/acceptance-ledger.md` 和 `releases/`。

手机根代理仅修改 `studio/` 的主机状态文案及阅读弹窗输入样式、手机原生语音手稿、共享文档与 `tools/supervisor.py` 的UTF-8输出；保留平板续做对该启动器按所选data-dir读取provider/proxy的修复。不操作MacUS，不改 `ipad/`，未接管8767。收到的附件定位引用约定协调消息已阅读，本轮未改 `provider.py` 的prompt段。

后续根代理已把现成`AgentTools`接入共享主机：ACP专属运行授权MCP现可读取当前会话附件、创建受管文字成品并投递；每轮独立授权，结束/停笔撤销，任意命令/磁盘/其他工具仍拒绝。`Config.port`跟随`HAJI_PORT`，因此未来8767正常重载时桥会连接8767而不是8765。新工具路由、额外SQLite表与状态能力保持向后兼容；旧运行实例不会被此源改动自动重载。

`provider.prompt`保留了平板的`artifact-links-v1`能力头门控与笔迹来源约束；手机根代理未改`ink_metadata.py`或其PNG解析分支。共享默认ACP配置使用独立`gateway-tools`目录，原全拒绝`gateway`目录保留。真实四种文字产物/HTML交互及原生翻阅的范围见验收台账，不能把它描述为任意主机工程执行或全格式生成。
