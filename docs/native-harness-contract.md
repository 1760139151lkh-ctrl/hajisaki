# 哈基祥与 Antigravity 的原生运行边界

手机与iPad共用此合同：App是Antigravity CLI的输入、显示和文件交付客户端。模型的系统指令、原生工具、工具选择、执行循环、会话与上下文管理仍由原生CLI负责；不得抽取底层模型后用自建agent替代，不得改为模型HTTP接口反代或OpenAI兼容服务。

生产调用为本机Google签名的`agy.exe acp --stdio`，通过ACP提交普通用户内容、图片及补充上下文，继续同一provider session。由CLI直接加载常规`~/.gemini/antigravity-cli/settings.json`，保留默认customizations和原生工具目录；不替换agent或modelProvider。权限采用下述用户明确开启的Turbo配置。已有会话的原生trajectory存储根`hajisaki-acp`保留，防止换存储后找不到旧会话；不再选择旧gateway-tools限制profile。若普通设置要求额外credits或替换模型provider，则明确拒绝，不自动改为别的模型接口。`agy`旧配置名也统一进入此路径，不保留另一套裁剪后的执行分支；`development`只用于显式非AI演练，不能作失败后备。

哈基祥MCP服务器是附加的文件接收/交付能力，不是原生工具的替代目录。原生工具调用作为真实ACP事件转发；不得因为它不是哈基祥MCP而取消整轮。原生系统提示词不由App重建或伪造；人物语气、记忆与文件指引只以普通用户附加上下文提供，并明确不替代原生系统规则。

App交付协议必须生效，不是仅列为候选：人物语气、长期记忆、上下文锚点、附件读取和交付工具继续随每轮接入。生成成品必须回到App附件/卡片入口，不能只给主机路径。原生工具可在本轮真实受管输出目录中生成文件；该目录由CLI官方`--add-dir`参数加入工作区，再通过App交付工具挂载。`create_*`仍自动生成并挂载，不重复交付。原生执行能力与App集成能力同时保留。

权限不等于工具目录。用户于2026-11-16明确开启Turbo、全部操作默认许可。项目runtime/host-settings.json的turbo:true令原生ACP启动带官方支持的--dangerously-skip-permissions。对活动会话仍发出的权限请求，客户端自动选择许可项，保留会话归属和取消状态校验；日志标明user_enabled_turbo。关闭Turbo时恢复已有只读/交付许可规则，其余单项返回取消而不取消整轮。未实现的客户端委托终端/文件接口不伪造支持；原生工具自己执行操作。定位、永久删除等用户已有明确约束仍保留。

Windows网关、客户端私有隧道和主机联网代理属于传输：它们不终结模型协议、不抓取或重写Antigravity底层模型请求、不替换原生harness。主机已有HTTP代理只是CLI联网出口。

验收须同时检查两个实际服务（手机8765、iPad8767）的provider状态、CLI签名、真实进程参数及原生工具事件；仅凭模型自称、配置文件或成功的一句回复不能代替证据。已有健康任务需等待结束后再更新进程，不能通过中断任务制造恢复或重新开会话。

原生接入方式依据[Google Antigravity ACP说明](https://antigravity.google/docs/ide/extensions/acp)：客户端发送prompt并呈现回复/工具调用/权限请求，agent、tools和settings由Antigravity CLI提供。
