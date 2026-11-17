# iPad 核心版交付 · 0.1.0（7）

按用户2026-11-16最新要求，本次以“最核心的使用链路”收尾。原始120项不虚报全量通过，继续保留在`acceptance-ledger.md`作为后续规划。

## 核心交付与证据

| 核心能力 | 当前结果与实际证据 |
| --- | --- |
| 原生平板界面 | SwiftUI/UIKit原生工程，横屏三栏、竖屏阅读与卷宗；昼夜资源、对话、文档及批注入口已在Apple Simulator实际运行。最后客户端源4cfb1299…，30份Swift文件 |
| 真实模型聊天 | Windows后台调用Google签名Antigravity CLI的原生ACP/harness。没有抽取裸模型、没有模型HTTP兼容反代；原生工具与App交付在同轮协作。已整合“Read Codex goal objective (3)”的共享主机修改，见`../native-harness-verification.md` |
| 文件与学习协作 | 实际PDF、图片、源码、Markdown/公式与HTML工作台可打开；原生PencilKit/圈画保存可编辑笔迹，PNG回到草稿后由用户发送。此前真实图像回复已观察；本轮PencilKit再次解码，旧365B一笔、599B两笔、1292B两笔归档保留 |
| 数据与恢复 | Keychain保存配对，SQLite保存历史、游标、草稿、待发队列及卡片状态；实际锁屏断流恢复、应用更新/重开和离线草稿验证已记录。最终56条消息有序ID、状态、长度与全文SHA在主机/原生完全一致，游标1512，无活动任务/草稿/待发附件；真实短问答正确返回振幅2、周期2π/3 |
| 私有接入与独立配对 | 客户端支持自己的HTTPS/加密私网网关地址，拒绝凭据跨站重定向。已为真实iPad在正式8765网关签发独立companion配对并验证认证成功；口令仅保存在本机受保护的`runtime/ipad-pairing.json`，未写进IPA、文档或聊天 |
| 可构建、可交付 | 独立Xcode工程和资源齐全，不依赖Codex会话运行。arm64/iPhoneOS/iPad family2/最低18.0的未签名IPA已生成；146份App及资源与已运行模拟器、当前工作区逐项SHA相同。安装仍须正常Apple签名 |

新增闪卡/决策卡已完成直接交付、翻面、单票改选和本地保存，保留在此版本。完整Metal/12种全身情绪、Widget/Live Activity、外接4K、双通道自动切换、时光机、全部高级语音及实机量化门槛不再阻塞本次核心版收尾。

## 安装和接入

1. 用正常Apple签名方式安装`ipad/outputs/install-build7/HajiSaki-iPad-0.1.0-build7-03ba2d3c-unsigned.ipa`，或在Mac/Xcode打开`ipad/App/HajiSaki.xcodeproj`选择自己的Team和iPad构建。Apple账号、OTP、信任与开发者模式由本人在本机完成。
2. Windows双击工程根目录的`HajiSaki.pyw`，保留已有Antigravity正常登录。正式共享网关默认8765；本轮模拟器8767/SSH18767是独立开发线路，真实iPad不能填写`127.0.0.1:18767`。
3. 为真实iPad准备可达的私有HTTPS地址。可让Windows和iPad的官方Tailscale客户端加入同一tailnet，再在Windows运行下述命令，使用它输出的HTTPS地址。它只承载App网关传输，模型仍由官方CLI原生harness处理。[Tailscale官方Serve说明](https://tailscale.com/docs/reference/tailscale-cli/serve)说明HTTPS及后台选项；本轮没有执行Tailscale账号登录或国内外网实机验证。

```powershell
python tools/run.py --timeout 30 -- tailscale serve --bg --https=8443 http://127.0.0.1:8765
```

4. 在本机查看受保护的`runtime/ipad-pairing.json`。把`device`原样填入App“设备标识”，把`token`填入“配对口令”，地址填上一步的私网HTTPS地址。它们不是Apple账号或虚拟Mac密码。重新准备配对可运行`.venv/Scripts/python.exe tools/pair_ipad.py`；工具不会把口令打印到控制台。
5. 连接后直接对话，文件柜打开原件；PDF/图片“批注”保留独立笔迹，“递给祥子看这段”先回草稿，再由本人发送。

## 交付文件与边界

IPA：88,020,621字节；SHA-256 `03ba2d3c83f822ce6224a639f7f28fdd310721d23647cd66c7397706e13c3651`。设备构建/源码回执在`ipad/outputs/device-build7-final/`；具体观察在`verification-build7-2026-11-16.md`，原始图、数据和文件在`ipad/evidence/`。

模拟器与Windows主机核心链路已经取得真实证据。尚未安装到实际iPad；Apple签名、本人私网登录和真实Pencil压力/触感/性能仍需对应设备与本人操作，不能用模拟器或未签名IPA冒充已完成这些步骤。主机原生权限要求本人确认的操作仍保留边界，完整App审批UI不在本次核心版中。

收尾清理仅针对确认的一次性文件，全部直接进入回收站/废纸篓：`finish-existing-package.sh`（948B/0.95KB）、`move-build-storage.sh`（1362B/1.36KB）、`temporary-guest-maintenance.py`（5626B/5.63KB）及封包失败的`Application-unsigned.ipa`（63,563,613B/63.56MB）。大小为文件逻辑大小，不等同于释放的磁盘空间。原始图片、文件、笔迹、历史包、源码回执和诊断证据保留。
