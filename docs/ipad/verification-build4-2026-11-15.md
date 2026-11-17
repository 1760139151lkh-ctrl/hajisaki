# iPad 0.1.0（4）· 姿态伴随与长回复布局

本轮继续完整宪章，根代理独立实现、直接检查集成结果，没有创建或续派子代理。本文记录本轮实际观察；完整120项仍在`acceptance-ledger.md`，尚未全部完成。

## 当前构建

设备安装输入为`ipad/outputs/install-build4/HajiSaki-iPad-0.1.0-build4-73247e91-unsigned.ipa`，87,791,285字节，SHA256 `73247e91234dd0980d6a5f3a0c572c530baef0e43827a898d0843e632ae05e41`。arm64/iPhoneOS、iPad设备族2、最低18.0、版本0.1.0（4），仍需正常Apple设备签名；没有实际设备安装结论。安装说明和摘要在同目录README与`install-packet.json`，build2/build3保留。

已运行的最终模拟器源快照为`08890b75f0f5b8b5230fbc9779fd29a8198b04fd35b3d8c1ef572f919a05a272`，设备包源快照为`1eea8e4cf669f8abc1680e7aed277bd2aeba7beb298a8bdeb1d7b4159b79fca0`。141份App/资产文件摘要一致，当前工作区这些文件也一致；完整源树摘要因证据/说明文件不同而不同。Xcode26.3正常编译、模拟器ad-hoc签名和设备构建均完成。`outputs/device-build4-final/root-verification.json`记录包结构、架构、摘要及两项当前配对令牌扫描均未命中；没有位置权限声明。此扫描不等于对所有潜在秘密的证明。旧`outputs/device-build4/`中的dc93中间IPA已撤回并直接回收。

模拟器为iPad Air 11-inch M3、iOS26.2、x86_64，UUID `37A96691-E6C9-4BD6-BAE8-715D00DC3794`；签名回执`ipad/evidence/build4-signed-simulator.json`。不是iPad硬件、Pencil Pro或功耗验收。

## 新姿态与实际动画

使用内置`image_gen`，依据在场昼夜母图生成昼夜各thinking/reading/watching/tea完整坐姿，共8张人物层及8张对应闭眼源。原图1536×1024 RGBA，逐字节入库，没有Python重绘、抠图或独立拉伸五官。完整提示词、源文件名、SHA、Alpha检查和逐图审阅范围均在`ipad/assets/living-stage/poses/manifest.json`。

| 姿态 | 实际原生闭眼画面 | 检查范围 |
| --- | --- | --- |
| 夜间thinking | `build4-night-thinking-closed.png`，录像帧576 | 完整坐姿/眼区；该早期截图中的主聊空白另行诊断修复，不当作聊天通过证据 |
| 日间thinking | `build4-day-thinking-closed.png`，帧489 | 完整坐姿/眼区；候选整帧+32px登记后闭眼对齐 |
| 夜间reading | `build4-reading-frame-47.png`，帧47 | 完整坐姿/眼区 |
| 日间reading | `build4-day-reading-closed.png`，帧63 | 完整坐姿/眼区 |
| 夜间tea | `build4-tea-frame-67.png`，帧67 | 完整坐姿/眼区；另看29/595帧的茶雾升起/淡出 |
| 日间tea | `build4-day-tea-closed.png`，帧728 | 完整坐姿/眼区及独立底栏 |
| 日间watching | `build4-day-watching-closed-fixed.png`，帧240 | 工作台顶栏近景，挂载门控修复后自然眨眼 |
| 夜间watching | `build4-night-watching-closed.png`，帧301 | 工作台顶栏近景；主题已通过保存设置实际恢复夜间 |

以上文件均在`ipad/evidence/`，原视频保留。watching的原生运动检查范围是顶栏近景，不冒称两张完整观看姿态的全身动态都检查过。夜间watching闭眼v1的Alpha背景最小值36，已移动到`evidence/rejected-stage-assets/`保留，未选用；v2的Alpha范围0…254。

`StageArtwork.swift`在后台有界工作集中合成人物、原场景及承接物，眼区使用对应闭眼源。PNG未带ICC，作为sRGB输入转换到Display P3合成，不能称生成源文件已经是P3。`LivingStageView.swift`负责自然随机眨眼、近景和仅茶姿态出现的三缕程序茶雾；没有把Core Image合成当成完整Metal活体引擎。

实际入口包括：输入读谱、真实模型运行托腮、工作台顶栏看向页面、手动茶盏。23:30–05:00的本地时钟自动茶盏分支已实现，尚未在该真实时段观察。Pencil笔尖坐标跟随、停笔两分钟主动询问、陀螺仪视差、完整呼吸/发梢/雨丝和12种全身情绪仍待完成。

