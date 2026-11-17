# iPad 0.1.0（7）原生复习卡片与收尾

本轮增加原生闪卡和单选决策卡，修复返回控件遮挡卡片的问题。用户随后明确以最核心使用链路收尾，范围见core-delivery.md；原始120项继续完整保存在acceptance-ledger.md，不虚报全量通过。最终未签名设备包已生成并校验，真实iPad安装尚需本人签名。

## 实现与真实模型交付

宿主增加严格的`.hajicard.json`协议、`create_interactive_card`工具、按乐章原件访问验证和设备身份绑定的单选投票。卡片保留为普通CAS原件，投票记录进入正常全库JSON导出。native-cards-v1选择的profile4仅控制附加MCP目录（比旧14项多本工具），不替代Antigravity原生工具。已整合聊天“Read Codex goal objective (3)”对共享主机的修改，保留CLI默认定制、原生系统/工具/执行循环，App文件协议仍生效，见native-harness-contract.md及native-harness-verification.md。原先限制原生工具的gateway-tools配置不再用于启动；没有重置原有provider会话。

初次运行被旧ACP策略校验拦住，已按实际grant选择版本目录；随后实际模型接口拒绝整数enum，已由宿主固定协议v1，移除工具参数里多余的version。原始失败记录保留。seq1430的英文SDK横幅被精确归入诊断，未重写原始事件；现有PublicTextRouter直接处理该真实输出后只留下换行，并识别fatal schema状态，不把技术错误正文递给用户。未新建测试、夹具或测试运行器。

实际成功run为`bd70bd019f4049c5a4d0ce544dc777d9`，助手`5d562371de884439b1de88ecd1a7a890`。模型交付：

- `sine-phase-shift-flashcards.hajicard.json`，1798B，artifact `8b3f6405c52f4e7faa91f0cf43f0f669`，SHA `61d75119e2cf5ed2f096e9e3d53ee3257575930395aa2e3de8dcb6f6232e15bb`。
- `sine-next-step-poll.hajicard.json`，400B，artifact `0f8aea4dc36d4cb2b4ad5777582dc8f3`，SHA `2a1711cfaf27504b44757e477d9d50cf55135526bc4f8d6e429e1490d1ffcaa0`。

原提示要求三张，模型实际生成四张闪卡和四选项决策卡；记录实际内容，不写成三张。第一张题/答案、第二张题/答案中的振幅、值域、周期、相移公式已实际查看。原生按钮直接翻面，未用HTML模拟卡片。

## 操作、保存与恢复

UI首次选择选项0，主机读回`[1,0,0,0]`；再次点击同项仍为`[1,0,0,0]`，改选1后为`[0,1,0,0]`。当前设备只有一条投票，不追加重复票。

Mac重启及0.1.0（7）正常ad-hoc更新后，原生仍是第二张题面，第一张翻面集合保留；离线时第二张能翻到答案，本机SQLite读回index=1、revealed={0,1}。决策卡继续显示选项1/一票，离线时明确暂停投票。竖屏→横屏后卡片与选择保留，恢复本任务开发forward后重新连上。

原始悬浮“回到最新”在大图中挡住投票文字，已移到消息区下方独立44pt栏。7C实际滚动后的图片显示该栏保留自身空间，不再覆盖正文；最终实际点击该栏后回到最新数学回复，控件退场，见build7-core-returnbar-visible.png及build7-core-returned-latest.png。

20,953,398B的正常全库ZIP已实际导出，含两份原始卡片及当前card_votes记录。原件SHA与模型交付相同，投票为选项1；见`ipad/evidence/build7-library-export-readback.json`，原始归档保留。

## 构建与环境

最后正常签名模拟器源`4cfb1299fd06cdf26d97053ff9f77e2204d7b492308596e685bfce42c3c90f9a`，签名二进制SHA `7113d98899baff51df443b5a68c01a0db578925d941d8734690aa6c9ee365c22`。7B残留旧控件引用的编译失败已修正，7C已编译并实际运行。

首次arm64设备编译完成，但最后ditto封包因新Mac系统盘空间不足失败。另建空白80GiB构建数据盘HajiSakiBuild（卷UUID485EA340-1E7A-4880-B779-AE29B92D48D0），正常停机接入后仅初始化这张新空盘，将新Mac自身CodexIOSLab/sources构建目录迁入并保留原路径链接。原Mac未操作。实际读回系统盘可用57GiB、新卷可用20GiB；文件保留，没有永久删除缓存。系统虚拟盘256GiB、APFS仍160GiB及剩余未分配区均如实保留，不把失败的容器扩展写成成功。

复用已完成的arm64编译结果，在新卷正常ditto封包。63,563,613B不完整IPA经FileManager.trashItem直接移入废纸篓。最终IPA为88,020,621B，SHA `03ba2d3c83f822ce6224a639f7f28fdd310721d23647cd66c7397706e13c3651`，0.1.0（7）、iPhoneOS、arm64、iPad family2、最低18.0，无签名/描述文件。设备源`3d9e35301d77963a422bec6d501eba025d983d25675167c4e148539c5ae19a5f`；146份App/资产与模拟器和工作区差异均为空。两份开发配对口令的包内容检查无匹配，未打印口令。成品在outputs/install-build7/，回执在outputs/device-build7-final/。

合并后的共享后端真实完成原生read_file、App进度说明和Markdown交付；本任务亲自打开了回传的827B文档，原生缓存SHA为b3684a2659f67db763719f2eb2bc09cbc0bcc04cc0fb20043c1042d1004befd4。主机与原生54条消息/游标1502的完整有序摘要相同。最后还通过原生UI发送普通数学短问，真实回答振幅2、周期2π/3，非演练。PencilKit重新解码证明旧365B/599B/1292B非空归档仍保留1/2/2笔。

最后一轮真实短问run `54d4ae718e7748cc8578a864e65c362e`已completed，主机authenticated=true、simulated=false、model_api_proxy=false；56条/游标1512的有序ID/状态/长度/SHA与原生全等且唯一，无活动run/草稿/附件。Google CLI本机签名再读回Valid/Google LLC。最终2360×1640截图core-delivery-final.png已亲自查看，数学回复与原生Markdown卷宗同屏。正式8765网关已为真实iPad生成独立companion配对并成功认证，口令保留在受保护的runtime/ipad-pairing.json，未输出；三份配对口令的IPA内容扫描均无匹配。清理文件名与逻辑大小见core-delivery.md。

所有Mac操作仅在新Mac HajiSaki iPad的2224/5904，原Mac US课程环境未操作。虚拟Mac口令仅瞬时输入，没有写进代码、日志或成品。真实iPad签名/安装、Pencil硬件、广域网双通道与完整性能门槛未因此通过。
