# iPad 0.1.0（5）· 全局圈画与怀表指令环

本轮build5安装输入已备妥，完整120项宪章继续推进；本轮没有创建子代理或新聊天。

## 当前构建

设备安装输入`ipad/outputs/install-build5/HajiSaki-iPad-0.1.0-build5-84b18cf5-unsigned.ipa`：87,925,315字节，SHA256 `84b18cf555a844242467f54af7e7d3da1cdafc7081144579d9ebc82bf84bb6e9`。iPhoneOS/arm64、iPad设备族2、最低18.0、版本0.1.0（5），未签名，仍需正常Apple设备签名。ZIP、Info.plist、Mach-O架构和两项当前配对令牌扫描已直接检查，无位置权限声明；扫描范围不等于对所有潜在秘密的证明。build4包保留。

设备源`e5f7af10c2522a23f13d2af8787f6439ab0f83c25c772cf3fcde783a32289884`、最终签名模拟器源`94b0ad8aeea3cd3bd4ccbbf7321e7980b6faf20e511f283fccca669bb1a95e4d`。143份App/资产文件的摘要在两个快照及当前工作区一致。该模拟器已在独立新Mac通过正常Xcode ad-hoc签名运行，回执`build5-signed-simulator.json`，可执行文件SHA `50a57197f05cd028a7d8b8905a687116a68bb16045fe6543041fc33850f0d223`。

最终补验已完成：新颜色元数据导出/主机识别、最终回复结尾、日间环与圈画、同资料库的跨会话手稿隔离、速览关闭与返回最新。Pencil Pro真实squeeze/hover/roll/触感和20ms/150ms延迟门槛仍需硬件，不由鼠标证据替代。

## 最终补验

- 新Mac最终38条原生/主机消息ID、状态、长度和正文SHA全部一致，游标867、公共末条3731字符；无活动run/草稿/附件，三项待办均false。`build5-final-native-data.json`、`build5-final-host-data.json`、`build5-final-data-comparison.json`。较早3849字符为含118字符供应端横幅的原始正文，原文仍保留在raw接口，不能将两种投影混作丢字。
- 夜间新圈画附件`965f7c986a2547528574c94bf8f28ef0`，843×501、257180字节、SHA `81bcd5854a1c421dcb66c802887187887fcc2ce8c95a08cb7375ce54f1adf9c9`，与本机PNG一致；主机成功读到1笔、归一化范围、底图存在和合法`#B8D2FCFF`。`build5-final-color-export.png`、`build5-final-color-metadata.json`。已通过UI移出草稿，原件保留。
- 日间怀表与圈画实际查看，781×493导出PNG的笔迹元数据也有效，颜色`#345E96FF`。`build5-day-ring-final.png`、`build5-day-circle-export.png`。随后通过保存按钮恢复night，主机读回balanced、sound=false、personality65/50/25；`build5-final-settings.json`。
- 另一个既有乐章打开手稿库为空，返回Moonlit notes后可见原记录和新圈画。`build5-other-library-settled.png`、`build5-original-library-open.png`。最初11份JSON/底图/PKDrawing/PNG在编辑、整机复制与新圈画后摘要仍全部相同；未宣称已覆盖另一主机的完整矩阵。
- 最终源在新Mac横竖屏方向校正后均实际查看；消息“查看手稿”打开真实内容，并用“收起”按钮关闭，再点“回到最新”返回最新回复末尾。全尺寸2360×1640原生截图`build5-native-final.png`已查看，原始像素方向副本保留。手稿图、数学正文、结束段与侧幕均可见；不作真机帧率结论。

## 原生实现

