"""Render the article's measured RSS curves; requires matplotlib."""

import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

root = Path(__file__).resolve().parent
data = json.loads((root / "measurements.json").read_text())
before, after = data["runs"]
font = Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc")
if font.exists():
    font_manager.fontManager.addfont(str(font))
    plt.rcParams["font.family"] = font_manager.FontProperties(fname=font).get_name()
plt.rcParams.update({"font.size": 10, "axes.unicode_minus": False, "svg.fonttype": "path"})

fig, axes = plt.subplots(1, 2, figsize=(12, 4.8), gridspec_kw={"width_ratios": [1.25, 1]})
colors = {"before": "#c04c39", "after": "#167c80"}
for run, label in [(before, "修复前 · 478960a8"), (after, "修复后 · 21fd1b6d")]:
    x = [s["requests"] for s in run["samples"]]
    y = [s["rss_kib"] / 1024 for s in run["samples"]]
    axes[0].plot(x, y, color=colors[run["label"]], label=label, linewidth=1.9)
    if run["label"] == "after":
        axes[1].plot(x, y, color=colors["after"], linewidth=1.7)

axes[0].set(title="相同纵轴：修复前后对照", ylim=(0, 1600))
axes[1].set(title="放大修复后的曲线", ylim=(0, 95))
axes[0].legend(loc="upper right", frameon=False)
peak = max(before["samples"], key=lambda s: s["rss_kib"])
axes[0].annotate(
    "482 步后内存分配失败\n峰值 1433.7 MiB",
    xy=(peak["requests"], peak["rss_kib"] / 1024), xytext=(90, 1250),
    arrowprops={"arrowstyle": "->", "color": colors["before"]}, color=colors["before"],
)
axes[1].text(40, 82, "1000 步全部完成\n峰值 82.2 MiB", color=colors["after"], va="top")
for ax in axes:
    ax.set(xlim=(0, 1030), xlabel="模型请求计数（1000 次工具步骤 + 1 次最终回复）", ylabel="fx RSS / MiB")
    ax.grid(axis="y", color="#dde2e5", linewidth=0.7)
    ax.spines[["top", "right"]].set_visible(False)
    ax.set_axisbelow(True)
fig.suptitle("相同的长回合，临时副本是否及时释放，决定了内存增长的形状", fontsize=13, x=0.51)
fig.text(0.5, 0.025, "真实采样，无拟合或外推；仅测 fx。2 GiB 限制针对虚拟地址空间，图中纵轴是 RSS。", ha="center", fontsize=9, color="#475569")
fig.tight_layout(rect=(0, 0.07, 1, 0.95))
fig.savefig(root / "memory-rss.png", dpi=180, facecolor="white")
fig.savefig(root / "memory-rss.svg", facecolor="white")
