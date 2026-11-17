# iPad 0.1.0（6）· 笔记阅读与恢复

已生成并检查build6预览安装输入，build5保留。完整120项宪章继续active，本轮根代理独立工作，没有新建聊天或子代理。

按用户“新开一台”的要求使用独立Mac HajiSaki iPad：SSH2224、VNC5904，独立完整系统盘，16GiB/8vCPU。原Mac US及课程聊天继续使用原环境。本轮构建、Simulator与输入均在新Mac，未接管Windows宿主键鼠或剪贴板，未启用定位。启动入口在`C:/Users/17601/Documents/Codex/2026-11-16/hajisaki-ipad-mac/Open Mac HajiSaki iPad.pyw`；原始虚拟盘与数据保留。

## 已实现与实际观察

公式后的中文逗号在旧原生大图中孤立到下一行。先加strict CJK规则后仍复现；随后用DOM Range把真实标点与公式相邻片段成组，保留原文本及强调。短公式整体换行，长公式仍可在前面的KaTeX base之间换行，超宽尾部局部横滑。未插入不可见字符或改写模型正文。`build6-first-css.png`为未修复观察，`build6-punctuation.png`、`build6-stage-native.png`为实际修复后观察。[CSS断行规范](https://www.w3.org/TR/css-text-3/)说明了排版边界规则；[DOM Range文档](https://developer.mozilla.org/en-US/docs/Web/API/Range/extractContents)对应所用的真实节点提取方式。

原生请求携带`X-Haji-Platform: ipados`，主机将白名单平台与features放入本轮message_created事件，再注入iPad原生、卷宗和手写工作台环境。通用client交付别名此前已存在，系统指引改为优先使用它们。中继放行平台头和既有文件定位头，没有扩展文件/命令授权或修改数据库schema。现有中继校验函数使用本轮实际消息元数据正常调用后保留这两个头；这不是WAN部署或主备切换验证。

通过实际UI发送179字符复习笔记请求，run `9143ef206eb540c4ad1f87a6e7ec0058`、助手`ae269f97476341bbb861f1a0c5a80a39`；事件868实际记录ipados与artifact-links-v1。模型调用工具回传`phase-shift-revision-note.md`，artifact `f059bf29a4094fa7bc45b6880bcb4a4f`，2169字节，SHA `76c7625cd4322f026edd1baf3375c456f225b7c29f501fc05c719166aa8008ac`。主机下载与原生缓存摘要相同，回复给出消息链接、附件卡和卷宗入口，未报主机路径。

首次打开文件时，卷宗只显示Markdown/LaTeX源码。现加入离线阅读预览与明确的源码切换；公式、标题、列表和七列表格实际显示，表格能横滑且首列固定。带源码行定位的打开方式继续走原有代码定位；超过有界UTF-8预览范围时保留分页原文和原件导出。

当前文件拥有懒建的原生滚动WebKit会话，源码模式和DOM随同一份卷宗保留。初版外层ScrollView导致竖屏重回顶端；会话版仍出现返回横屏纵向漂移。只读LLDB/Mirror实际读到：宽viewport保存y930，但当前停在竖viewport上限y675；宽WK416.5×621、内容1551、DOM1534、measuredWidth417。改为观察原生内容尺寸并等待提交后恢复。6F源`3c847c0fb20bfc121761b93b6602edf643a26dee310c67e7f8b5d41eee603dbb`已在同一路径复查，`build6-ready-position-before.png`与`build6-ready-landscape-returned.png`的表格/段落纵向位置一致，右侧列保留。源码往返、源码模式随布局保留、日间阅读及恢复night都实际查看。

## 启动与侧幕

用正常App重开录制原生视频：before 18.65秒/403帧，after 18.61秒/469帧；逐张查看所选0.7/1.5/2.5/5/17秒全帧，原片保留。这些帧率和时间不是实机冷启或60FPS结论。

发现白色启动屏后，加入Display P3藏蓝LaunchBackground颜色资产与UILaunchScreen颜色声明。after录像中的白底已去，但初始状态栏仍黑字，因此补初始LightContent并保留view-controller自适应。[Apple启动颜色文档](https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen/uicolorname)和[状态栏说明](https://developer.apple.com/documentation/technotes/tn3105-customizing-uistatusbar-syle)支持所用配置。

最终正常重开录像`build6-stage-launch-final.mp4`为18.885秒/428帧。1.5秒实际启动屏为藏蓝底、白色状态字，5/17秒已是完整三栏和人物，夜间状态字为白色；日间保存设置后状态字为黑色，未把全局界面强制锁成深色。2.5秒系统到首帧的淡入过渡中仍短暂出现黑色状态字，因此不能宣称启动全程样式或550ms指标通过。所选原生全帧逐张查看并保留，录像帧数不当作真实设备FPS。

侧幕预热改为当前姿态优先、姿态变更取消旧批次、每姿态之间让出执行；图像与几何在同一事务布局。一次原生截屏中人物曾只露边缘，后续连续视频未复现持续裁切，证据保留，不将其根因伪称已完全证明。实际长请求中思考姿态已出现，但未对首次到达延迟给量化结论。

## 长回复、锁屏与断流

通过原生UI发送279字符完整讲解请求，run `dea40c5ea51243739e9f7127a94af7c2`、助手`45515e22a87c49bfbbfa0bd176397cbf`。回复仍running、前缀20396字符/4410 CJK时，停止新Mac自己的开发forward PID56012，并操作Simulator Device→Lock。

最初计划15秒，实际记录链路中断65.650秒，必须按实际时长报告。随后同一新Mac上的forward PID13636重新接起18767→Windows8767，guest health=ok；Home唤醒并上滑解锁。主机最终正文26253字符、其中5399 CJK，保留断流前全部前缀。

原生与主机42条消息的有序ID列表、唯一性、状态、长度及全文SHA全部一致，游标1423；无活动run/草稿/待发附件。末条SHA `ba82aaba124cc4f5cd089d938a10d2a4d1e999d4d3bfaa144381436aad6a2273`。`build6-link-interruption.json`、`build6-cut-host.json`、`build6-long-native-after-link.json`、`build6-long-host-after-link.json`和`build6-link-data-comparison.json`保留真实读回。

解锁初次重接有短暂“新的乐章”空页，之后`build6-restored-visible-current.png`实际显示完整结尾。定位到同一会话重新加载也先清空数据，6H改为保留同namespace、同会话、已就绪的内存内容，跳过旧缓存覆盖；真正切换资料库/乐章仍加载自己的缓存和草稿。

6H已正常ad-hoc签名安装后实际复查：先从文件柜“围绕它继续问”附入Markdown原件，再写35字符未发送草稿`please keep this question for later`，锁屏并停止本任务forward PID13636。记录的中断窗口为17.67秒，重新启动的forward PID49416；此时没有模型运行，不冒充第二次流中断。Home唤醒、上滑解锁后，正文和草稿/单个附件同时保留；切到“未写完的乐章”再回Moonlit notes，内容不串、不重复。三个SQLite读回均为42条/游标1423、同一草稿和单个artifact，见`build6-draft-before-reconnect.json`、`build6-draft-after-reconnect.json`、`build6-draft-after-switch.json`及对应实际屏幕。最终仅通过UI清空本轮临时草稿并移除待发附件，原件保留。

上述观察仅覆盖本次本地模拟器与65.65秒中断，不记精确15秒条件或国内网络/WAN、500条、15000中文字符、帧率/热控、Pencil硬件等门槛通过。26253是总字符数，不能写成26253个中文字。

## 相邻模式与最终产物

最终6H中的HTML正弦微剧场实际从文件柜打开，振幅从1.00调到1.10，查看源码后回预览仍为1.10，曲线与极值同步。PDF实际打开首页、下一页至2/12并开启柔光；保存日间、再恢复夜间后页码/柔光仍保留，状态栏各自可读。没有把这些相邻模式观察扩大为全部HTML/PDF、Pencil硬件或安全内容全覆盖。

实际重开Markdown卷宗后的2360×1640原生大图`build6-final-native.png`已亲自查看。最终本机与主机42条消息的有序ID、状态、长度及正文SHA完全一致，游标1423，无活动run/草稿/附件；PDF、HTML、Markdown原件摘要均保持。主机设置读回night、sound=false、性格65/50/25，见`build6-final-host-readback.json`与`build6-final-native-data.json`。

最后正常签名模拟器源码SHA为`e64aa68f79b5e67f989293dbab763cc7c68f66d71cffab618ab1cc2c01e5e5af`，实际签名二进制SHA为`b43b62eea0d389d36b26eeb57f9996bff3b405d9bb3bbd037e798544b70ee80a`。最终arm64设备构建源码SHA为`027d899f84732810a084059a070eab27d4117ef9d0614cbfaab1c5c231465539`，全树因工作记录变化而不同；144份App及assets文件逐项摘要与模拟器及当前工作区一致，差异均为空。回执在`outputs/device-build6-final/integrated-source-check.json`。

安装输入为`outputs/install-build6/HajiSaki-iPad-0.1.0-build6-d0242db8-unsigned.ipa`，87,948,606字节，SHA `d0242db8ff7826a0572f6025306e262005abb88f15517916b0d8780d7af939ee`。ZIP内Info为0.1.0（6）/iPhoneOS/iPad family2/最低18.0，Mach-O为arm64；无签名或描述文件。以现有两份开发配对口令在内存作包内容检查，无匹配，未输出口令。尚未正常Apple设备签名或安装真实iPad，模拟器签名不代替实机签名。

## 清理与完整范围

未新建单元/功能/E2E测试、夹具或测试运行器；使用实际UI、现有API与校验函数、编译器、只读调试和最小视觉录制。仅将确认的一次性文件直接移入回收站：`runtime/read-markdown-owner.sh`（882B/0.86KiB）、旧6F候选`outputs/device-build6/Application-unsigned.ipa`（87,948,260B/83.87MiB）、新Mac管理目录的`__pycache__/vm.cpython-312.pyc`（17,027B/16.63KiB）。这些是文件逻辑大小，不声称实际腾出同等磁盘空间。旧候选回执/manifest、稳定build5、原始日志/截图/原片/原件/笔迹全部保留。

完整Metal/12种全身情绪、精确笔尖注视、系统扩展、互动卡/媒体、全量归档、剪贴板/时光机/双通道及真实量化门槛仍在台账；启动过渡样式也仍需精修。完整目标未完成，未缩减成只缺签名或硬件。
