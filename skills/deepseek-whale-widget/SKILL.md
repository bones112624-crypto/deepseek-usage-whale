---
name: deepseek-whale-widget
description: DeepSeek 余额小鲸鱼挂件。当用户想看 DeepSeek 余额、今日花了多少、最近一轮对话花了多少，或者想把小鲸鱼挂件放出来 / 调大小 / 换音效时使用。
---

# DeepSeek 小鲸鱼挂件

从 DSH 版 [DeepSeek-Balance-Whale-Widget](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget) 移植到 Windows 桌面的余额挂件：小鲸鱼立绘 + 对话气泡，显示余额、今日已用和每轮对话消耗。

## 外观与交互（与上游一致）

- **小鲸鱼立绘**：cut-out PNG，位于挂件右下角，占宽度 59.45%
- **对话气泡**：代码绘制（大椭圆 + 尾巴 + 两个小气泡），描边 `#203170`，白底，内部四行文字
  - 主行 `DeepSeek 余额`（66u / 600）
  - 金额（128u / 800，颜色 `#536ba9`）
  - 提示行 `今日已用 ¥X`（56u，颜色 `#9fb0d9`）
  - 缓存行 `上轮命中 N%`（56u，颜色 `#9fb0d9`），取自最近一轮对话的真实 usage；每轮消耗气泡的第三行显示同一个值。注意它只算最近一轮，与用量监控面板上的当日缓存命中率口径不同
- **右键**：直接打开 DeepSeek 用量监控面板（默认 `http://127.0.0.1:8788`）。只启动面板服务本身，不会顺带拉起悬浮球；面板服务用 `wscript` + VBS（window style 0）启动，node 的控制台窗口是隐藏的，桌面上不会多出黑窗口
- **拖拽 + 四边四分之一吸附**：中心点落在视口 1/4 区间就吸附该边，横纵独立、可组合成角落
- **左吸附镜像翻转**：整体水平镜像，文字反向镜像回来保持可读
- **按压 Q 弹**：`scaleY(0.88) scaleX(1.05)`，锚点底边中心，0.22s 过冲回弹
- **余额数字滚动**：700ms ease-out，仅在余额实际变化时触发
- **随机台词气泡**：点击鲸鱼弹出 → 再点切随机台词 → 再点关闭；总时长 5 秒自动收起
- **音效**：按压/松手，可选「小黄鸭」(Ya1/Ya2) 或「音效1」(D1/D2)
- **汉堡菜单**：大小 0.6–2.5、音效、音量、用量模式、气泡开关、每轮消耗开关与自动关闭秒数

60 秒自动刷新余额；瞬时网络失败沿用最近值不闪错误。

## 数据来源

| 数据 | 来源 | 真实性 |
| --- | --- | --- |
| 账户余额 | DeepSeek `GET /user/balance` | 真实值 |
| 今日已用 | 余额差值本地记账（`usage.json`），跨天归档 30 天 | 近似（DSH 关闭期间的消耗会漏记） |
| 每轮对话消耗 | **Codex 会话日志里的 `token_usage_record`** | **真实 usage** |

每轮消耗是移植时改进的地方：上游监听 DSH 的会话事件，这里直接读 Codex 自己写的会话日志，同样是精确 token 数，不依赖任何事件钩子。金额按**官方峰谷单价**换算（工作日北京时间 9:00–12:00、14:00–18:00 为高峰，周末全天谷价）。

凭据解析顺序：`DEEPSEEK_API_KEY` 环境变量 → `~/.codex/config.toml` 里 DeepSeek provider 的 `experimental_bearer_token`。后者让挂件开箱即用。

## 工具

| 工具 | 用途 |
| --- | --- |
| `whale_balance` | 余额 + 今日已用 + 当前是否高峰 |
| `whale_last_turn` | 最近一轮对话消耗（真实 usage） |
| `whale_widget` | 启动桌面挂件 / 查运行状态 |

## 命令行

```powershell
$CLI = "$env:USERPROFILE\plugins\deepseek-whale-widget\scripts\whale.mjs"
node $CLI balance        # 余额
node $CLI today          # 今日已用
node $CLI last-turn      # 上一轮消耗
node $CLI start          # 放出挂件
node $CLI status         # 状态
```

## 随 Codex 启停

挂件默认由 `widget/whale-follow.ps1` 守护：Codex（桌面版 `ChatGPT.exe`，路径含 `OpenAI.Codex_`）
一起来就放出小鲸鱼，Codex 一退出就把它优雅收掉。收起走停止信号，位置与配置都会被保存。

```powershell
$FOLLOW = "$env:USERPROFILE\plugins\deepseek-whale-widget\widget\whale-follow.ps1"
powershell -File $FOLLOW -Action status   # 守护状态
powershell -File $FOLLOW -Action stop     # 收起（下次启动 Codex 自动恢复）
powershell -File $FOLLOW -Action start    # 独立模式：不依赖 Codex
```

桌面「DeepSeek 小鲸鱼挂件」快捷方式走的就是 `-Action start`（独立模式，不会被 Codex 退出牵走）。

## 硬性要求

- 不要在回复里打印完整 API key，需要提及时用掩码形式。
- **余额和每轮消耗是真实值；今日已用是余额差值记账的近似值**，转述时保持这个区分。
- 面板/挂件启动是 Windows 专用（PowerShell + WinForms 分层窗口）；CLI 与 MCP 跨平台。
- 立绘、gif、音效来自上游 MIT 许可的素材，改动外观时保留 `LICENSE`。
