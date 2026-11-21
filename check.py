#!/usr/bin/env python3
# 静态自查：括号平衡 / 块配对 / 文件引用 / 常量一致性
import os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC_DIRS = [os.path.join(ROOT, "Sources"), os.path.join(ROOT, "prefsapp")]
EXTS = (".h", ".m", ".xm", ".mm")

errors = []
warnings = []

def strip_code(text):
    """去掉字符串字面量和注释，只留骨架"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        # 行注释
        if c == "/" and i + 1 < n and text[i+1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        # 块注释
        if c == "/" and i + 1 < n and text[i+1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i+1] == "/"):
                i += 1
            i += 2
            continue
        # 字符串
        if c == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        # 字符字面量
        if c == "'":
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == "'":
                    i += 1
                    break
                i += 1
            out.append("'x'")
            continue
        out.append(c)
        i += 1
    return "".join(out)

files = []
for d in SRC_DIRS:
    if not os.path.isdir(d):
        continue
    for f in sorted(os.listdir(d)):
        if f.endswith(EXTS):
            files.append(os.path.join(d, f))

print("=== 检查文件 ===")
for f in files:
    print("  ", os.path.relpath(f, ROOT))
print()

# 1) 括号平衡
for f in files:
    raw = open(f, encoding="utf-8", errors="replace").read()
    code = strip_code(raw)
    for open_c, close_c in [("{", "}"), ("(", ")"), ("[", "]")]:
        o, c = code.count(open_c), code.count(close_c)
        if o != c:
            errors.append(f"{os.path.relpath(f, ROOT)}: 括号 {open_c}{close_c} 数量不等 {o} vs {c}")

# 2) ObjC 块配对
for f in files:
    code = strip_code(open(f, encoding="utf-8", errors="replace").read())
    ib = len(re.findall(r"@interface\b", code))
    impl = len(re.findall(r"@implementation\b", code))
    ends = len(re.findall(r"@end\b", code))
    if ib + impl != ends:
        errors.append(f"{os.path.relpath(f, ROOT)}: @interface({ib}) + @implementation({impl}) = {ib+impl}，但 @end 有 {ends}")

# 3) logos 块配对
for f in files:
    if not f.endswith(".xm"):
        continue
    raw = open(f, encoding="utf-8", errors="replace").read()
    groups = len(re.findall(r"^\s*%group\b", raw, re.M))
    hooks = len(re.findall(r"^\s*%hook\b", raw, re.M))
    ctor = len(re.findall(r"^\s*%ctor\b", raw, re.M))
    ends = len(re.findall(r"^\s*%end\b", raw, re.M))
    expect = groups + hooks
    if ctor and ctor != 1:
        errors.append(f"{os.path.relpath(f, ROOT)}: %ctor 出现 {ctor} 次")
    if expect != ends:
        errors.append(f"{os.path.relpath(f, ROOT)}: %group({groups}) + %hook({hooks}) = {expect}，但 %end 有 {ends}")
    if groups and "%init(" in raw:
        pass
    if groups and "%init(" not in raw:
        warnings.append(f"{os.path.relpath(f, ROOT)}: 定义了 %group 但没看到 %init")

# 4) Makefile 引用的文件是否存在
tweak_mk = os.path.join(ROOT, "Makefile")
if os.path.exists(tweak_mk):
    text = open(tweak_mk, encoding="utf-8").read()
    # 抓 AttribClean_FILES = ... 到下一个空行
    m = re.search(r"AttribClean_FILES\s*=\s*((?:.*\\\n)*.*)", text)
    if m:
        blob = m.group(1).replace("\\\n", " ")
        for token in blob.split():
            p = os.path.join(ROOT, token)
            if not os.path.exists(p):
                errors.append(f"Makefile 引用了不存在的文件: {token}")
    if "prefsapp" not in text:
        warnings.append("Makefile 里没有 SUBPROJECTS += prefsapp")

prefs_mk = os.path.join(ROOT, "prefsapp", "Makefile")
if os.path.exists(prefs_mk):
    text = open(prefs_mk, encoding="utf-8").read()
    m = re.search(r"AttribCleanPrefs_FILES\s*=\s*((?:.*\\\n)*.*)", text)
    if m:
        blob = m.group(1).replace("\\\n", " ")
        for token in blob.split():
            p = os.path.join(ROOT, "prefsapp", token)
            if not os.path.exists(p):
                errors.append(f"prefsapp/Makefile 引用了不存在的文件: {token}")

# 5) Info.plist / entitlements 存在性
for rel in ["prefsapp/Resources/Info.plist", "prefsapp/entitlements.plist",
            "control", "layout/DEBIAN/postinst", "layout/DEBIAN/prerm"]:
    if not os.path.exists(os.path.join(ROOT, rel)):
        errors.append(f"缺少文件: {rel}")

# 6) 常量一致性：Tweak 里用到的 kACKey 是否都在 ACCommon.h 定义
common = open(os.path.join(ROOT, "Sources", "ACCommon.h"), encoding="utf-8").read()
defined = set(re.findall(r"kACKey(\w+)", common))
used = set()
for f in files:
    used |= set(re.findall(r"kACKey(\w+)", open(f, encoding="utf-8", errors="replace").read()))
missing = used - defined
if missing:
    errors.append(f"使用了未定义的常量: {sorted(missing)}")

# 7) 头文件 import 检查
for f in files:
    if not f.endswith(".m") and not f.endswith(".xm"):
        continue
    text = open(f, encoding="utf-8", errors="replace").read()
    for m in re.finditer(r'#import\s+"([^"]+\.h)"', text):
        hdr = m.group(1)
        p1 = os.path.join(os.path.dirname(f), hdr)
        p2 = os.path.join(ROOT, "Sources", hdr)
        p3 = os.path.join(ROOT, "prefsapp", hdr)
        if not (os.path.exists(p1) or os.path.exists(p2) or os.path.exists(p3)):
            errors.append(f"{os.path.relpath(f, ROOT)}: import 的头文件找不到 {hdr}")

# 8) 危险调用检查
for f in files:
    text = open(f, encoding="utf-8", errors="replace").read()
    for bad in ["killall", "pkill", "system(", "popen("]:
        if bad in text:
            warnings.append(f"{os.path.relpath(f, ROOT)}: 出现 {bad}")

print("=== 结果 ===")
if errors:
    print(f"错误 {len(errors)}:")
    for e in errors:
        print("  × ", e)
else:
    print("  √ 没有结构性问题")

if warnings:
    print(f"提示 {len(warnings)}:")
    for w in warnings:
        print("  ! ", w)

sys.exit(1 if errors else 0)
