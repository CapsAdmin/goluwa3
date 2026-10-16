import subprocess, sys, glob, collections, os
crop = os.environ.get("FLY_CROP")
crop_args = ["-crop", crop, "+repage"] if crop else []
d = sys.argv[1]
frames = sorted(glob.glob(d + "/f*.png"))
mean = sys.argv[2] if len(sys.argv) > 2 else d + "/mean.png"
if len(sys.argv) <= 2:
    subprocess.run(["magick"] + frames + ["-evaluate-sequence", "mean", mean], check=True)
tot = collections.Counter()
for f in frames:
    raw = subprocess.run(["magick", f, mean, "-compose", "difference", "-composite"] + crop_args + ["-colorspace", "Gray", "-depth", "8", "gray:-"], capture_output=True, check=True).stdout
    tot.update(raw)
n = sum(tot.values())
mad = sum(k * v for k, v in tot.items()) / n
def frac_above(t): return sum(v for k, v in tot.items() if k > t) / n
def pct(p):
    acc = 0
    for k in sorted(tot):
        acc += tot[k]
        if acc >= p * n: return k
rms = (sum(k * k * v for k, v in tot.items()) / n) ** 0.5
print(f"{d}: frames={len(frames)} rms={rms:.2f} mad={mad:.2f} p99={pct(.99)} p99.9={pct(.999)} >8:{frac_above(8)*100:.3f}% >16:{frac_above(16)*100:.3f}% >32:{frac_above(32)*100:.4f}% max={max(tot)}")
