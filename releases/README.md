# 双端安装包与原生构建产物

## 本机构建 · 公主的小客厅

源码来自 `princess-redesign` 提交 `f9e6aeb`。本地为双端更新了构建号，并为 Android 包配置本次主机连接地址及已配对设备的地址迁移。

| 产品 | 本机产物 | SHA-256 |
| --- | --- | --- |
| Android 1.0.3（4） | `releases/hajisaki-android.apk` | `bf914062d3482484b4840dbd468607b97c4bd0266647a662a382cc43ceb13b71` |
| iPad 0.1.0（8） | `ipad/outputs/princess-install8/HajiSaki-iPad-0.1.0-build8-32ae4e6b-unsigned.ipa` | `32ae4e6bda536c6dda406610af52b73c6353528ab52eb3df36f9a57ce1f024a8` |

Android 已核对发布签名，并在 Android 15 模拟器从 1.0.2 覆盖安装，验证原配对迁移、历史信笺加载及文件附入草稿。iPad 已完成 arm64 实机构建，并在 iPad Air 模拟器看到新版界面。模拟器配对尚未完成，实体 iPad 仍需 Apple 签名。两个下载的完整字节均与本地构建的 SHA-256 一致。

## 2026-11-17 上传快照

最新安装包通过[私有 GitHub Release](https://github.com/1760139151lkh-ctrl/hajisaki/releases/tag/snapshot-2026-11-17)提供，不写入 Git 历史。

| 文件 | 实际字节数 | 版本与签名 |
| --- | ---: | --- |
| `hajisaki-android.apk` | 44,886,529 | Android 1.0.2（3），项目发布密钥签名 |
| `HajiSaki-iPad-0.1.0-build7-03ba2d3c-unsigned.ipa` | 88,020,621 | iPad 0.1.0（7），未签名 |
| `hajisaki-openharmony-api26-unsigned.hap` | 64,279,942 | OpenHarmony API 26，未签名 debug |
| `hajisaki-preview-api26-unsigned.hap` | 64,280,782 | API 26 临时预览，未签名 debug |

四份文件均按实际文件计算 SHA-256；完整清单为 `snapshot-2026-11-17.json`。Android APK 含既有单设备限时首次连接码，仅供私人下载；iPad 需要正常 Apple 签名。源工程、运行说明与验收边界分别见 `phone/android/`、`ipad/`、`phone/harmony/`。

## OpenHarmony 诊断包说明

本目录为源码真实编译的未签名 debug HAP，不是华为手机可直接安装的签名发行版。

| 文件 | 实际字节数 | 存储模式 |
| --- | ---: | --- |
| `hajisaki-openharmony-api26-unsigned.hap` | 64,279,942 | 生产代码路径：S3加密RDB |
| `hajisaki-preview-api26-unsigned.hap` | 64,280,782 | 显式临时预览：关闭后清空本机记录 |

两包均含实际 `ets/modules.abc`；包元数据为OpenHarmony SDK `26.0.0.38`、目标API26。每包旁侧的 `manifest.json` 保留实际SHA-256、应用信息和对应暂存源码摘要；`build.log` 保留编译日志。临时预览包名为 `com.hajisaki.companion.preview`，常规包名为 `com.hajisaki.companion`。

当前包包含PDF纸页、工作簿和ZIP目录的原生阅读入口与缓存/重连处理。实际检查了切表、行分页、固定表头首列、PDF缩放/平移/跳页、主机停止时的缓存重开及恢复重试；没有把临时预览算作生产存储或Pura硬件验收。HAP保留123份离线渲染资源。

当前包也包含原生画室、聊天图片、图片墙、大图缩放/柔光/批注返回和原图追问。共享网关提供有界缩略图、真实 ThumbHash 及 MCP 图片/PDF 页面读取，原生过程页可打开实际取出的画面。手机现已直接解码 hash，先通过轻量元数据接口获取占位，再取图片；占位与图片使用相同显示区域，实际中间帧和缓存离线重开均已查看。真实 GIF 首帧也已交给模型并准确描述；输入区文件名可打开预览，移除使用单独按钮。窄屏文件卡片将名称/大小和操作分行；文件阅读以覆盖页保留下面的页面。合同与剩余边界见 `phone/docs/native-images.md`。常规包 SHA-256 为 `e44503d9c88dcde4a112b7dc974c247b7d73922eb99231a4757dca47fc94f22f`，预览包为 `d260ba677b61050b33e768bcd820bc92c526538975e3567f3f900a5b4e5af9a9`。

保存错误现按真实阶段反馈，阅读页“重试”接回保存并保留阅读位置。已实际检查当前Previewer的写入失败与重试；首块写入返回0，未进入系统保存窗口。系统文件导出、取消和原件摘要仍待真实设备验证。

新包还包括备用通道资料页、设备封签、安全存储与恢复路径、通道设备绑定及未完成回执的钥匙保护。真实资料已在最终预览中通过格式校验，并明确被临时预览的安全存储边界阻止；主连接保留，离开资料页输入清空。设备端HMAC、Asset恢复、TLS正负向握手和外网双模尚未通过验收。

构建入口为 `phone/harmony/tools/build.py`，复制与生成清单入口为 `phone/harmony/tools/package_release.py`。华为 `default` 产品仍需要对应HarmonyOS SDK和设备开发签名。当前包没有证明手机安装、生产RDB耐久性、系统Kit或硬件指标通过，具体已观察结果见 `docs/acceptance-ledger.md`。
