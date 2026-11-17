# 本地编译与原生画面采集工具

这里的脚本不依赖 Codex 内部运行时。下载和解包使用 Python 3.11+ 标准库；预览桥接使用 Windows、Python 和 `requirements-preview.txt` 中列出的公开包。

## 获取公开 SDK

在工程根目录执行：

```text
python tooling/fetch_official.py https://mirrors.huaweicloud.com/harmonyos/compiler/hvigor/6.26.1/command-line-tools.zip
python tooling/fetch_official.py https://mirrors.huaweicloud.com/harmonyos/os/7.0-Release/ohos-sdk-windows_linux-public_20260829.tar.gz
python tooling/unpack_openharmony.py
```

下载工具按服务器 Range 续传并核对官方 SHA-256。源码中不会改写 SDK 清单；API 26 组件按自身 `platformVersion` 放入 `openharmony-sdk/26.0.0`。Hvigor ZIP 解压至 `command-line-tools`；它是公开镜像的跨平台 JavaScript 构建工具包，实际标注的发布版本与核验结果见 `docs/platform-environment.md`。原生工程构建入口为 `phone/harmony/tools/build.py`。

## 观察原生 ArkUI

先完成原生编译，使用其真实 `loader_out/default/ets` 与 `res/default` 目录。将匹配版本的 SDK `previewer` 完整目录复制到自己选择的 ASCII 路径；保留内部 `common/bin` 与 `common/resources` 相对关系。当前主机的中文运行路径会导致原生系统主题读取失败，桥接工具会拒绝此路径。

依赖可安装到独立 Python 环境：

```text
python -m pip install -r tooling/requirements-preview.txt
```

调用示例（路径按自己的构建位置替换）：

```text
python tooling/preview_native.py --previewer C:/HajiSakiBuild/previewer/common/bin/Previewer.exe --ets C:/HajiSakiBuild/harmony/entry/build/openharmony/intermediates/loader_out/default/ets --resources C:/HajiSakiBuild/harmony/entry/build/openharmony/intermediates/res/default --output C:/HajiSakiBuild/captures/hub.png --interactive
```

交互模式需要保留 stdin（通过统一执行工具调用时使用 `tty=true`）。它只接受 Previewer 的命令，不操作宿主键鼠。按已观察到的当前画面坐标逐次发送普通点击，例如：

```json
{"command":"MousePress","args":{"x":1120,"y":2737}}
{"command":"MouseRelease","args":{"x":1120,"y":2737}}
{"capture":"C:/HajiSakiBuild/captures/host.png"}
{"command":"exit"}
```

每次采集保存 Previewer 原始 JPEG 及同像素 PNG。SDK 在主机上模拟若干平台接口，布局、页面导航、主题变化可以观察，但不能据此证明真实网络请求、设备数据库、录音、指纹、系统实况窗、功耗或实机性能通过。截图和日志的实际结论见 `docs/platform-environment.md`。

需要在原生字段中输入文字时，可发送 `{"text":"普通公开文字"}`。若输入凭据，应从启动时启用 `--private-input`，再发送 `{"text_file":"C:/path/pairing.json","json_key":"token"}`；文件正文不会回显，可能包含输入字符的 SDK/管道日志也不记录。先通过原生点击聚焦正确的输入框，保持密码掩码，不能在显示明文密码时采集画面。ASCII 使用 Previewer 键事件；非 ASCII 输入法通道在当前 SDK 尚未证实可用。
