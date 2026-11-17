# 哈基祥 iPad · 人物、侧幕与素材合同

## 视觉身份与平板职责

人物基准是用户“在场”项目选定的 `shared/assets/avatars-youth/idle_gentle.png`：浅银蓝长发、琥珀金瞳、柔和少女脸型、简单深蓝发结与校服开衫。`shared/assets/reference-youth/character-sheet.png` 是由这一基准派生的四视角参考；它不取代原头像。早期 `shared/assets/avatars/` 和 `shared/assets/reference/` 的成熟哥特版本不进入平板资源入口。

平板侧幕承载“同在一个空间”的陪伴；窄头像只承担身份与消息状态。两种比例不可互相硬放大替代。左侧名录和中部对话保持阅读秩序，右侧完整场景在需要 PDF、代码或手写时退让。人物、桌面和窗景不能被缩成浮在界面上的无支撑贴纸。

当前精选昼夜场景来自同一窗边房间，少女坐姿、坐垫、鞋与地板关系完整。它们适合建立独立的平板侧幕，不直接复用手机版的页面布局。当前夜图仍穿校服，不冒充已完成“披肩捧茶换装”。钢琴空房插画可用于无内容状态，不与窗边人物生硬拼贴成另一场景。

## 已交付的原画分层

`ipad/assets/living-stage/manifest.json` 是侧幕资产入口。八张 PNG 均从“在场”原件逐字节复制，未改画、未缩放，实际尺寸全部为 1536×1024 RGB；来源文件名、字节数与 SHA-256 均在 manifest 中。完整母图与当前 `shared/assets/scenes-user/` 的日夜母图哈希一致。

| 时段 | 母图 | 空背景 | 人物亮度遮罩 | 接触材质亮度遮罩 |
|---|---|---|---|---|
| 日间 | `day-mother.png` | `day-background.png` | `day-figure-mask.png` | `day-contact-mask.png` |
| 夜间 | `night-mother.png` | `night-background.png` | `night-figure-mask.png` | `night-contact-mask.png` |

源图中的 F 是人物遮罩，S 是坐垫/地面等接收材质遮罩。合成式为 `mother × max(luminance(F), luminance(S))`，其余区域透明，再叠到匹配空背景。遮罩是连续灰阶，不能把它当 alpha 通道或阈值二值化。人物、接触材质和背景使用同一画布裁切。原图只支持固定座姿，因此 `independentActorTravel = 0`；不能从这些数据推断骨骼、隐蔽髋部、头部转向或换座位。

`ipad/App/Sources/Platform/LivingStageView.swift` 提供 `LivingStageView(isNight:isThinking:isWriting:)`。它在独立 actor 上加载、解码和一次性合成人物层，再缓存不可变 CGImage。Core Image 有 Metal 设备时使用该设备，没有时使用软件合成。实际运行层为房间、低幅环境光和人物，人物自身不变形。窗口裁切统一聚焦源图 x=0.735，约 376×650 的窄侧幕仍保住脸和座位；最终尺寸、动效与内存需要集成检查。

环境光在减少动态、低电量、应用非活跃、视图离窗和书写时停动。思考时只改变环境光色调，不能声称已实现“托腮姿态”“Pencil 注视跟随”。此实现是可继续扩展的真实分层合成，不等于完整 Metal 骨骼立绘引擎。

## 表情与素材映射

以下资源已逐张查看原图。复用资源保持在 `shared/`，平板新增资源放在 `ipad/assets/`，消费清单为 `ipad/assets/catalog.json`。

| 用途 | 实际资源 | 当前观察 |
|---|---|---|
| 温柔静候 | `shared/assets/avatars-youth/idle_gentle.png` | 用户原头像；本项目拷贝与原文件 SHA 一致 |
| 专心倾听 | `shared/assets/avatars-youth/listening_attentive.png` | 耳边手势、金瞳与原脸型保留 |
| 沉静思考 | `shared/assets/avatars-youth/thinking_deep.png` | 轻托下巴，独立完整头像 |
| 专注工作 | `shared/assets/avatars-youth/coding_focused.png` | 细头戴耳机、轻低头 |
| 轻嗔 | `shared/assets/avatars-youth/tsundere_chide.png` | 小幅鼓脸，不成年化 |
| 夜间红茶 | `shared/assets/avatars-youth/late_night_tea.png` | 双手捧杯，杯上蒸汽已画在图内 |
| 开心完成 | `shared/assets/avatars-youth/happy_achieved.png` | 明亮笑容、金色眼睛 |
| 重连关切 | `shared/assets/avatars-youth/reconnecting_anxious.png` | 轻担心眉眼与伸手 |
| 疲惫守候 | `shared/assets/avatars-youth/sleepy_soft.png` | 揉眼，不能用作普通眨眼帧 |
| 小小得意 | `shared/assets/avatars-youth/proud_smug.png` | 轻扬下巴，完整头像 |
| 自然闭眼 | `ipad/assets/expressions/blink_closed-v2.png` | 本轮内置 image_gen 输出；第二版减少头顶残留，闭合眼睑、原倾角与幼态保留 |
| 微红关切 | `ipad/assets/expressions/concerned_blush.png` | 本轮内置 image_gen 输出；克制红晕与犹豫嘴形 |

