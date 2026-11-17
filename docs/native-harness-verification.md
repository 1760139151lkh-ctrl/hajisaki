# 原生 harness 与 App 能力共存核验 · 2026-11-16

用户要求：手机和平板都保留Antigravity原生harness、系统指令与工具；同时保留App的人设、记忆、上下文、附件、文件交付及卡片协议，不能将App功能降为可有可无的建议。边界见`native-harness-contract.md`。

## 实际运行与修改

本机`agy.exe`的Authenticode状态Valid，签发主体Google LLC，文件231,726,744字节，SHA256 `8803c289cac04d6e53f2211592d9981c2d5760bc0d9b4a7f222ef6ecc7abb38a`。实际手机/平板进程均由各自Windows后台网关直接启动，命令使用原生`acp --stdio`、普通CLI设置文件、`--include-default-customizations=true`及本轮输出目录`--add-dir`。没有替换agent/modelProvider、没有使用模型HTTP兼容反代，也不再加载旧gateway-tools原生工具封锁profile。原生trajectory存储根保留，原有provider session ID继续使用。

哈基祥MCP继续按客户端能力挂载，生成工具仍自动挂载原件。每轮提示保留人设、调音、记忆、Pin、待办、上下文与附件摘录，并明确文件回传是必须遵循的App协议。原生工具可使用真实受管输出目录再交付，不能只报电脑路径。

## 同一轮的真实调用

| 链路 | 实际run | 调用与结果 |
| --- | --- | --- |
| 手机8765 | `71efdaddae22432281e8d8677c8e0bec` | 原生`read_file`完成；`mcp_hajisaki_send_progress_note`成功；`mcp_hajisaki_create_text_artifact`成功；最终completed |
| 平板8767 | `02062f32a17a4af281a5495671c1f229` | 原生`read_file`完成；`mcp_hajisaki_send_progress_note`成功；`mcp_hajisaki_create_text_artifact`成功；最终completed |

两端均实际读出本文相关合同首行`# 哈基祥与 Antigravity 的原生运行边界`。权限回调记录明确区分`authorized_native_read`和`app_delivery_tool`，均仅选择allow_once；不是由模型自称有能力替代工具证据。

手机实际挂载`app-harness-handoff.md`，artifact `c2f4bbcd2a0b4c9d851ffec2a385b967`，1072字节，SHA256 `c4c32ba294e7c1960582f648a37117364b5f85cf6c1313db2d5bc7a19723d5ef`。

平板实际挂载同名文件，artifact `3c02ea2e8c1e459bab3cc9036f873cc0`，827字节，SHA256 `b3684a2659f67db763719f2eb2bc09cbc0bcc04cc0fb20043c1042d1004befd4`。

两份原件均通过相应网关的正常认证下载入口取回，字节数与SHA和附件元数据一致，回复包含可用的hajisaki原件链接。原生工具与App工具在同一真实模型轮次中协同，而非二选一。

## 失败、修正与边界

最初只切换默认会话存储时，ACP元数据协商成功，但实际提交报旧trajectory不存在。已恢复原生已有存储根，未创建替代会话。早先原生只读请求因无确认UI被拒绝，随后针对工作区或当前用户明确指定文件的只读操作增加allow_once处理，两端实际执行完成；其它未获授权操作不会自动全放行。失败消息、原始回执均保留。

正常CLI设置文件内容未被修改。原生私有系统词不可由本客户端逐字读取；证明来自Google签名程序、实际启动参数、官方ACP接入方式、原生工具事件及App产物，不声称已穷举每一种原生工具或完成全部审批UI。原生源引用可能仍含主机file://链接，本轮实际交付原件已通过hajisaki链接可下载；完整跨端源引用映射另列原宪章待办。

使用编译语法检查、已有ACP诊断命令、真实业务API、实际模型与原件下载核验；没有新建单元/功能/E2E测试、测试夹具或测试运行器。本轮未清理文件，证据保留在`runtime/native-harness-*`。

此记录仅证明本次原生harness与App集成共存，不代表完整产品宪章或当前build7设备包已全部交付。
