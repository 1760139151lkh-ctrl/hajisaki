# 模型与思考强度选择

已按用户反馈把同一模型的Low/Medium/High等档位合并到模型名称下，避免把强度当作不同模型。模型列表在随日夜主题变化的底部面板中滚动，高度为屏幕45%；独立思考强度面板为260vp。聊天输入区和同题对照使用同一个组件。

模型家族及可选强度来自现有实际目录，未虚构额外档位。旧接口中的带档位ID仍作为内部请求标识保留，保证已有待发请求与幂等记录兼容；界面只呈现模型名称与单独的强度。对照可以选择同一模型、不同强度，也可选择不同模型。

已实际查看425vp浅色、夜间、320vp窄屏的模型面板，完成模型选择及“中→低”切换，模型名仍为Gemini 4 Argon。浅色对照设置实际选择了两份Gemini 4 Argon，分别低与中。原始图：native-model-families-day.png、native-model-families-night-first.png、native-model-families-compact.png、native-model-strength-night.png、native-family-strength-low-selected.png、native-second-family-changed.png。均在tooling/evidence/。

普通与临时预览API26编译通过，发布包与228份实际构建输入一致，字节码已读回；记录runtime/branch-model-picker-release-verification.json。

- 普通未签名诊断HAP：64279942字节，SHA256 e44503d9c88dcde4a112b7dc974c247b7d73922eb99231a4757dca47fc94f22f。
- 临时预览HAP：64280782字节，SHA256 d260ba677b61050b33e768bcd820bc92c526538975e3567f3f900a5b4e5af9a9。

本次选择器修正已有实际界面操作证据；对照双方真实生成、投票及真机签名安装不由这些截图或编译结果证明，继续以验收台账为准。
