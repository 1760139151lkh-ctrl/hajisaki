# 祥子人物与执行模式

本轮人物研究和润色实际由 **Gemini 4 Hydrogen / XHigh** 完成，使用已登录的 Antigravity CLI。运行时 `init` 记录确认模型为 `gemini-4-hydrogen-xhigh`，会话为 `44e4b331-a5c8-4eff-a4ac-b0cdf1967be8`。用户指定氢模型后，在同一会话切换并保留此前检索资料，没有新建替代会话。

[Gemini 原始公开改稿](gemini-hydrogen.md) 覆盖人物资料、运行核心、背景、工具后语气、源码改写和自然对话示例；[咨询元数据](consultation.json) 记录实际模型与整合调整。[资料底稿与独立复核](research.md) 区分官方事实、剧情解读、应用自设及未确认信息。

| 文件 | 当前作用 |
| --- | --- |
| `shared/persona/sakiko.md` | 每轮读取的人物核心；经历、自尊、责任感、少女感、亲近方式、语调和三轴调律。 |
| `shared/persona/reply-voice.md` | 技术协议与附件资料之后的语气收束，工具返回后仍以自然角色声音回应。 |
| `shared/persona/background.md` | 维护及特定话题参考，不每轮全文注入。 |
| `host/hajisaki/persona.py` | 所有客户端共用的人物载入入口，运行核心可即时更新；设置里“她怎么称呼你”（`nickname`，最多 24 字）以引号内名字的形式附在调律之后，只用于亲近时的称呼。每轮另附一行“此刻”资料：主机本地时间与时段、相识第几天（从第一封信算起）、距上一封信几天，以及元旦、2月14日（她的生日）、5月20日、平安夜、圣诞、除夕；标明只是资料，自然时再提。 |
| `host/hajisaki/composer.py` | 五种语气的提示已采用 Gemini 改稿；用户提问模板和交接摘要保留用途。 |
| `host/hajisaki/bridge.py` | 十五个交付/读取工具的描述改为准确中文；名称、参数和实际格式限制保留。 |
| `host/hajisaki/provider.py` | 人物核心、资料与出口声音分层；失败文案及进度语气一并整合。 |

整合时修正了原稿中 Our Notes 的失效人物链接，独立找到并核对[正确的官方档案](https://bang-dream-on.bushimo.jp/character/avemujica/togawa-sakiko/)；没有把未经明确证实的精确年龄或咖啡厌恶写入运行核心。对亲近的回应保留自然温度，不把温柔限定成极罕见的奖励。角色表演、真实记忆和实际执行结果保持区别。

用户于 2026-11-16 明确要求开启 **Turbo、默认许可全部操作**。当前项目在 `runtime/host-settings.json` 保存 `turbo:true`，每次原生 ACP 调用带上 `--dangerously-skip-permissions`；若服务器仍提出本次会话的操作许可，客户端自动选许可项。原生实际文件写入和客户端交付已经执行成功，无重复确认。真实系统身份验证及账户能力仍按其实际状态运行。

主机默认模型已设为 **Gemini 4 Hydrogen (XHigh)**。“主机当前配置”同时继承模型与强度；旧客户端仍发送 `medium` 时不会把主机最高档降回中档。具体模型的档位校验保留。运行记录已确认请求 `default` 时，实际选中 `gemini-4-hydrogen` 与 `thought_level:xhigh`。

调用证据与原始 CLI 流保存在受保护的 `runtime/persona-consultation/`；手机上传修复的安装包、大小和散列见 `phone/android/verification.md`。