- `PencilCompanion.swift`在应用自己的UIWindow内处理Pencil触点、coalesced采样、真实force/azimuth/altitude/roll；显式圈画或高光模式才允许指触/指针画线。普通手指滚动、输入控件和原生画布保留各自工作方式。
- 五动作怀表：圈选追问、高光标记、展开草稿、语音附耳、思考档位。可触控或⌘⇧P打开；Pencil contextual squeeze依据系统偏好转发，同timestamp去重，系统快捷方式与PencilKit画布工具偏好保留。
- 圈画落笔会锁定主聊阅读，并触发观看姿态。每次完成保存当前可见区域的无笔迹底图、原始PKDrawing、逐点JSON与合成PNG；附到草稿后读回SQLite成功才清除候选，不自动发送。失败保留候选。
- 旋转、文档页或窗口上下文变更后隐藏旧坐标笔迹，保留原截图缩略图和递交入口，避免旧圈落在新段落上；下一笔另开记录。指触移动内容不拦截原滚动手势。
- 同一主机/设备资料库和同一会话内提供“圈画手稿”库；按捕获ID展示最新版本。formatVersion2可从独立底图+PKDrawing进入可编辑草稿。编辑保存使用独立会话ID，原始记录不覆盖；较早无可靠底图的记录仅预览。
- 公式富文本、附件缩略图、工具胶囊可提供真实手稿/摘要速览；消息“查看手稿”是手动入口。窗口原生弹层有关闭按钮。硬件Hover距离和响应尚未测量。
- 修复UIKit表格在宽度/复杂块高度改变后未重算行高导致的旋转文字重叠；合并重测，触摸、拖动、减速和快照提交时延后，并保留用户阅读锚点。

## 已实际观察

以下证据在`ipad/evidence/`，均保留原件，未生成新测试套件、夹具、断言案例或功能测试运行器。

| 工作流程 | 实际结果与证据 |
| --- | --- |
| 怀表五动作 | 环五项可见；语音进入00:00页面、未录音或申请麦克风；思考档进入真实模型目录、未更改选择；草稿展开原工作台。`build5-ring-first.png`、`build5-ring-voice.png`、`build5-ring-effort.png`、`build5-ring-scratchpad.png` |
| 键盘与手稿 | ⌘⇧P实际展开怀表；消息“查看手稿”展开真实源码的原生速览。`build5-keyboard-ring.png`、`build5-source-preview-open.png` |
| 全局聊天圈画 | 优先级修复后可圈公式、生成截图、附入原会话草稿。第一份图863×534、229611字节、SHA `ad274f59616a957d90b2eace7510ed9a999db225b987ab6d52753805f31cd85e`，PKDrawing391字节；未自动发送。`build5-circle-priority.png`、`build5-circle-export-first.png` |
| 独立底图 | v2底图已亲自查看，公式底图没有蓝圈。旧F4记录的所谓底图混入旧笔迹，保留并按旧格式只供预览，未冒充可无损编辑。`build5-circle-background-v2.png` |
| 编辑与恢复 | 擦蓝圈时原公式仍在，撤销恢复、重做再擦；新增短蓝线，关闭/重开及完整App重启后仍在。1800×906导出1229182字节/SHA `1583308699ef5dd769613f3c2c53f77e5b8894a27761ac4e7a83d2587b6cf245`，已看。`build5-editor-erased-layer.png`、`build5-editor-undo-restored.png`、`build5-editor-redo-erased.png`、`build5-editor-after-app-restart.png`、`build5-edited-capture-export.png` |
| 附件持久化 | 原图与编辑图两份附件在重启后的SQLite及全尺寸原生截图都可见。VNC曾显示旧帧，实际原生大图纠正了判断，没有凭小截图乱改布局。`build5-restored-native.png`；其后两项均通过UI移出草稿，原件保留 |
| 原始笔迹不覆盖 | 编辑前后的11份JSON/底图/PKDrawing/PNG摘要全部一致。`build5-captures-v2.json`与`build5-rotation-source-records.json` |
| 高光与旋转 | 宽笔锋实际可见；旋转后旧坐标高光隐藏，原图缩略图可递交。附件99934字节/SHA `ad054f3897895817b6eb15f603d7f37af6c3a84956740acd28e13a38b3b97fab`与旋转前原PNG一致，已看。`build5-rotation-highlight-preview.png`、`build5-rotated-attached-export.png` |
| PDF第2页 | 柱图圈画→附到草稿→翻第3页。附件131507字节/SHA `5d0d444728c4b11965cd62213a85a02210bb77ca057d653fe5694f3618e9c33c`与原PNG一致，圈和原柱图已看。`build5-pdf-attached-export.png`、`build5-pdf-page-moved.png`。此较早图颜色元数据有九位值，主机拒绝；后续修复已在最终新版昼夜新圈画导出读回，不据旧PDF图声称元数据通过 |
| 旋转排版 | 原生大图确认表格/正文重叠后修复；同一长回复重测版竖屏大图已无重叠。`build5-rotation-native.png`为缺陷证据，`build5-remeasured-native.png`为修复后观察 |
| 真实生成与阅读锁 | 通过UI发送226字符学习请求，run `ac1a2e509b614402b899c77a371d0083`、助手`39ff958a55f2412c92439b6f8f84c524`。0至至少2580字符时旧段落位置保持，返回按钮可见；原始3849字符回复完成后38条本机/主机ID/状态/长度/正文SHA全一致，游标867，无活动run/草稿/附件。`build5-stream-native-complete.json`、`build5-stream-host-current.json`、`build5-stream-lock-native.png`。随后新Mac最终源已返回最新并查看全尺寸结尾，公共正文3731字符与主机相同 |
| 自然深夜分支 | 未手动选茶，23:25为月下琴房，23:37自然切到披肩茶与休息提醒，未改系统时钟。`build5-late-time-observation.png` |

