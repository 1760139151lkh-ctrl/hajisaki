# 本地语音预处理

这是一个只处理明确指定音频文件的离线库与命令行入口，不监听麦克风、不调用付费 API、不自动下载模型。导入 `speech` 不加载模型。转写使用本地 CTranslate2 格式的 Whisper 模型；缺少模型或依赖时返回真实未配置状态，原音仍保留。

## 安装与运行

在项目根目录执行 `python speech/setup_environment.py`，将 `requirements.txt` 中的可选依赖装入项目 `.venv`。安装器使用隐藏的控制台子进程、参数数组和 UTF-8 日志。不会修改系统 Python。

设置 `HAJISAKI_SPEECH_MODEL` 为已有模型目录，或通过 `--model` 传入。目录必须含 `model.bin`、`config.json`、`tokenizer.json`、`preprocessor_config.json`、`vocabulary.json`。使用明确目录与 `local_files_only=True`，避免模型自动下载。

```text
.venv/Scripts/python.exe -m speech status
.venv/Scripts/python.exe -m speech --model <模型目录> transcribe <录音文件> --language zh
.venv/Scripts/python.exe -m speech --model <模型目录> transcribe <录音文件> --cleanup
.venv/Scripts/python.exe -m speech read <job_id>
.venv/Scripts/python.exe -m speech hotwords --import-file <词典.json>
.venv/Scripts/python.exe -m speech clean "嗯，先把这个问题记下来。"
```

默认数据目录 `runtime/speech` 可用 `--data-dir` 更改。GPU 是可选项：`--device cuda --compute float16`；默认 CPU/int8，未承诺 GPU 环境可用。库调用配置使用 `SpeechConfig`，也支持 `HAJISAKI_SPEECH_DEVICE` 与 `HAJISAKI_SPEECH_COMPUTE`。

网关使用项目内 `runtime/speech-settings.json`；当前指向用户持久 Hugging Face 缓存中的 large-v3 模型，约 3.09 GB，无需复制到 Codex 目录。迁移电脑后将 `model_path` 改为新电脑完整模型目录；环境变量优先于该文件。模型可以放在任意持久本地目录，不依赖 Codex 会话。

## 网关调用合同

```python
from speech import SpeechConfig, SpeechService

speech = SpeechService(data_dir, SpeechConfig(model_path=model_directory))
status = speech.status()
result = speech.transcribe_file(
    uploaded_audio_path,
    language="zh",
    cleanup=False,
    on_segment=publish_segment,
    cancel=cancel_event,
)
```

`transcribe_file` 是阻塞工作，应由网关分派到工作线程或独立进程，不能占用 HTTP 事件循环。large-v3 模型占用数 GB 内存，推荐单独的短期工作进程；不能把它算入网关 180 MB 常驻目标。`unload()` 可释放本实例模型。

返回字段：

- `id/status`：任务 ID 与 `completed/cancelled/failed/unconfigured/dependency_missing` 等实际状态。`status()` 的 `configured` 只表示文件与依赖齐全，`loaded` 表示模型已装入内存，不冒充实测成功。
- `original_audio`：原文件名、SHA-256、字节数和相对数据目录的 `retained_path`。网关应将它映射为鉴权附件下载地址，不向手机暴露本机路径。
- `original_text/text`：原始转写与用户明确开启清理后的文本。默认相同。
- `segments`：真实片段起止秒数、文本、`avg_logprob/no_speech_probability` 和模型返回的词时间戳、词概率。
- `uncertain_spans`：模型词概率低于默认 0.70 的片段；阈值是界面提示策略，不是准确率保证。没有模型概率时不编造。`candidates` 为空，因为该后端不返回声学 N-best 候选。
- `dictionary_suggestions`：仅来自用户填写的 `aliases`，明确标记 `source=user_dictionary`，不自动替换，也不伪装成音近词 Top-3。
- `cleanup`：保留原文、清理结果和每项编辑位置。只去除独立的嗯、呃与 um/uh/erm；为避免删掉语义，不自动移除“那个”“额外”等词。

所有字符偏移以 `original_text` 的 Unicode 码点为基准；JavaScript/ArkTS 在含非 BMP 字符时需转为 UTF-16 索引。清理后的文本位置不能直接使用原文偏移。

词典是最多 100 项的 JSON 数组，每项 `{"term":"规范写法","aliases":["常见误识别"]}`。规范词作为模型热词提示；提示不保证转写一定采用该词。可以 `set_hotwords(entries)` 保存、`hotwords()` 读回。

每个任务先保留完整原音，随后逐段 `fsync` 写入 `segments.jsonl`，结束写 `result.json`。`read_job(id)` 可读回未完成任务的已落盘片段，返回 `incomplete`，不将“没有最终结果”擅自推断为进程崩溃。失败诊断留在本机 `diagnostic.json`，不出现在面向用户的回复字段。模块没有删除命令。

## 鉴权 HTTP 接口

`host/hajisaki/speech_routes.py` 通过现有 Bearer 与设备绑定鉴权，所有音频都必须先上传到既有 CAS 文件柜。请求只能指定 `artifact_id`，不能传入主机路径。

| 接口 | 输入或返回 |
| --- | --- |
| `GET /api/speech/status` | 配置状态、真实队列、单工作进程限制与能力声明 |
| `GET /api/speech/hotwords` | `{hotwords:[{term,aliases}]}` |
| `PUT /api/speech/hotwords` | 保存同形词典，不自动改变转写 |
| `POST /api/speech/transcriptions` | `{artifact_id,language?,cleanup?}`；202 返回直接任务对象 |
| `GET /api/speech/transcriptions/{id}` | 原音附件地址、实际片段、文本与任务状态 |
| `POST /api/speech/transcriptions/{id}/stop` | 停止所属工作进程，保留原音与已落盘片段 |
| `POST /api/speech/clean` | `{text}`；返回原文、清理结果与逐项修改 |

一个隐藏的 Python 工作进程执行一项任务，最多 16 项排队；没有为正常推理设置强制时限。进度是已经落盘的片段数与真实音频时间，不生成虚假百分比。停止接口实际终止工作进程；关闭网关会停止所属进程，未开始的队列可在下次启动继续。工作进程监测其父网关实际退出后自行结束，避免留下失去管理的模型进程。

`build_speech_router(config, artifacts, authenticate)` 返回 `(router, manager)`。网关在生命周期开始调用 `await manager.start()`，结束调用 `await manager.close()`。`manager.export_entries()` 只提供用户词典、原音及转写文件，排除机器路径配置与诊断日志，供全库导出使用。

## 当前界限

支持 WAV、MP3、OGG/Opus、M4A/MP4、AAC、FLAC、WebM 的音轨，单文件默认最多 512 MiB、30 分钟；限制可通过 `SpeechConfig` 显式调整。解码逐帧检查实际样本数，最终将受限的单声道 16 kHz 音频交给 Whisper。多小时流式分块尚未实现，不能宣称任意时长内存恒定。

这是文件转写，不是 350 ms 麦克风实时转写；取消在模型片段之间生效，不承诺 50 ms。没有说话人分离、声纹克隆、音近词 Top-3 或把原音送入文本聊天模型的能力。语音理解准确率与地铁/方言/中英混说指标仍需实际评测。

接口依据 [faster-whisper 官方文档](https://github.com/SYSTRAN/faster-whisper) 与[实现源码](https://github.com/SYSTRAN/faster-whisper/blob/master/faster_whisper/transcribe.py)：词级时间戳、概率、热词与本地模型路径都沿其真实接口使用。
