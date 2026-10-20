#!/usr/bin/env python3
"""生成决赛路演 PPT（12 页，16:9，可编辑文本与表格）。"""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE

ACCENT = RGBColor(0x2B, 0x6C, 0xB0)
DARK = RGBColor(0x1A, 0x20, 0x2C)
GREY = RGBColor(0x5A, 0x63, 0x70)
LIGHT = RGBColor(0xF2, 0xF5, 0xF9)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)

prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
BLANK = prs.slide_layouts[6]


def box(slide, x, y, w, h, text="", size=18, color=DARK, bold=False, align=PP_ALIGN.LEFT):
    tb = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    p = tf.paragraphs[0]
    p.alignment = align
    r = p.add_run()
    r.text = text
    r.font.size = Pt(size)
    r.font.bold = bold
    r.font.color.rgb = color
    return tb


def bullets(slide, x, y, w, h, items, size=17, color=DARK, space=8):
    tb = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    first = True
    for it in items:
        p = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        p.space_after = Pt(space)
        r = p.add_run()
        r.text = it
        r.font.size = Pt(size)
        r.font.color.rgb = color
    return tb


def title_bar(slide, title, kicker=""):
    bar = slide.shapes.add_shape(1, Inches(0), Inches(0), prs.slide_width, Inches(1.05))
    bar.fill.solid()
    bar.fill.fore_color.rgb = ACCENT
    bar.line.fill.background()
    box(slide, 0.55, 0.22, 11.5, 0.6, title, size=26, color=WHITE, bold=True)
    if kicker:
        box(slide, 0.6, 1.15, 12, 0.4, kicker, size=13, color=GREY)


def table(slide, x, y, w, rows, col_w=None, header=True, size=14):
    nrows, ncols = len(rows), len(rows[0])
    h = 0.42 * nrows
    shape = slide.shapes.add_table(nrows, ncols, Inches(x), Inches(y), Inches(w), Inches(h))
    tbl = shape.table
    if col_w:
        for i, cw in enumerate(col_w):
            tbl.columns[i].width = Inches(cw)
    for ri, row in enumerate(rows):
        for ci, val in enumerate(row):
            cell = tbl.cell(ri, ci)
            cell.text = ""
            p = cell.text_frame.paragraphs[0]
            r = p.add_run()
            r.text = str(val)
            r.font.size = Pt(size)
            if header and ri == 0:
                r.font.bold = True
                r.font.color.rgb = WHITE
                cell.fill.solid()
                cell.fill.fore_color.rgb = ACCENT
            else:
                r.font.color.rgb = DARK
                cell.fill.solid()
                cell.fill.fore_color.rgb = LIGHT if ri % 2 else WHITE
    return shape


def rrect(slide, x, y, w, h, fill, line=None):
    sh = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Inches(x), Inches(y), Inches(w), Inches(h))
    sh.adjustments[0] = 0.08
    sh.fill.solid()
    sh.fill.fore_color.rgb = fill
    if line is None:
        sh.line.fill.background()
    else:
        sh.line.color.rgb = line
        sh.line.width = Pt(0.75)
    sh.shadow.inherit = False
    return sh


def shape_text(shape, lines, size=13, color=DARK, bold=False, align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.MIDDLE):
    tf = shape.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.margin_left = Inches(0.12)
    tf.margin_right = Inches(0.1)
    tf.margin_top = Inches(0.04)
    tf.margin_bottom = Inches(0.04)
    first = True
    for line, sz, c, b in lines:
        p = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        p.alignment = align
        r = p.add_run()
        r.text = line
        r.font.size = Pt(sz)
        r.font.bold = b
        r.font.color.rgb = c
    return shape


# ---------- 1 封面 ----------
s = prs.slides.add_slide(BLANK)
bg = s.shapes.add_shape(1, Inches(0), Inches(0), prs.slide_width, prs.slide_height)
bg.fill.solid(); bg.fill.fore_color.rgb = ACCENT; bg.line.fill.background()
box(s, 0.9, 2.0, 11.5, 1.0, "cjreg · 仓颉私有中心仓与多仓体系", size=40, color=WHITE, bold=True)
box(s, 0.95, 3.05, 11.5, 0.6, "仓颉生态创新开发挑战赛 · 决赛路演", size=22, color=WHITE)
box(s, 0.95, 4.35, 11.5, 0.5, "技术课题 ｜ 版本 v0.3.0（2026-10-20）", size=16, color=WHITE)
box(s, 0.95, 4.85, 11.5, 0.5,
    "https://atomgit.com/ystyle/cjreg    ghcr.io/ystyle/cjreg:v0.3.0    https://ystyle.top/cjreg/",
    size=14, color=WHITE)

