"""Reproducibility test: run the SAME scenario twice, see if the sheep repeat.

Runs the env twice with the *same seed* and the agent standing STILL in both.
If the simulation were perfectly reproducible, every sheep would follow the
exact same trajectory both times, so the two flocks would overlap perfectly
(gap = 0 forever). Any gap that appears is the simulation being
non-reproducible run-to-run (shared global RNG + variable dtime).

Overlays both runs on one top-down map:
  - blue  dots = run 1
  - orange dots = run 2   (same sheep, matched by id)
  - grey lines join each sheep's two versions (the per-sheep gap)
The title shows the mean gap each step; the console prints a verdict.

Run headless:
    xvfb-run -a python sheep_reproducibility.py --env-id Craftium/SheepInfoMG-v0
Output: flock_reproducibility.gif
"""

import argparse
import json
import math
import os

import gymnasium as gym
import craftium  # noqa: F401

STILL = 0


def obs_path_of(env):
    mt = env.unwrapped.mt
    world_name = getattr(mt, "world_name", "world")
    return os.path.join(mt.run_dir, "worlds", world_name, "sheep_obs.json")


def read_flock(path):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def run_still_episode(seed, steps, num_sheep, env_id, pin=False, fixed_dtime=0.05,
                      grid=False):
    """Run one all-still episode; return frames[t] = {id: (x, z)}.

    If pin=True, run with sync_mode (one server step per action) and a fixed
    simulation dtime (craftium_fixed_dtime), so the run is deterministic.
    If grid=True, spawn the flock on a deterministic grid so both runs start
    in the identical layout (provably same positions at step 0).
    """
    conf = dict(num_sheep=num_sheep, sheep_spawn_radius=10, sheep_report_radius=200)
    if grid:
        conf["sheep_grid_spawn"] = True             # identical start on every run
    if pin:
        conf["craftium_fixed_dtime"] = fixed_dtime  # constant timestep -> reproducible
    env = gym.make(
        env_id, obs_width=64, obs_height=64, seed=seed, offscreen_sdl=False,
        sync_mode=pin,                 # lockstep client/server when pinning
        minetest_conf=conf,
    )
    env.reset(seed=seed)
    path = obs_path_of(env)
    frames = []
    for _ in range(steps):
        env.step(STILL)                       # agent never moves
        flock = read_flock(path)
        frames.append({s["id"]: (s["pos"]["x"], s["pos"]["z"])
                       for s in ((flock or {}).get("sheep") or [])})
    env.close()
    return frames


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--env-id", type=str, default="Craftium/SheepInfoMG-v0")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--steps", type=int, default=300)
    ap.add_argument("--num-sheep", type=int, default=50)
    ap.add_argument("--out", type=str, default="flock_reproducibility.gif")
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--pin", action="store_true",
                    help="pin the timestep: sync_mode + fixed craftium_fixed_dtime "
                         "(makes the runs deterministic)")
    ap.add_argument("--fixed-dtime", type=float, default=0.05,
                    help="constant simulation dtime in seconds when --pin is set")
    ap.add_argument("--grid", action="store_true",
                    help="spawn the flock on a deterministic grid so both runs "
                         "start in the identical layout (same positions at step 0)")
    args = ap.parse_args()

    bits = []
    bits.append("grid start" if args.grid else "random start")
    bits.append("PINNED dtime" if args.pin else "wall-clock dtime")
    mode = " · ".join(bits)
    print(f"== Run 1: agent STILL  [{mode}] ==")
    frames1 = run_still_episode(args.seed, args.steps, args.num_sheep, args.env_id,
                                pin=args.pin, fixed_dtime=args.fixed_dtime, grid=args.grid)
    print(f"== Run 2: agent STILL (identical seed)  [{mode}] ==")
    frames2 = run_still_episode(args.seed, args.steps, args.num_sheep, args.env_id,
                                pin=args.pin, fixed_dtime=args.fixed_dtime, grid=args.grid)

    n = min(len(frames1), len(frames2))
    if n == 0:
        print("No data captured — nothing to animate.")
        return

    xs, zs = [], []
    for frames in (frames1, frames2):
        for fr in frames:
            for (x, z) in fr.values():
                xs.append(x); zs.append(z)
    if not xs:
        print("Flock frames were empty — nothing to animate.")
        return
    pad = 3
    xlim = (min(xs) - pad, max(xs) + pad)
    zlim = (min(zs) - pad, max(zs) + pad)

    def mean_gap(i):
        a, b = frames1[i], frames2[i]
        gaps = [math.dist(a[k], b[k]) for k in a.keys() & b.keys()]
        return sum(gaps) / len(gaps) if gaps else 0.0

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation, PillowWriter

    fig, ax = plt.subplots(figsize=(7.5, 7.5))

    def draw(i):
        ax.clear()
        a, b = frames1[i], frames2[i]
        for k in a.keys() & b.keys():
            ax.plot([a[k][0], b[k][0]], [a[k][1], b[k][1]], color="#cccccc",
                    linewidth=0.6, zorder=1)
        if a:
            ax.scatter([p[0] for p in a.values()], [p[1] for p in a.values()],
                       s=45, c="#1f77b4", edgecolors="black", linewidths=0.3,
                       label="run 1 (still)", zorder=2)
        if b:
            ax.scatter([p[0] for p in b.values()], [p[1] for p in b.values()],
                       s=45, c="#ff7f0e", edgecolors="black", linewidths=0.3,
                       label="run 2 (still)", zorder=3)
        ax.scatter(0, 0, marker="*", s=280, c="black", zorder=5)  # agent (both still)
        ax.set_xlim(*xlim); ax.set_ylim(*zlim); ax.set_aspect("equal")
        ax.set_xlabel("x (nodes)"); ax.set_ylabel("z (nodes)")
        ax.set_title(f"Same scenario x2, player still — {mode}\n"
                     f"step {i+1}/{n}   mean gap = {mean_gap(i):.3f} nodes")
        ax.legend(loc="upper right", fontsize=9)

    anim = FuncAnimation(fig, draw, frames=n, interval=1000 / args.fps)
    anim.save(args.out, writer=PillowWriter(fps=args.fps))
    plt.close(fig)

    final = mean_gap(n - 1)
    print(f"Saved reproducibility animation ({n} frames) -> {args.out}")
    print(f"Final mean gap between the two identical runs: {final:.3f} nodes")
    if final < 1e-3:
        print("VERDICT: reproducible — the sheep followed the same trajectories both times.")
    else:
        print("VERDICT: NOT reproducible — identical setup, yet the sheep trajectories "
              "differ. The dynamics change run-to-run (shared global RNG / variable dtime).")


if __name__ == "__main__":
    main()
