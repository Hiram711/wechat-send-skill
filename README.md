# wechat-send

往**本机**微信桌面端的某个会话发一条文本消息。不经任何第三方服务——不用企业微信机器人，不用服务号或 PushPlus 之类的推送网关，只驱动本机微信客户端。

这是一个 [Claude Code](https://claude.com/claude-code) skill，也可以当独立脚本直接跑。

## 它解决什么问题

想让程序给自己的微信发条消息，常规做法都要把内容送出本机（推送网关、机器人 webhook）。这个项目不出本机：发给「文件传输助手」等于发给自己，手机上立刻能看到。

代价写在明面上：发送瞬间会抢一下前台焦点，一条约 40 秒，**锁屏期间发不出去**（见下文）。

## 前置条件

| 要求 | 说明 |
| --- | --- |
| Windows | 实测 Windows 10/11，200% 缩放、2880x1800 |
| Windows PowerShell 5.1 | **不能用 PowerShell 7**，它加载不了 WinRT 的 OCR 类型 |
| 微信桌面版 4.x | 实测 4.1.13.65（`Weixin.exe`，Qt 5.15.14） |
| 中文 OCR 语言包 | 系统语言含中文即可，离线识别，不联网 |
| Python 3 | 只有 `tools/` 下的辅助脚本需要 |

微信必须处于已登录、非最小化状态，且目标会话名要和侧栏显示的完全一致。

## 用法

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/wx_send.ps1 -Target "文件传输助手" -Message "内容"
```

第一次对一个新会话发之前，先用 `-DryRun` 走完整流程但不按回车：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/wx_send.ps1 -Target "文件传输助手" -Message "内容" -DryRun
```

正文含换行、引号或大量中文时写进 UTF-8 文件再传路径，别往命令行里拼：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/wx_send.ps1 -Target "文件传输助手" -MessageFile "body.txt"
```

完整参数、退出码、排查手册都在 [SKILL.md](SKILL.md)。

## 装成 Claude Code skill

```bash
python tools/install_skill.py
```

只把 `SKILL.md` 注册进 `~/.claude/skills/wechat-send/`，并把脚本的绝对路径注入进去。刻意不改 `settings.json`、不注册 hook、不建计划任务。卸载用 `--uninstall`，预览用 `--dry-run`。

装完之后对 Claude Code 说「微信发给我」这类话就会触发。发送本身不需要安装任何东西，脚本可以直接跑。

## 它是怎么工作的

微信 4.x 是自绘界面，**没有 UIAutomation 树**，拿不到任何控件。所以只能纯靠屏幕：

前台化 → 整屏截图 → Windows 自带离线 OCR 认屏定位 → 合成鼠标键盘输入。

一条消息约 40 秒，绝大部分花在两三次 OCR 上。

## 安全边界

- **OCR 核对聊天标题**，标题不符就中止，且一个字都不输入。这道闸是防发错人的。
- **群聊标题的成员数后缀**（`项目组（5）`）单独放行，但正则两头锚死、括号里只认数字，不可能把另一个人的名字放进来。
- **`-KeepShots` 的截图含聊天内容**，看完立刻删。`.gitignore` 已经挡掉 `*.png` 和 `wx_send_shots/`。
- **排查工具默认挡掉左侧会话列表**（`tools/ocr_probe.ps1 -RightPanelOnly`），那里是私人聊天，不该倒进日志。
- **锁屏时返回退出码 8 而不是瞎按键**。屏幕锁了之后 Windows 不给任何程序操作桌面，也就是说人离开电脑的时候恰恰是这条路唯一做不到的时候。想锁屏也能送达只能接受消息出本机，那是另一个决定——调用方该做的是存起来等解锁补发。

## 已知限制

- 只支持简体中文界面的微信 4.x，其他版本和语言没测过，窗口类名和布局判据可能对不上。
- 多显示器、非 200% 缩放下几何判据是按窗口尺寸比例推导的（不是写死像素），但只在单屏 200% 上充分验证过。
- 发送期间不要动鼠标键盘，会和脚本抢焦点（这种情况返回退出码 3，稍后重试即可）。
- Windows OCR 对某些正文（纯重复单字、单个字、纯标点、纯表情）返回不了结果，脚本用像素判据兜底，详见 SKILL.md。

## License

MIT，见 [LICENSE](LICENSE)。
