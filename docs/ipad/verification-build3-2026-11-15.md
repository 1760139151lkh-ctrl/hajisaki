# iPad 0.1.0（3）· 交互微剧场

继续完整宪章，由根代理独立实现和验收。本次新增独立HTML交互预览，修复网页键盘焦点与打开工作台时最新回复的位置；完整120项台账继续保留，目标仍为active。

## 当前产物

- 设备IPA：`ipad/outputs/install-build3/HajiSaki-iPad-0.1.0-build3-24391b43-unsigned.ipa`，70,202,454字节，SHA256 `24391b4371e358d57ddfa6d1ee9cb19372ddd646b0457937d79e1ff1bae86002`；原build2包保留。
- 平台为arm64/iPhoneOS、iPad专用设备族2、最低iPadOS18.0、版本0.1.0（3）、bundle `app.hajisaki.theater.ipad`。包内没有签名目录或设备描述文件，仍需正常Apple设备签名。Windows本次只读枚举未见Apple/iPad USB设备，没有实际安装。
- 设备源快照`ea988e6f5339b04dddd98fd26bf3af4742a5649b8c0efcd2ef05344792c47b4e`；实际设备构建、包结构/架构/摘要回执分别在`ipad/outputs/device-build3/build-receipt.json`、`package-validation.json`及`root-verification.json`。安装输入回执在`ipad/outputs/install-build3/install-packet.json`。
- 122份App/资产文件与已运行模拟器版本摘要一致，当前工作区这些文件也与包快照相同。包内未发现当前主资料库/独立iPad两项配对令牌，未发现位置权限声明。该检查只覆盖明确列出的令牌，未把它说成对所有潜在秘密的证明。

最终原生预览：`ipad/evidence/build3-native-theater.png`；原始像素方向文件为`build3-native-raw.png`。已签名模拟器源快照为`7b85dacbb4480ea436f9aba7251711cb4cf862c335a95bd46991a29b36340aff`，实际签名回执为`build3-signed-simulator.json`。设备包与后续说明材料的源树摘要可能不同，应比较真正编入App的文件摘要。

## 实际入口与观察

在现有`Moonlit notes`会话发出真实模型请求，由运行`dbbf52f3e7114c8bb5dd066070612c9f`完成助手回复`f3ac0216ee8143ebb7f2cdd5ce21382f`，并交付附件`154da9ad247a4621a6667dd56d03fde9`。`sine-wave-workbench.html`为19,233字节，SHA256为`ba441d4aac510494e00afcd8739900a1003a533d6d260e85103b5d75e4ba0522`。它是实际模型产物，未把临时测试内容伪装成已交付回复。

| 流程 | 实际观察与证据 |
| --- | --- |
| 从聊天附件/共享文件柜打开 | 原生卷宗直接显示中文正弦波观测台；外部库不参与。三滑杆、基线/主曲线和数值均真实呈现 |
| 触控调参、微调与重置 | 过程中a=1.95、b=1.90、c=1.20时最高3.15/最低−0.75；本次最终状态a=1.95、b=1.90、c=0.95时最高2.90/最低−1.00、周期1.05π。`interactive-three-parameters-landscape.png`与`build3-native-theater.png`分别保留两个时刻，不能混作同一状态 |
| 硬件键盘 | 实际点入滑杆后，右方向键将a从1.00变1.05；Tab沿控件顺序进入b，方向键将b变1.05；R恢复1/1/0。`build3-keyboard-parameters.png`、`build3-keyboard-reset.png`。这里只覆盖明确操作过的控件，不是全部网页无障碍组合验收 |
| 曲线读点 | 在画布内实际按下并移动，显示交叉线/圆点及约x=2.09、y=0.87。`build3-curve-probe.png`，不是只看到静态曲线就宣称交互通过 |
| 源码/预览切换 | 原生源码可阅读；返回预览保留参数和内部滚动位置。`build3-source-view.png`、`build3-source-state-restored.png`。隐藏页面采用WebKit suspend调度策略，未另行把它说成实测功耗达标 |
| 横竖屏及工作台关闭/恢复 | 竖屏打开卷宗、返回横屏、关闭右栏再打开仍保留同一DOM参数。`build3-portrait-state.png`与最终原生图。不是任意Stage Manager/4K/应用重启内存状态持久化的结论 |
| 最新回复位置 | 原先右栏展开后会露出较早内容。改为观察内容/视口尺寸并仅在跟随最新时重新定位；最终实际打开工作台仍显示最新回复及附件。`build3-latest-before-opening.png`、`build3-latest-after-opening.png` |
| 阅读锁 | 上翻后“回到最新”出现；工作台尺寸变化后锁定状态仍在，点击该入口可恢复跟随。`build3-reading-lock-before-resize.png`、`build3-reading-lock-after-resize.png`。未将此扩大成任意尺寸下的精确字符锚点保证 |
| 原件与落盘 | 原生缓存HTML与实际模型原件摘要相同；14条原生/主机消息的ID、状态、长度和正文SHA全部一致，游标均150，无活动运行、草稿附件为空。`build3-native-data.json`、`build3-host-data.json` |

本次通过既有Xcode构建、正常UI/键盘、现有API/SQLite读回和最小视觉捕获验证，没有新增测试套件、断言用例、夹具或功能测试运行器。修复后静置原生进程单次读数为0.0% CPU，采样在`runtime/ipad-build3-process.log`；这是本虚拟机观察，不是iPad功耗/FPS指标。

## 修复与边界

- WebKit内容规则编译拒绝合并正则，已改为独立规则；opaque `about:blank`的path为空，导航白名单改为验证完整about地址。
- 点入网页时用公开UIKit responder接口接收键盘；子页面在原文之前建立权限限制及控件焦点处理。range需在触摸结束后恢复焦点；Tab按页面控件顺序移动，源码在首尾交回系统。诊断读取控件类型的临时代码已移除，实际诊断日志保留。
- `InteractiveDocumentView.swift`拥有独立非持久WKWebView，原文在只有`allow-scripts`的opaque sandbox iframe中；CSP/规则/导航delegate限制外部连接，没有原生主机、凭据、文件或复制消息桥。媒体/运动/文件选择/弹窗被拒绝，位置服务从未开启或授权。没有触发定位请求来作验证。
- `DocumentInspector.swift`在后台读取最多2MiB UTF-8 HTML/HTM，提供源码和原件导出；同一卷宗会话保留DOM。新开另一份卷宗或重启应用重新开始，不假称任意网页内部状态跨年保存。
- `TheaterRootView.swift`令卷宗持有会话；`ConversationStage.swift`按实际内容与容器尺寸保持最新回复，并服从阅读锁；生成工程版本更新为3。

完整闪卡/投票、活体姿态与12套全身差分、Pencil Pro/系统扩展/外屏、全量原生笔迹归档、私网双通道、真实设备安装与量化门槛等仍在120项台账中。HTML演示不等于这些项目完成。原Mac、模拟器、主机数据及开发转发继续复用，没有新增或替换聊天/VM/子代理。

## 清理

`runtime/guest-secret-input.py`（558字节，约0.56KB）已直接送入Windows回收站；它不含密码值。没有创建备份、试验恢复性或永久删除，也没有把逻辑文件大小说成释放的磁盘空间。SDK、原件、源码快照、笔迹与诊断证据继续保留。