## 供应端重试信息修复

本轮真实请求先出现供应端503容量不足横幅，随后正常完成。不是Codex模型运行时终止或会话失效，没有创建恢复聊天。

`diagnostics.py`原来只识别“request failed”这一种精确横幅，现在补充实际出现的UNAVAILABLE容量横幅，仍保留代码围栏、引用段和本轮用户明确引用。`acp.py`/`provider.py`只将本轮用户原文用于引用判断，避免旧对话里保存过错误横幅后永远关闭诊断分流。

直接调用现有路由器处理实际保存的横幅，普通输出只有换行，横幅进入diagnostic。对既有事件784调用原有`Store.provider_diagnostic`完成精确分类；原消息3849字符与原事件完整保留，公共正文3731字符，私有raw接口能读到1条诊断。仅8767网关子进程重新载入，公共API已不再返回英文横幅；下一次真实重试的UI显示仍待观察。

## 独立Mac

原Mac US于本轮中被课程聊天使用。用户明确回复“新开一台”，因此创建独立磁盘/UUID/MAC的`Mac HajiSaki iPad`；SSH2224/VNC5904、最终16GiB/8vCPU，文件在`C:/Users/17601/Documents/Codex/2026-11-16/hajisaki-ipad-mac/`。原Mac保留运行，未重置VNC或关闭课程；没有发送未授权的协调消息。

在线复制已成功concluded并释放目标节点，新盘没有backing image，镜像检查无错误。新实例最终为16GiB/8vCPU；已实际启动并解锁macOS15.8.1/24H32，核对Xcode26.3/17C529、Swift6.2.4与iOS26.2运行环境，原iPad UUID和本地数据已恢复。SSH主机密钥与受信来源核对相同后添加新端口信任；未将密钥或口令放入工程。新Mac独立的18767开发转发已接到8767并从guest读回health=ok。原Mac US仍保留。原生TigerVNC新窗口打开前后宿主前台句柄相同。

新实例使用任务单独配置，不修改共享技能连接配置；所有后续模拟器输入必须指向5904，不能再盲用5903。启动盘选择的持久默认尚未证明，不能承诺完全无人值守冷启动；Codex可在新实例内选择已安装系统。此新VM是用户明确要求的资源隔离，不是从工具错误或等待推断出的聊天恢复。

## 完整目标与清理

完整Metal呼吸/发梢/雨丝、12种全身情绪、精确笔尖注视、停笔关切、系统扩展/外屏/媒体/归档/剪贴板/时光机/双隧道和量化真机/7日门槛等仍在台账内，没有缩减成只缺Apple签名或硬件。

`runtime/guest-secret-input.py`665字节（0.665KB，无密码值）和空`runtime/ipad-newmac-hostkey.pub`0字节已直接移入回收站，回执`runtime/ipad-build5-cleanup.json`。没有备份、恢复性试验或永久删除；不把逻辑大小称作释放空间。原始截图、原视频、JSON/PKDrawing、源图/提示词、构建和诊断回执保留；独立Mac的系统盘、启动器和运行所需文件保留。

新Mac管理目录内本轮创建的`__pycache__/vm.cpython-312.pyc`17027字节（17.027KB）随该临时缓存目录直接回收，控制器源码保留。最终`operational.json`再次读回新Mac8vCPU/运行中、VNC5904仅环回监听，以及原Mac仍运行；未将镜像逻辑大小或缓存大小称作释放空间。
