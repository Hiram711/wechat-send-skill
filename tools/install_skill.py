# -*- coding: utf-8 -*-
"""把 wechat-send 的 SKILL.md 注册进 ~/.claude/skills/，并规范化 .ps1 编码。

刻意只做这两件事：不改 settings.json、不注册 hook、不建计划任务。
发送本身不需要安装任何东西，脚本可以直接跑；这里做的只是让 Claude Code
能自动发现这个技能。

用法:
    python tools/install_skill.py [--dry-run]
    python tools/install_skill.py --uninstall [--dry-run]
"""
import argparse
import os
import sys
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL_SRC = os.path.join(ROOT, "SKILL.md")
SKILL_NAME = "wechat-send"          # 要和 SKILL.md frontmatter 的 name 一致
SKILL_DST_DIR = os.path.join(os.path.expanduser("~"), ".claude",
                             "skills", SKILL_NAME)
SKILL_DST = os.path.join(SKILL_DST_DIR, "SKILL.md")
PS_DIRS = ["scripts", "tools"]


def fix_encodings(dry):
    """PowerShell 5.1 的硬要求：CRLF + 单个 UTF-8 BOM。缺 BOM 时中文会乱码。"""
    if dry:
        n = sum(len([f for f in os.listdir(os.path.join(ROOT, d))
                     if f.lower().endswith(".ps1")])
                for d in PS_DIRS if os.path.isdir(os.path.join(ROOT, d)))
        return "将检查 %d 个 .ps1" % n
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import fix_ps1_encoding as fx
    n = 0
    for d in PS_DIRS:
        p = os.path.join(ROOT, d)
        if not os.path.isdir(p):
            continue
        for fn in sorted(os.listdir(p)):
            if fn.lower().endswith(".ps1"):
                fx.fix(Path(os.path.join(p, fn)))   # fix() 要 Path，不能传 str
                n += 1
    return "已规范化 %d 个 .ps1" % n


def install_skill(dry):
    """正文里写的都是相对本项目根目录的路径，所以复制过去之后要在开头补一行
    绝对路径，否则换个工作目录就找不到脚本了。"""
    if not os.path.exists(SKILL_SRC):
        return "跳过：SKILL.md 不存在"
    with open(SKILL_SRC, encoding="utf-8") as f:
        text = f.read()
    end = text.find("\n---", 4)
    if end < 0:
        return "跳过：SKILL.md 没有合法的 frontmatter"
    end = text.find("\n", end + 1) + 1
    note = ("\n> 本技能的脚本在：`%s`\n> 下面所有相对路径都相对这个目录。\n"
            % ROOT)
    text = text[:end] + note + text[end:]
    if dry:
        return "将写入 %s（%d 字节）" % (SKILL_DST, len(text.encode("utf-8")))
    os.makedirs(SKILL_DST_DIR, exist_ok=True)
    with open(SKILL_DST, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return "已写入 %s" % SKILL_DST


def remove_skill(dry):
    if not os.path.exists(SKILL_DST):
        return "跳过：%s 不存在" % SKILL_DST
    if dry:
        return "将删除 %s" % SKILL_DST
    os.remove(SKILL_DST)
    try:
        os.rmdir(SKILL_DST_DIR)      # 只在空目录时成功，不误删用户别的东西
    except OSError:
        pass
    return "已删除 %s" % SKILL_DST


def main():
    ap = argparse.ArgumentParser(description="安装/卸载 wechat-send 技能文件")
    ap.add_argument("--dry-run", action="store_true", help="只打印，不改任何文件")
    ap.add_argument("--uninstall", action="store_true")
    a = ap.parse_args()

    print("项目根目录 : %s" % ROOT)
    if a.uninstall:
        print("技能文件   : %s" % remove_skill(a.dry_run))
        print("\n注：本脚本从不碰 settings.json，所以没有 hook 需要摘除。")
        return
    print("编码规范化 : %s" % fix_encodings(a.dry_run))
    print("技能文件   : %s" % install_skill(a.dry_run))
    if not a.dry_run:
        print("\n完成。技能文件下次启动 Claude Code 会话时生效。")
        print("直接发一条试试（DryRun 只粘贴不回车）：")
        print('  powershell -NoProfile -ExecutionPolicy Bypass -File '
              '"%s" -Target "文件传输助手" -Message "测试" -DryRun'
              % os.path.join(ROOT, "scripts", "wx_send.ps1"))


if __name__ == "__main__":
    main()