# ---------- 2 问题与定位 ----------
s = prs.slides.add_slide(BLANK)
title_bar(s, "问题：官方中心仓很好，但它不解决这三件事")
PROBLEMS = [
    ("① 内网 / 离线没有仓", "中心仓在公网；流水线与机器在内网，离线时要带着依赖跑"),
    ("② 发布不可逆、同步不可控", "版本不能删除、不能覆盖；索引同步几十分钟到几天，失败要等"),
    ("③ 团队需要自己的仓与预演位", "预发布、内部包、灰度版本不该进公共仓"),
]
pw, pgap = 3.95, 0.22
for i, (t, d) in enumerate(PROBLEMS):
    x = 0.55 + i * (pw + pgap)
    card = rrect(s, x, 1.75, pw, 2.0, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
    shape_text(card, [(t, 16, ACCENT, True), (d, 13, DARK, False)], anchor=MSO_ANCHOR.MIDDLE)
pos = rrect(s, 0.55, 4.15, 12.23, 1.2, ACCENT)
shape_text(pos, [("cjreg 的定位：与官方协议互通的私有中心仓 + 多仓体系", 20, WHITE, True),
                 ("不是替代，是补位 —— 官方仓照常用，缺的那一半由私有仓承接", 14, WHITE, False)])
box(s, 0.6, 5.75, 12.1, 0.6,
    "生产实例已在内网常驻：团队日常发布、门户取 Token、审计留痕；本机也能一条 compose 起一套",
    size=14, color=GREY)

# ---------- 3 能力地图 ----------
s = prs.slides.add_slide(BLANK)
title_bar(s, "能力地图：一条发布链路上的七件事")
rows = [
    ["环节", "能力", "关键实现"],
    ["发布", "官方二进制协议互通；流式接收；幂等/冲突/越权判定", "分段解析 + 边读边算 sha256 + 原子落盘"],
    ["索引 / 下载", "NDJSON 索引；流式下载；下载计数", "IndexService / BlobStore.stream"],
    ["多仓", "官方 + 私有 + 团队仓；回源、缓存、解析诊断、重拉", "ProxyService / ResolveService / UpstreamProbe"],
    ["发布计划", "选包自动补依赖（拓扑序）→ 版本对照 → 推送；六态 + SSE", "PublishPlanService / PublishExecutor"],
    ["权限", "首个发布者 = owner；团队 write/overwrite；管理员直通", "effectivePermission 双栈裁决"],
    ["门户 / 管理端", "用户门户（Token、我的包、我的团队）+ 管理后台", "cjxt 声明式页面 + WS 补丁"],
    ["审计 / 公开 API", "发布/认证/管理审计（IP/UA）；公开只读 API 供 CI 集成", "LogDoc / /api/stats /api/packages"],
]
table(s, 0.55, 1.45, 12.2, rows, col_w=[1.7, 5.3, 5.2], size=13)

# ---------- 4 架构 ----------
s = prs.slides.add_slide(BLANK)
title_bar(s, "技术方案：分层与关键取舍",
          "纯仓颉实现 · 静态单二进制 · 依赖 bstorm（KV）/ cjxt（UI+WS）/ tang（HTTP）")


# 左：分层（自顶向下 5 层，名称色块 + 说明）
box(s, 0.55, 1.55, 7.4, 0.34, "分层（自顶向下）", size=13, color=GREY, bold=True)
LAYERS = [
    ("ui",       "cjxt 页面层 —— 公共面 / 管理面分子包", ACCENT),
    ("server",   "发布裁决 · 代理回源 · 计划执行 · handler", ACCENT),
    ("store",    "bstorm 文档层 —— 包 / 用户 / 上游 / 团队 / 审计", ACCENT),
    ("index",    "NDJSON 生成与兼容解析", ACCENT),
    ("protocol", "官方发布 / 下载二进制协议、URL 分片", ACCENT),
]
y0, hh, gap = 1.95, 0.74, 0.12
for i, (name, desc, color) in enumerate(LAYERS):
    y = y0 + i * (hh + gap)
    rrect(s, 0.55, y, 7.4, hh, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
    chip = rrect(s, 0.62, y + 0.13, 1.15, hh - 0.26, color)
    shape_text(chip, [(name, 13, WHITE, True)], align=PP_ALIGN.CENTER)
    box(s, 1.9, y + 0.16, 5.9, hh - 0.3, desc, size=13, color=DARK)
box(s, 0.6, y0 + 5 * (hh + gap) - 0.02, 7.3, 0.34,
    "层间数据一律 DTO 序列化（公开面 + 管理面）", size=12, color=GREY)

# 右：三个关键取舍 + 一条决赛核心改造
box(s, 8.25, 1.55, 4.55, 0.34, "关键取舍", size=13, color=GREY, bold=True)
TRADES = [
    ("为什么不用 SQLite？", "当时仓颉生态还没有完整可用的 SQLite 驱动"),
    ("为什么自研 tar / gzip？", "发布与回源要从制品里取 README、cjpm.toml"),
    ("为什么 UI 走 WS 补丁？", "信号派生，前端零手写 DOM"),
]
ty, th, tgap = 1.95, 1.02, 0.14
for i, (q, a) in enumerate(TRADES):
    y = ty + i * (th + tgap)
    card = rrect(s, 8.25, y, 4.55, th, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
    shape_text(card, [(q, 13, ACCENT, True), (a, 12, DARK, False)], anchor=MSO_ANCHOR.MIDDLE)
y_hl = ty + 3 * (th + tgap) + 0.06
hl = rrect(s, 8.25, y_hl, 4.55, 0.98, ACCENT)
shape_text(hl, [("决赛核心改造：发布链路全程流式", 13, WHITE, True),
                ("内存与包体解耦（详见下页数字）", 12, WHITE, False)])

# ---------- 5 流式发布 ----------
s = prs.slides.add_slide(BLANK)
title_bar(s, "核心难点 ①：流式发布 / 下载 / 回源（内存 O(1)）")
rows = [
    ["指标", "初赛 v0.2.0", "决赛 v0.3.0"],
    ["最大可发布包体", "≤32 MiB；48–50 MiB 偶发 OOM", "200 MiB 稳定"],
    ["200 MiB 发布", "失败", "0.618 s（324 MiB/s）"],
    ["发布峰值内存", "≈ 包体 2–3 倍", "恒定 291 MiB"],
    ["200 MiB 下载", "Out of memory", "成功，sha256 一致"],
]
table(s, 0.55, 1.5, 7.3, rows, col_w=[2.05, 2.7, 2.55], size=13)
why = rrect(s, 0.55, 3.95, 7.3, 1.5, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
shape_text(why, [("为什么重要", 14, ACCENT, True),
                 ("整包驻留时峰值 ≈ 包体的 2–3 倍，撞上默认 256 MB 堆上限就失败；"
                  "现在内存与包体解耦，发大包不再需要调 cjHeapSize", 12, DARK, False)])
box(s, 0.6, 6.5, 12.1, 0.5,
    "复现：bash scripts/bench.sh（桩上游 + k6；内存取 /proc/<pid>/status 的 VmHWM）",
    size=13, color=GREY)

# 右侧：做法三步 + 下载/回源
box(s, 8.2, 1.5, 4.6, 0.34, "做法（发布链路）", size=13, color=GREY, bold=True)
STEPS = [("①", "按段解析头，拿到长度与校验"), ("②", "边读边算 sha256，不缓存整包"),
         ("③", "写临时文件 → 校验 → rename 原子落盘")]
for i, (n, d) in enumerate(STEPS):
    y = 1.9 + i * 0.9
    card = rrect(s, 8.2, y, 4.6, 0.78, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
    shape_text(card, [(f"{n}  {d}", 13, DARK, False)])
note = rrect(s, 8.2, 4.65, 4.6, 1.0, ACCENT)
shape_text(note, [("下载 / 回源同样流式", 14, WHITE, True),
                  ("handler 直接 body(stream)；回源边收边落盘", 12, WHITE, False)])

# ---------- 6 权限 ----------
s = prs.slides.add_slide(BLANK)
title_bar(s, "核心难点 ②：权限双栈与「首个发布者 = owner」")
rows = [
    ["操作者", "发新版本", "覆盖已有版本", "说明"],
    ["包 owner", "✓", "✗（需 overwrite）", "owner = 该包最早版本发布者，唯一且不随覆盖转移"],
    ["团队成员（write）", "✓", "✗", "按团队关联的组织 / 包判定"],
    ["团队成员（overwrite）", "✓", "✓", "覆盖需显式授权"],
    ["平台管理员", "✓", "✓", "直通 overwrite（预演必需：同版本可反复发）"],
]
table(s, 0.55, 1.5, 12.2, rows, col_w=[3.0, 2.1, 2.6, 4.5], size=14)
bullets(s, 0.7, 4.55, 12.0, 2.0, [
    "退出团队后不可见是有意的产品决策：私有仓的可见性跟随权限，不做历史遗留读取",
    "越权返回 403，并在审计里记 failed + 原因（运营可对照两条记录）",
], size=15, space=10)

# ---------- 7 六态 + SSE ----------
s = prs.slides.add_slide(BLANK)
title_bar(s, "核心难点 ③：发布计划六态 + SSE 实时进度")
box(s, 0.55, 1.38, 6.0, 0.32, "计划项状态机", size=13, color=GREY, bold=True)
STATES = [("pending", "待执行", RGBColor(0x8A, 0x94, 0xA3)), ("running", "执行中", ACCENT),
          ("waiting_index", "等索引（可见）", RGBColor(0xB4, 0x7A, 0x1F)),
          ("completed", "完成", RGBColor(0x2F, 0x86, 0x5A))]
sx, sw, sgap = 0.55, 2.55, 0.42
for i, (name, cap, color) in enumerate(STATES):
    x = sx + i * (sw + sgap)
    chip = rrect(s, x, 1.75, sw, 0.8, color)
    shape_text(chip, [(name, 15, WHITE, True)], align=PP_ALIGN.CENTER)
    box(s, x, 2.6, sw, 0.3, cap, size=11, color=GREY, align=PP_ALIGN.CENTER)
    if i < 3:
        box(s, x + sw, 1.87, sgap, 0.5, "→", size=18, color=ACCENT, bold=True, align=PP_ALIGN.CENTER)

box(s, 0.55, 3.02, 2.0, 0.3, "分支", size=12, color=GREY, bold=True)
BR = [("failed", "任一步失败（带原因）", 0.55), ("skipped", "人工跳过该包", 4.4)]
for name, cap, x in BR:
    chip = rrect(s, x, 3.32, 1.55, 0.6, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
    shape_text(chip, [(name, 14, DARK, True)], align=PP_ALIGN.CENTER)
    box(s, x + 1.65, 3.4, 1.9, 0.4, cap, size=11, color=GREY)

INFO = [
    ("索引判据", "版本出现且 sha256 一致才算完成，索引先到的假完成被挡掉"),
    ("SSE 事件", "GET /api/admin/publish-plans/:id/events，event: progress / done"),
    ("可恢复", "中断后计划保持 pending，不会假装 running"),
]
cw, cgap = 3.98, 0.16
for i, (t, d) in enumerate(INFO):
    x = 0.55 + i * (cw + cgap)
    card = rrect(s, x, 4.35, cw, 1.3, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
    shape_text(card, [(t, 13, ACCENT, True), (d, 12, DARK, False)])
box(s, 0.6, 5.95, 12.1, 0.9,
    "为什么需要：发布不可逆 —— 推送目标仓时「发没发成功」必须可见、可核验、可跳过，"
    "否则一次网络抖动就让人不敢继续", size=14, color=GREY)

# ---------- 8 迭代成果 ----------
s = prs.slides.add_slide(BLANK)
title_bar(s, "决赛阶段迭代成果（相比初赛 v0.2.0）")
KPI = [
    ("单测用例", "154 → 1002", "×6.5"),
    ("行覆盖率", "39.3% → 91.3%", "+52.0pp"),
    ("最大可发布包体", "32 MiB → 200 MiB", "×6 以上"),
    ("发布峰值内存", "≈3× 包体 → 291 MiB", "与包体解耦"),
]
kw, kgap = 2.93, 0.18
for i, (label, value, delta) in enumerate(KPI):
    x = 0.55 + i * (kw + kgap)
    card = rrect(s, x, 1.6, kw, 1.95, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
    shape_text(card, [(label, 13, GREY, False), (value, 22, ACCENT, True), (delta, 13, DARK, False)],
               align=PP_ALIGN.CENTER)
box(s, 0.55, 3.85, 12.2, 0.34, "新增能力", size=13, color=GREY, bold=True)
CAPS = [
    ("发布计划六态 + SSE", "实时进度 · 索引 SHA256 校验 · 手动跳过"),
    ("团队 owner 自助", "成员 / 转移 owner / 团队关联，门户弹窗"),
    ("自包含构建镜像", "Dockerfile.build 多阶段，评审无需本地工具链"),
]
cw, cgap = 3.98, 0.16
for i, (t, d) in enumerate(CAPS):
    x = 0.55 + i * (cw + cgap)
    card = rrect(s, x, 4.25, cw, 1.15, ACCENT)
    shape_text(card, [(t, 14, WHITE, True), (d, 12, WHITE, False)])
info = rrect(s, 0.55, 5.65, 12.2, 0.95, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
shape_text(info, [("工程结构同期改造", 13, ACCENT, True),
                  ("admin_handler 1358 → 122 行；ui 按站点面分子包、一页一文件；响应体统一 DTO 序列化；+80 个提交", 12, DARK, False)])

# ---------- 9 质量与性能证据 ----------
s = prs.slides.add_slide(BLANK)
title_bar(s, "质量与性能：每个数字都可复现")
lp = rrect(s, 0.55, 1.5, 6.0, 4.4, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
box(s, 0.8, 1.68, 5.5, 0.32, "测试与验证", size=13, color=ACCENT, bold=True)
box(s, 0.78, 2.0, 5.6, 0.62, "1002 用例 · 91.3% 行覆盖", size=24, color=DARK, bold=True)
bullets(s, 0.8, 2.75, 5.55, 2.9, [
    "1002 例 = 逻辑单测 + 进程内 HTTP 夹具（真实服务 + 真实 client）+ 页面渲染断言",
    "覆盖率：cjcov HTML 报告（CI artifact），逻辑层 85%–95%",
    "双仓 e2e 9 步：发布 6 包 → 拓扑推送 → 公开 API → 上游连通 → 三级删除 → 组织 CRUD",
    "CI 六步：构建 / 单测 / 覆盖率 / e2e / 文档站 / 容器冒烟",
], size=12, space=8)

rp = rrect(s, 6.78, 1.5, 6.0, 4.4, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
box(s, 7.03, 1.68, 5.5, 0.32, "性能（同一脚本可复现）", size=13, color=ACCENT, bold=True)
PERF = [
    ("索引命中 2.74 ms", "回源 16.16 ms → 5.9×（桩计数证明重查轮零回源）"),
    ("发布吞吐 324 MiB/s", "2 / 32 / 200 MiB = 74 / 278 / 324 MiB/s"),
    ("并发 414 req/s", "1/4/16/64 VU → 88 / 294 / 414 / 356（拐点 16 VU）"),
    ("内存 291 MiB 恒定", "2 / 32 / 200 MiB 发布与 200 MiB 下载均平稳"),
]
for i, (big, desc) in enumerate(PERF):
    y = 2.15 + i * 0.92
    box(s, 7.03, y, 5.5, 0.36, big, size=16, color=DARK, bold=True)
    box(s, 7.03, y + 0.34, 5.5, 0.4, desc, size=11, color=GREY)
box(s, 0.6, 6.15, 12.1, 0.5,
    "复现：bash scripts/bench.sh（桩上游 + k6）｜ cjpm test --coverage && cjcov … -e \"*_test.cj\"",
    size=12, color=GREY)

# ---------- 10 实用价值 ----------
s = prs.slides.add_slide(BLANK)
title_bar(s, "实用价值与落地：四类真实用法")
VAL = [
    ("内网常驻私有仓", "流水线与机器在内网：发布、拉依赖、门户取 Token 全在本地完成"),
    ("预演仓", "发布不可逆，先在私有仓预演；管理员直通 overwrite，同版本可反复发"),
    ("多仓体系：一个实例对接多个仓", "读路径（回源/镜像）与写路径（推送目标）两个独立开关；版本对照告诉你目标仓有没有、要不要发"),
    ("CI 与工具链集成", "公开只读 API 取包索引与统计；cjpm 客户端无需改造；镜像一条命令起"),
]
vw, vh, vgx, vgy = 5.95, 1.8, 0.25, 0.2
for i, (t, d) in enumerate(VAL):
    x = 0.55 + (i % 2) * (vw + vgx)
    y = 1.6 + (i // 2) * (vh + vgy)
    card = rrect(s, x, y, vw, vh, LIGHT, line=RGBColor(0xD5, 0xDE, 0xE8))
    shape_text(card, [(t, 16, ACCENT, True), (d, 13, DARK, False)])
hl = rrect(s, 0.55, 5.55, 12.2, 0.95, ACCENT)
shape_text(hl, [("把中心仓缺的那一半补上：内网可用 · 预演安全 · 多仓可查", 18, WHITE, True)])
box(s, 0.6, 6.7, 12.1, 0.45,
    "生产实例已常驻内网（团队真实在用）｜镜像 ghcr.io/ystyle/cjreg:v0.3.0｜tag v0.3.0",
    size=13, color=GREY)

# ---------- 12 收尾 ----------
s = prs.slides.add_slide(BLANK)
bg = s.shapes.add_shape(1, Inches(0), Inches(0), prs.slide_width, prs.slide_height)
bg.fill.solid(); bg.fill.fore_color.rgb = ACCENT; bg.line.fill.background()
box(s, 0.9, 2.2, 11.5, 0.9, "谢谢 · Q & A", size=40, color=WHITE, bold=True)
box(s, 0.95, 3.5, 11.5, 1.8,
    "仓库  https://atomgit.com/ystyle/cjreg  （tag v0.3.0）\n"
    "镜像  ghcr.io/ystyle/cjreg:v0.3.0\n"
    "文档  https://ystyle.top/cjreg/   验证 docs/verification.md   基准 docs/benchmark.md",
    size=16, color=WHITE)
box(s, 0.95, 5.55, 11.5, 0.5,
    "未实现功能与限制：仓库 docs/finals-submission.md §4.5（按赛事要求书面注明）",
    size=12, color=WHITE)


# ---------- 演讲者备注（演讲者视图直接用；每页 30–60 秒）----------
NOTES = [
    "【第1页 · 约 30 秒】开场：我是 XXX，作品是 cjreg —— 仓颉私有中心仓与多仓体系，技术课题。"
    "一句话：官方中心仓解决公共分发，我们解决内网/离线/预演这三件它不覆盖的事。",
    "【第2页 · 约 60 秒】三条各说一句就够：内网没仓、发布不可逆+同步不可控、团队要自己的预演位。"
    "落点：不是替代官方仓，是补位，协议完全互通。",
    "【第3页 · 约 60 秒】不要逐行念表格。挑三件讲：发布（协议互通+流式）、多仓（回源+解析诊断）、"
    "发布计划（拓扑推送+实时进度）。其余一句『都在同一个仓里』带过。",
    "【第4页 · 约 50 秒】分两列讲：左边是分层（protocol/index/store/server/ui），右边是取舍。"
    "必讲的一句：『发布链路全程流式，这是决赛最大的改造』。",
    "【第5页 · 约 70 秒】先给对比表里最刺眼的一行：200 MiB 从失败到 0.618 秒、内存恒定 291 MiB。"
    "再用三句话说做法：边读边算 sha256、写临时文件、rename 原子落盘。最后说复现方式（bench.sh）。",
    "【第6页 · 约 40 秒】讲矩阵的两端：owner 能发新版本但不能覆盖；管理员直通 overwrite（预演必需）。"
    "退出团队即不可见是**有意的产品决策**，不是缺陷。",
    "【第7页 · 约 50 秒】一句话说为什么需要：发布不可逆，所以『发没发成功』必须可见可核验。"
    "判据要点：版本出现且 sha256 一致才算完成，避免索引先到的假完成。",
    "【第8页 · 约 60 秒】只念五个数字：154→1002、39.3%→91.3%、六态+SSE、owner 自助、自包含构建。"
    "每个数字都能在仓库里找到脚本和报告。",
    "【第9页 · 约 40 秒】左列说『测试怎么组织』（逻辑单测 + 进程内 HTTP 夹具 + 页面渲染），"
    "右列只念两个数字：索引 5.9×、并发拐点 16 VU / 414 req/s。",
    "【第10页 · 约 40 秒】四个场景各一句：内网常驻、预演仓、多仓解析、CI 集成。"
    "补一句生产在跑、有真实团队与审计数据。",
    "【第11页 · 约 50 秒】谢谢 + 给链接（仓库 tag v0.3.0 / 镜像 / 文档站）。未实现项（arm64/瘦身/预热）不做单独页，评委问到再答，口径见答辩手册 Q8。"
    "留一句钩子：『发布链路的流式改造和测试体系是这次迭代最重的两块，评委老师想先听哪块？』",
]

for _slide, _note in zip(prs.slides, NOTES):
    _slide.notes_slide.notes_text_frame.text = _note

out = "/home/ystyle/Projects/Cangjie/cjreg/docs/finals-roadshow-v0.3.0.pptx"
prs.save(out)
print("saved", out, "slides:", len(prs.slides))