原先顶栏近景已有图层/闭眼源、motion=true，却因遍历SwiftUI宿主祖先而误判不可见。已改为窗口挂载、实际面板呈现、场景活跃和节能条件共同控制，dismantle时停止并取消任务；昼夜近景均在实际录像中看到闭眼。私有DEBUG状态日志已从Swift源码移除。

系统Reduce Motion通过设置实际开启，24秒原生录制`build4-day-reduced-motion.mp4`中无正常闭眼/茶雾；`build4-reduced-motion-max-frame.png`已查看。之后实际恢复OFF，证据`build4-reduce-motion-actually-restored.png`。低电量/热控与真实功耗未据此通过。原片保留，VFR文件时长、墙钟录制时间与帧数分别记录，不拿模拟器视频帧率冒充真机60FPS。

## 对话与布局修复

1351字符回复曾完整落盘但主聊全空白；仅换ScrollPosition、锚点或摊平LazyVStack后，短回复完成仍再次复现。LLDB确认滚动处于底部，却没有消息子视图；完整数据没有丢失。不同阶段还观察到高度估算371557点、28pt横向偏移、菜单打开后重复行，以及空活动行的44pt留白。原始记录保留，不能拿中间候选的末尾截图当作最终通过。

最终由`ConversationLayout`后台复用语义解析，`ConversationList.swift`用UITableView统一复用平面语义行；每个cell独立Observable内容模型，同ID不重建hosting配置。普通文字/代码仍走原生面，公式走已有离线WebKit；空活动和完成状态行不呈现。拖动解除跟随，可见行ID和相对位置组成读锁；触摸、减速和布局阶段不误记用户位置，必要时先取回锚点行。44pt“回到最新”属于原生列表，避免跨UIKit/SwiftUI覆盖控件不可见；水平位置约束为0。

| 受影响流程 | 实际观察与证据 |
| --- | --- |
| 新发送与回复完成 | 完整落盘的`Good night.`通过UI发送；等待状态、40字符真实回复均可见，返回后仍可读。`build4-native-final-send.png`、`build4-native-final-reply-visible.png` |
| 长回复生成中阅读锁 | 最终构建发出211字符学习请求，开始生成时上翻到旧消息；从0到4699字符完成，旧消息位置保持，未强拉底部。`build4-final-long-reading-start.png`与`build4-final-long-reading-held.png`；真实运行`18e7c49c90c248c59affdb290fe6a5f6`，助手消息`df123a290ee04a42b167f3f8aeaefd9e` |
| 返回长回复末尾 | 点击原生返回按钮，4699字符回复末尾及数学内容正常显示。`build4-final-long-returned.png`。不是500条/15000字或所有窗口逐字符锚定保证 |
| 工作台与横竖屏 | 32%陪伴切38%草稿台、转竖屏时读锁/返回控件仍在，返回最新再回横屏能见末尾。`build4-native-table-portrait-lock.png`、`build4-native-table-returned-landscape.png` |
| 菜单与文字选择 | 修复单元格状态后，消息菜单不再让其它行重复；“选择整条文字”可进入原生页，长按出现选择柄和系统Copy/Look Up/Translate菜单。`build4-native-table-model-actions.png`、`build4-native-table-selection-actual.png`。没有点复制或执行查词/翻译；不声称跨TextKit/WebKit任意连续选择已完成 |
| 数学待办 | 三项真实清单分别查看，公式不再露LaTeX源码；最终构建第三项UI勾选后主机与本机SQLite均为true，再UI取消为全false。`build4-anchor-guard-checked.png`、`build4-native-checked-and-input.json`、最终数据回执。较早b57构建还实际观察了重开后勾选保留，`build4-checklist-reopened-checked.png` |
| 昼夜颜色 | 最终构建保存日间设置，原生消息/输入框/工作台近景颜色正确，再通过保存设置恢复夜间。`build4-final-day-native-table.png`、`build4-final-night-restored.png`；声音/环境音保持关闭 |

`sin(bx)`曾被系统自动更正成`sin(by)`，composer已关闭自动更正/自动大写，同一输入从SQLite读回保持bx，`build4-typed-formula-native.json`。名录预览去除公式定界符与`###`标题标记，保护代码run；原消息不变。侧幕标题/两枚44pt操作移到照片下方独立底栏，日间对比与下缘点击均实际查看。

一次25ms快速虚拟键入尚未全部处理便点发送，仅259字符进入请求，防丢稿revision保护保留后续完整草稿；该重复草稿已通过UI清空，没有放宽保护条件。之后先SQLite确认完整41字符短句，再发送并清稿；最终211字符长请求也先完整读回后发送。VNC键入工具15秒超时属于局部工具时限，原生完整输入已读回，没有重复键入或替换会话。