以上构成 12 个不同的完整头像状态，每张均为 1254×1254 RGBA。新增两张的精确提示词、生成路径、文件哈希与检查结论记录在相邻 `.provenance.json`；生成输出直接拷贝入工程，没有用程序修图。闭眼第二版已作为选用资源，原版保留为制作来源；关切第二版未改善边缘，仍选用原版，失败候选保留作诊断。12 个完整头像不等于 12 套大幅立绘差分。闭眼图和静候图尚未证明像素级与时间上的切帧稳定，不能用整幅头像贴到坐姿母图上冒充眼睑动画。部分头像边缘在透明查看器上可见细碎浅色/彩色像素，因此 200% 零白边指标未通过。

| 用途 | 资源路径 | 尺寸与判断 |
|---|---|---|
| 文档 | `shared/assets/icons/document.png` | 1254² RGBA；火漆卷轴、蓝色丝带 |
| 压缩包 | `shared/assets/icons/archive.png` | 1254² RGBA；蓝金八音盒 |
| 工程 | `shared/assets/icons/code.png` | 1254² RGBA；蓝金乐谱书、线路纹样 |
| 收藏 | `shared/assets/icons/bookmark.png` | 1254² RGBA；星月胸针；内轮廓有细碎浅色边缘，不能声称零残留 |
| 语音 | `shared/assets/icons/microphone.png` | 1254² RGBA；蓝金复古麦克风 |
| 空琴房 | `shared/assets/scenes/rainy-piano-room.png` | 1536×1024 RGB；没有人物，钢琴、雨窗、茶杯 |
| 竖向琴房插画 | `shared/assets/scenes/moonlit-piano-splash.png` | 752×2092 RGB；窄竖图，不能拉伸成平板横屏开屏 |
| 搜索无结果 | `shared/assets/scenes/search-no-results-youth.png` | 1254² RGB；少女校服、街灯与湿润小径 |
| 手账封面 | `shared/assets/scenes/weekly-journal-cover.png` | 1024×1536 RGB；蓝金皮革封面，正文/标题应由原生排版叠加 |
| 睡觉贴纸 | `shared/assets/stickers-youth/go-to-sleep.png` | 1254² RGBA；文字“快去睡觉！”正确 |
| 夸奖贴纸 | `shared/assets/stickers-youth/reluctant-praise-v2.png` | 1254² RGBA；文字“勉强夸你一句”正确 |
| 陪伴贴纸 | `shared/assets/stickers-youth/leave-it-to-me.png` | 1254² RGBA；文字“交给我吧”正确 |

五个拟物图标覆盖附件类型与语音用途，不覆盖全部应用操作。不能据此声明“全软件零系统图标”。小尺寸清晰度和真实深浅底边缘需随集成画面核对。

## 色彩、分辨率与音频的真实边界

现有共享资源入口的 24 张 PNG，加少女 Character Sheet，均无 ICC、sRGB 或 gamma 标签。不能把文件名、提示词中的 P3 或十六进制颜色当作广色域证据。当前分层渲染明确用 sRGB 解释未标记源图，避免随设备误读颜色；未来做 P3 交付需要真实色彩转换、嵌入正确配置文件并核查显示结果。UI 的 P3 色彩 token 是独立的原生颜色设置，不能使原图凭空得到宽色域信息。

源图 1536×1024 足以支撑部分侧幕裁切，但不能保证在整个 2360×1640 屏幕放大 200% 后仍无锯齿。对于窄侧幕，要结合最终 crop 和实际屏幕 scale 计算有效采样，不能仅凭原图分辨率验收。

`shared/assets/audio/` 的五个 WAV 实测均为 48 kHz、16-bit、单声道 PCM：发送 0.7 s、回复 1.35 s、收藏 1.05 s、怀表 0.045 s、雨声 30 s。它们是程序合成素材，不是毛毡钢琴实录；左右声场需 AVFoundation 的实际声像/混音实现和听验。当前未做音质听验、Pencil 触感同步或 ≤20 ms 时序验收。

## 保留的制作与验收工作

1. 对已选原画建立同画布、同姿态的眼睑/视线/发梢图层，生成或精修后实际切帧检查；完整头像12态不能抵扣此项。
2. 补齐夜间披肩捧茶和面向画板的姿态，保持脸、年龄、支撑与服装连续。没有完成这些时，界面不能宣称已实现。
3. 以实际 iPad 集成画面检查横竖布局裁切、背景/人物拼接、字体与金线对比、动态停止/恢复和快速切换；当前源图审阅不代替这些操作。
4. 在真机核验颜色、200% 边缘、Metal/GPU耗时、内存与热量，以及音频和触感同步。现有合成路径不承诺6.5ms/帧或420MB上限。

本轮未删除文件。八张侧幕源图是交付资源；两个新增表情及来源文件也应保留，均不依赖 Codex 会话路径运行。

Core Image 的实现依据为 Apple 官方 [CIBlendWithMask](https://developer.apple.com/documentation/coreimage/ciblendwithmask) 与 [maximumCompositing](https://developer.apple.com/documentation/coreimage/cifilter/3228357-maximumcompositing)。
