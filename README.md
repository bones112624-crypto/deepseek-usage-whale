# DeepSeek 小鲸鱼挂件

屏幕角落的一只小鲸鱼，盯着你的 DeepSeek 余额、今日已用、每轮对话消耗和缓存命中率。

挂件原作是 B 站 UP 主 **月匠** 的小鲸鱼余额挂件，这里是它的 Windows 桌面移植版，做成了 Codex 插件。

<p align="center"><img src="assets/DSniang1.png" width="180" alt="小鲸鱼"></p>

## 它显示什么

| 内容 | 说明 |
| --- | --- |
| 账户余额 | DeepSeek 官方接口，真实值，60 秒自动刷新 |
| 今日已用 | 余额差值本地记账，跨天归档 30 天（近似值） |
| 上轮缓存命中率 | 最近一轮的命中输入 ÷（命中 + 未命中），来自真实 usage |
| 每轮对话消耗 | 读 Codex 会话日志里的 token 用量，按官方单价换算，真实值 |

金额按 DeepSeek 官方峰谷单价计算：北京时间工作日 9:00–12:00 与 14:00–18:00 为高峰，其余时段和周末按空闲价。

## 交互

- **左键**：拖拽移动，松手吸附到最近的边或角；单击弹出气泡，再点切换随机台词
- **右键**：直接打开 DeepSeek 用量监控面板。只启动面板服务本身，不会顺带拉起悬浮球
- **汉堡菜单**：大小、音效、音量、用量模式、气泡开关、每轮消耗开关

按压有 Q 弹反馈，余额变化时数字滚动；吸附到左边时整体水平镜像，文字反向镜像回来保持可读。

## 随 Codex 启停

`widget/whale-follow.ps1` 是生命周期守护：Codex 启动就放出挂件，Codex 退出就把它收掉。注册登录自启的计划任务即可：

```powershell
powershell -ExecutionPolicy Bypass -File setup-deepseek-whale-follow.ps1
```

不想跟随 Codex 时也可以用桌面快捷方式单独启动（独立模式）。

## 安装与使用

把本目录放到 `%USERPROFILE%\plugins\deepseek-whale-widget`，在 Codex 里启用即可。命令行入口：

```powershell
$CLI = "$env:USERPROFILE\plugins\deepseek-whale-widget\scripts\whale.mjs"
node $CLI balance     # 余额
node $CLI today       # 今日已用
node $CLI last-turn   # 上一轮对话消耗
node $CLI start       # 放出挂件
node $CLI status      # 运行状态
```

凭据优先读 `DEEPSEEK_API_KEY` 环境变量，其次读 `~/.codex/config.toml` 里 DeepSeek provider 的 `experimental_bearer_token`，装好即可用。API key 不会写进任何数据文件。

## 出处与许可

- **挂件原作：B 站 UP 主 月匠**
- 本仓库是它的 Windows 桌面移植版；移植所依据的开源代码来自 [MeteorNOX/DeepSeek-Balance-Whale-Widget](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)
- 立绘 `DSniang1.png`、动图 `rua.gif` 与 4 个音效文件沿用原素材，未做改动
- 以 MIT 许可发布，见 [LICENSE](LICENSE)；原始版权声明为 Copyright (c) 2026 MeteorNOX
