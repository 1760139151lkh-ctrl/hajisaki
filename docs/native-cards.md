# 原生卡片协议 v1

原件采用UTF-8 JSON，文件名以`.hajicard.json`结束，最多128KiB；结构见`shared/native-card.schema.json`。卡片和普通文件一样保存在CAS仓库，附在实际助手消息上，可下载原件。客户端声明`X-Haji-Features: artifact-links-v1,native-cards-v1`后，本轮模型获得profile4的`create_interactive_card(name,card)`工具；未声明的既有客户端保留旧工具目录。

这里的profile版本只决定哈基祥附加MCP工具，不覆盖或裁剪Antigravity原生harness、系统词、工具与执行循环；当前共享主机边界以`docs/native-harness-contract.md`为准。

`version=1`，`kind`为`flashcards`或`poll`，标题为1–160字符。

- 闪卡：`cards`包含1–20组`front`/`back`，每面1–2000字符，可用Markdown与LaTeX。`question`与`options`为空。
- 决策卡：非空`question`可用Markdown，`options`为2–12个不同的纯文字选项，每项最多300字符，`cards`为空。

宿主按Pydantic额外字段拒绝、严格类型及类型关系验证；通用文字工具对保留文件名也执行相同验证，不能绕过。卡片不是可执行脚本，既有HTML交互微剧场协议继续独立存在。

## 已配对客户端接口

`GET /api/conversations/{conversation_id}/cards/{artifact_id}`返回原件定义、当前设备的`selected_option`（从0开始或null）及按选项顺序的`counts`。需正常Bearer与`X-Haji-Device`认证，且原件必须实际附在该乐章或其显式分支原件集合中；仅知道全局artifact_id不能跨乐章读取。

`POST /api/conversations/{conversation_id}/cards/{artifact_id}/vote`接收`{"option_index":0}`。设备身份由已认证请求决定，不能在body指定。每个乐章、原件、设备只保留一个当前选择；重复请求不会加票，改选原子替换原选择。事务中重新计算结果，返回同一快照结构。`card_updated`持久事件只广播原件ID，不暴露设备选择。客户端收到事件后以自身身份重新读取。

投票记录在`card_votes`，随正常全库JSON归档导出。分支同一原件的投票按乐章分别保存。中继仅增加上述两个精确路由，内部MCP创建入口不对远端开放。

## iPad呈现与本地状态

卡片直接显示在消息附件位置，原件入口保留。当前闪卡序号及已翻面的索引集合保存在当前主机/设备资料库的SQLite对象中；可离线翻阅，在切换乐章、旋转及应用重开后恢复。两面复用现有原生文字/离线公式管线。投票显示主机确认的选择和票数，断网时保留结果、暂停投票操作。

同一资料库/乐章的读取和投票按既有上下文队列串行，避免旧GET覆盖新投票；异步结果只更新它所属的资料库与乐章。卡片布局变化通知现有原生对话列表重新测量，不新建第二套聊天滚动区域。
