# 哈基祥 · 界面设计语言：公主的小客厅

手机端（`studio/`，即 Android APK 与电脑控制台共用的界面）和 iPad（`ipad/App/Sources/Views/TheaterTheme.swift`）用的是同一套设计语言。鸿蒙工程的 `phone/harmony/entry/src/main/ets/design/Theme.ets` 只同步了色值。离线富文本的色值在 `studio/src/frame.css`；改动任何一端的色值，都要同步更新其余几处，并重建 iPad 的 `Renderer/renderer.css`。

## 气质

像一位大小姐的私人小客厅：瓷白与珍珠、玫瑰与古金，有祥子的藏青缎带、小小的冠冕、火漆封印的爱心，还有金色花饰。华丽，但始终克制：

- 版式沿用“信笺”结构，留白充足，用细线分隔，不加厚重阴影。
- 装饰只用细金线和少量小图形，不用虚线描边、糖果渐变或贴纸。
- 玫瑰色承担主要操作和心意时刻；她的发色长春花蓝只留给链接。
- 祥子的声音用衬线体；短句拉丁文签名用花体；你的内容用无衬线体。

## 色值

| 角色 | 春日（昼） | 月下（夜） | 用途 |
| --- | --- | --- | --- |
| background | `#FBF4F1` | `#17131F` | 页面（叠一层极淡的爱心与星芒织纹） |
| raised / pearl | `#FFFCFA` | `#211B2B` | 卡片、对话框、输入框 |
| sunken | `#F5E8E6` | `#2B2337` | 代码块、未激活的发送键 |
| ink | `#2E2638` | `#F3E9E4` | 正文 |
| muted / dim | `#6C5F75` / `#8D7F93` | `#BBADB7` / `#8E8098` | 次要文字 / 时间等辅助信息 |
| rose | `#B8506F` | `#EDA3B9` | 爱心、选中、她的名字 |
| 缎面玫瑰按钮 | `#C25D7E → #A9466A`，白字 | 同左 | 主要操作 |
| 火漆 | `#D77D9A → #B8506F → #8C3350` | 同左 | 寄出、写信入口、品牌印 |
| gold | `#A8844C` | `#E3C48E` | 花体字、冠冕、编号 |
| 金线 | gold 42% / 20% | gold 38% / 16% | 镶边、分隔、花饰 |
| ribbon | `#2F2A45` | `#575073` | 她的发带 |
| bubble | `#F6E1E5` | `#352840` | 你的话 |
| blue | `#4F68AE` | `#B6C4F1` | 链接 |

对比度按 WCAG 公式计算：昼间正文 13.3:1、次要文字 5.5:1、链接 4.9:1；夜间正文 15.3:1。缎面按钮白字在 `#A9466A` 一端为 5.6:1，在浅端 `#C25D7E` 为 4.1:1，所以按钮文字用 15px 中粗。昼间古金在瓷白底上只有 3.2:1，只用于花体签名、冠冕、编号等大号装饰，不承载 12px 小字；小字统一用 muted。

## 字体

- **衬线**：Noto Serif SC Medium 子集（Haji Serif，iOS 字体名 `NotoSerifSC-Medium`），覆盖 GB2312 一级字与界面里出现的全部字符。
- **花体**：Pinyon Script（Haji Script，iOS 字体名 `PinyonScript-Regular`），只用于金色的短句拉丁文：
  - 首页问候 *Good morning / Good afternoon / Good evening / Sweet dreams*
  - 小纸条落款 *— Sakiko*
  - 页面小标题 *Little things about you*、*Treasures*、*Just for you*
  - 空对话上方的 *Only for you*
  - 静谧阅读的落款 *Sakiko*

  不要用它写中文。
- 两种字体都按 SIL OFL 1.1 随包分发，授权文本放在字体旁边。界面文字有改动后，重新运行 `assets_pipeline/subset_ui_font.py`。

## 母题

- **拱窗肖像**：首页把窗边的祥子放进半圆拱顶的珍珠画框（7pt 衬边加一道金线）。她的藏青缎带蝴蝶结停在拱顶上，金色虚线缝迹取自原画发带，轻轻左右摇摆（±2°，7 秒一个来回；开启“减弱动态效果”后静止）。
- **冠冕**：一顶小小的金冠，戴在 `祥` 字火漆印上（品牌），也跟在消息里她的名字后面。
- **火漆心**：寄出键和“写信给祥子”入口都是一枚压着象牙色爱心的玫瑰火漆；没写内容时，寄出键退成素色圆。
- **字母圆章**：信笺列表里，每封信前有一枚珍珠圆章，用衬线写出标题的第一个字（跳过标点）；置顶的信在右上角别一颗小心。
- **金框卡片**：她的小纸条、记忆、设置里的在线状态卡，都是外镶一道金线、内侧再一道浅金线；小纸条底边是蕾丝花边。
- **花饰分隔**：金色卷草细线，中间一颗玫瑰色小心。用在小纸条、信笺标题、对话框标题和空状态上方。

## 交互细节

- 手机用底部导航；进入聊天后收起导航，只留下你和她的对话。Android 返回键先关闭弹出的面板，再回到琴房首页。
- 新乐章的空白页提供几句起笔；点了只放进草稿，不会自动寄出。
- 头像会随状态换表情：写回信时托腮，回完开心一下，断线时担心，深夜捧茶，凌晨犯困。
- 只有新出现的内容才播放入场动画（Android 端每 850ms 轮询一次，不能让整页反复闪动）；所有动效都遵循系统的“减弱动态效果”。

## iPad

iPad：令牌与组件集中在 ipad/App/Sources/Views/TheaterTheme.swift（TheaterPalette、WaxSeal/WaxHeart、SakiSeal、TiaraMark、RibbonBow、MonogramRoundel、ArchedPortrait、FiligreeDivider、ScriptLine、letterCard）。字体随包放在 App/Resources/Renderer/fonts，并在启动时由 TheaterFonts.register() 注册；Renderer 是文件夹引用，所以不需要改工程。侧栏对应手机首页：花体问候、衬线寒暄、日期与在线点、封蜡心形写信入口、带字母圆章的信笺列表。iPad 的全局 tint（滑杆、开关、进度）、文字操作（“完成”“重新写”“引用到草稿”“复制”等）和选中态都用玫瑰色，与手机端 `.text-button` 一致；长春花蓝只留给消息里的链接和 Pencil 悬停光晕。