## 数据与交互记录

滚动诊断没有改写原消息或清理数据。最终36条原生/主机消息的ID、状态、长度和正文SHA全部一致，游标780、无活动run，草稿及附件为空，清单三项全false。读回为`ipad/evidence/build4-native-data.json`与`build4-host-data.json`。缓存PDF8,517,356字节，SHA `9fb106645f7d952aaaabdefdc3cc3fefd63898ed95c0c0d0d413a057dfac6264`；HTML19,233字节，SHA `ba441d4aac510494e00afcd8739900a1003a533d6d260e85103b5d75e4ba0522`，均保持一致。

最终构建从文件柜打开真实`sine-wave-workbench.html`，右栏出现交互演示和近景伴随，主聊仍显示最新回复；点击微调后a=1.10、b=1、c=0，最高1.10/最低−1.10、周期2π，在昼夜设置往返后保留。最终全尺寸图为`build4-native-workbench.png`，原始方向截图同时保留。较早竖屏拖动a=2.40并回横屏的记录也保留，二者是不同会话时刻的参数，不混作一次最终状态。

最终琴房预览`build4-native-piano-room.png`取自原生录像10秒帧。`build4-native-piano-room.mp4`为正确方向的无重新编码副本，原片`build4-native-piano-room-raw.mp4`保留。24秒墙钟录制，文件23.468021秒、969帧；编码1640×2360并带−90°方向，实际查看为2360×1640。已抽看3/10/20秒，方向与最终底栏正确，茶雾在不同时刻变化；8组闭眼证据见上表。VFR文件信息不作为真机60FPS结论。录像时会话有34条，之后仅增加最后一轮真实学习问答到36条，App编入文件未变。

最后一轮完成后再次手动捧茶，36条会话的原生全尺寸图为`build4-native-piano-room-current.png`，原始方向文件`build4-native-piano-room-current-raw.png`保留；最终实际渲染已查看。

本轮通过正常UI、真实ACP回复、现有API/SQLite、既有Xcode构建、只读LLDB和最小视频/图像分析检查。没有新增测试套件、夹具、断言案例或功能测试运行器。没有开启或授予位置权限，没有接管宿主前台/输入/剪贴板，没有重建健康VM或聊天。

## 清理与未完成范围

已直接送入回收站，未备份、试验恢复性或永久删除；以下为逻辑文件大小，不等于释放的磁盘空间：

| 临时文件 | 大小 |
| --- | ---: |
| `ipad/evidence/build4-reading-eyes.gray` | 4.16 MB |
| `runtime/build4-tea-eyes.gray` | 24.26 MB |
| `runtime/build4-tea-steam.gray` | 22.98 MB |
| `ipad/evidence/build4-night-tea-upright.mp4`（方向写入无效的临时副本） | 19.27 MB |
| `runtime/build4-day-thinking-eyes.gray` | 18.21 MB |
| `runtime/build4-day-tea-eyes.gray` | 26.42 MB |
| `runtime/build4-day-watching-eyes.gray` | 3.57 MB |
| `runtime/build4-day-watching-fixed.gray` | 16.30 MB |
| `runtime/build4-night-watching.gray` | 16.66 MB |
| `runtime/build4-night-thinking.gray` | 20.22 MB |
| `runtime/build4-reduced-motion-eyes.gray` | 7.14 MB |
| `runtime/guest-secret-input.py`（不含密码值的瞬时输入helper） | 0.56 KB |
| `runtime/guest-secret-input.py`（再次按原授权解锁时生成的新helper，无密码值） | 0.52 KB |
| `runtime/inspect-native-list-pointer.sh`（旧进程专用只读诊断） | 1.19 KB |
| `ipad/work/inspect-native-list.sh`（一次性只读诊断，命令已留日志） | 1.00 KB |
| `ipad/outputs/device-build4/Application-unsigned.ipa`（已撤回中间候选） | 87.79 MB |

回执为`runtime/build4-cache-cleanup.json`、`runtime/build4-final-cache-cleanup.json`及`runtime/build4-final-delivery-cleanup.json`。保留全部选用源图、原视频、逐帧证据、提示词、SDK、源码快照、原件、笔迹和诊断日志。旧`build4-night-tea-upright-v2.mp4`展示早期覆盖式底栏；最终底栏以本轮`build4-native-piano-room.mp4`为准。

完整目标仍active。除真实设备签名/Pencil/功耗、广域网双通道和7天运行等外，尚有完整情绪/Metal动效、Pencil Pro与系统扩展、外屏、完整互动卡/媒体/笔迹归档、剪贴板/时光机等可继续实现的工作，未把剩余范围缩减为仅缺硬件。
