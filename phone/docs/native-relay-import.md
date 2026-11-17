# 原生备用通道资料

主机导出单个设备绑定文件，手机在“主机指挥台 → 配置备用琴房”导入。原有“另一条直连地址”仍是主通道的第二个地址，加密反向通道使用单独的配置。

## 导出与使用

使用`relay/`自己的Python环境，保留其独立依赖锁。现有生产通道应已通过`hajisaki_relay.provision --http-port`生成HTTPS入口、可信CA、客户端证书与服务器SPKI摘要。为手机签发独立companion设备钥匙；传给下面命令的是该设备的私有配对文件。

在`relay/`目录运行：

```text
.venv\Scripts\python -m hajisaki_relay.native_bundle --config runtime/deployment/phone/config.json --pairing-file ../runtime/device-provisioning/phone.json --directory runtime/native-transfer
```

输出为新目录里的`hajisaki-relay.hsr.json`。现有目录不会被覆盖，终端只输出路径、字节数与模式。导出会核对客户端证书的CA、有效期、用途和私钥匹配，重新将私钥封装成带口令的PKCS8。Windows目录先限制为当前账户和SYSTEM。

JSON本身是敏感配对资料，包含通道令牌与载荷钥匙，通过受信任的设备传输。手机安装后，口令与加密私钥分别保存。CA签发私钥、主机角色凭据和原始网关令牌不进入导出文件。

手机先填写本机设备钥匙与主通道地址，再从备用琴房选择文件；也可在密码字段填入同一份通道资料。主通道暂时不可达时，已填写的配对仍可用于认证备用通道。文件选择取消会返回原页；离开资料页清空输入。

## 设备认证与保存次序

资料版本为1，最多32KiB，仅接受明确列出的字段：

| 字段 | 内容 |
| --- | --- |
| `kind`、`version` | `hajisaki-relay`与1 |
| `device` | 本机配对的设备编号 |
| `relay` | HTTPS来源、通道编号和明确为false的development标志 |
| `credentials` | 手机角色令牌、32字节载荷钥匙、服务器SPKI摘要、私钥口令 |
| `files` | CA证书、客户端证书、加密PKCS8私钥的PEM内容 |
| `authentication` | 当前设备网关钥匙生成的HMAC-SHA256封签，标准Base64 |

封签覆盖除`authentication`外的全部字段。使用ASCII转义、按键名排序、无多余空白的JSON；域前缀为`HajiSaki/native-relay/v1`与一个零字节。原生按相同固定顺序构造内容，使用系统HMAC并逐字节比较32字节标签。格式解析使用与32字节完全等价的规范Base64规则，包含零填充位约束；实际密码运算继续使用系统接口。

导入先检查结构、设备与封签，才允许向新通道发送网关凭据。随后写入应用私有随机目录中的公开证书与加密私钥，配置TLS1.3、mTLS、CA与SPKI固定摘要，通过加密HSR1请求实际读取`/api/status`。取得有效认证回复后才更新Asset Store并安装通道。导入期间主机钥匙若改变，会停止本次提交。

通道钥匙、私钥口令及对应网关设备绑定保存在独立的Asset `SECRET`中，最多1024 UTF-8字节；要求锁屏密码、首次解锁后可用、禁止同步。普通SQLite、preferences和文件不承担明文钥匙回退。证书路径从真实UIAbilityContext私有目录派生，导入文件不能指定路径。预览产品不会把模拟的安全存储视为有效设备保存。

恢复时先读取安全通道记录，再通过正常配对流程连接。只有网关令牌和设备编号都与通道的安全绑定一致，网关才会使用这条备用路径；换用另一把主机钥匙会停用不匹配的旧路径。未完成的传送仍保留对应加密日志。

## 请求与更换钥匙

安装期间使用短暂配置锁，不在进行中的请求或未确认回执之间切换载荷身份。同一通道与载荷钥匙允许更新TLS资料；更换载荷身份前，还会检查持久日志中的未完成写操作。请求帧与方法、响应帧与完成状态分别原子写入加密RDB，预览适配器仍只在内存中保留这些内容。

GET不阻止更换；不确定结果及401、403、503不能证明原写操作已经完成。旧版缺少元数据的记录保留旧钥匙，按原编号重查时补齐方法与回执。此处保留原件和候选加密资料，不执行文件删除。

## 实际观察与验收边界

- 正式设备绑定文件实际导出2298字节，当前账户/SYSTEM的ACL已读回。用实际设备钥匙读回核对的HMAC标签一致；原始网关令牌没有作为字段输出。客户端加密私钥能读回，其公钥与证书公钥摘要一致。
- 现有生产模式本机中继已通过独立Python环境启动；使用同一companion设备的正常参考客户端读取主机状态，返回认证后的内层200、1327字节、不确定标志false。参考手机配置也改用该companion配对，未改变relay/host角色钥匙。
- 最终公共API26常规与预览构建均通过。实际查看主机台、日间与夜间资料页、格式拒绝、受限保存提示。2298字节真实文件通过原生结构校验后被预览产品的安全存储边界阻止；返回主机台仍在线且备用状态仍为未导入。重开资料页输入为空。相关画面为`tooling/evidence/native-relay-final-*.png`。
- 当前Previewer的Base64系统调用曾对44字符数据返回0字节，已通过仅含阶段与长度的诊断定位。结构解析改用等价规范检查；没有将空结果当作有效密码操作。
- 文件选择入口实际返回了未选择文件的原界面，没有取得系统选择的真实URI。设备端HMAC认证、Asset保存/恢复、TLS正负向握手、持久日志恢复、实际5G/跨城双通道和1.5秒切换仍未验收。现有自动路由基础也不等于原生Mesh或完整双向热切换。

依据：[Asset属性与1024字节限制](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/asset-js-add/)、[系统HMAC接口](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/crypto-compute-hmac/)、[NetworkKit客户端证书与固定摘要](https://developer.huawei.com/consumer/en/doc/doccenter-references/api/js-apis-http/)。API26声明还用于核对请求body、TLS参数与文件接口。
