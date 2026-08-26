"""Top-down comparison: agent STILL vs agent WALKING FORWARD, same seed.

Runs the same env twice from the same seed. Both runs are held identical
(no-op) for a `--settle` window so the flock starts the same, then:
  - run A: agent keeps standing STILL
  - run B: agent walks FORWARD

It records every sheep's position each step in both runs (matched by id) and
renders one top-down animation with BOTH flocks overlaid:
  - blue dots  = still-run sheep
  - orange dots = forward-run sheep
  - a thin grey line joins the same sheep across the two runs (the gap)
  - stars mark the two agents (black = still, red = forward)

If the orange dots pull away from the blue ones over time, the agent's motion
is influencing the sheep. If they stay on top of each other, it isn't (beyond
the sim's own noise).

Run headless:
    xvfb-run -a python sheep_compare_topdown.py --env-id Craftium/SheepInfoMG-v0
Output: flock_compare.gif
"""

import argparse
import json
import math
import os

import gymnasium as gym
import craftium  # noqa: F401

STILL = 0
FORWARD = 1


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


def run_episode(action_after_settle, seed, settle, record_steps, num_sheep, env_id):
    """Return (frames, players): frames[rec] = {id: (x, z)}, players[rec] = (x, z)."""
    env = gym.make(
        env_id, obs_width=64, obs_height=64, seed=seed, offscreen_sdl=False,
        minetest_conf=dict(num_sheep=num_sheep, sheep_spawn_radius=10,
                           sheep_report_radius=200),
    )
    env.reset(seed=seed)
    path = obs_path_of(env)

    frames, players = [], []
    for t in range(settle + record_steps):
        env.step(STILL if t < settle else action_after_settle)
        if t < settle:
            continue
        flock = read_flock(path)
        if flock is None:
            frames.append({})
            players.append(None)
            continue
        frame = {s["id"]: (s["pos"]["x"], s["pos"]["z"]) for s in (flock.get("sheep") or [])}
        pp = flock.get("player", {}).get("pos")
        frames.append(frame)
        players.append((pp["x"], pp["z"]) if pp else None)
    env.close()
    return frames, players


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--env-id", type=str, default="Craftium/SheepInfoMG-v0")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--settle", type=int, default=60,
                    help="no-op steps before the agents diverge (flock starts identical)")
    ap.add_argument("--steps", type=int, default=300, help="steps to record after settle")
    ap.add_argument("--num-sheep", type=int, default=50)
    ap.add_argument("--out", type=str, default="flock_compare.gif")
    ap.add_argument("--fps", type=int, default=15)
    args = ap.parse_args()

    print("== Run A: agent STILL ==")
    framesA, _ = run_episode(STILL, args.seed, args.settle, args.steps,
                             args.num_sheep, args.env_id)
    print("== Run B: agent FORWARD ==")
    framesB, playersB = run_episode(FORWARD, args.seed, args.settle, args.steps,
                                    args.num_sheep, args.env_id)

    n = min(len(framesA), len(framesB))
    if n == 0:
        print("No data captured — nothing to animate.")
        return

    # Fixed axis bounds across everything.
    xs, zs = [], []
    for frames in (framesA, framesB):
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
        a, b = framesA[i], framesB[i]
        gaps = [math.dist(a[k], b[k]) for k in a.keys() & b.keys()]
        return sum(gaps) / len(gaps) if gaps else 0.0

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation, PillowWriter

    fig, ax = plt.subplots(figsize=(7.5, 7.5))

    def draw(i):
        ax.clear()
        a, b = framesA[i], framesB[i]
        # gap lines between matched sheep
        for k in a.keys() & b.keys():
            ax.plot([a[k][0], b[k][0]], [a[k][1], b[k][1]], color="#cccccc",
                    linewidth=0.6, zorder=1)
        if a:
            ax.scatter([p[0] for p in a.values()], [p[1] for p in a.values()],
                       s=45, c="#1f77b4", edgecolors="black", linewidths=0.3,
                       label="agent STILL", zorder=2)
        if b:
            ax.scatter([p[0] for p in b.values()], [p[1] for p in b.values()],
                       s=45, c="#ff7f0e", edgecolors="black", linewidths=0.3,
                       label="agent FORWARD", zorder=3)
        if playersB[i]:
            ax.scatter(*playersB[i], marker="*", s=280, c="red", zorder=5)
        ax.scatter(0, 0, marker="*", s=280, c="black", zorder=5)  # still agent stays put
        ax.set_xlim(*xlim); ax.set_ylim(*zlim); ax.set_aspect("equal")
        ax.set_xlabel("x (nodes)"); ax.set_ylabel("z (nodes)")
        ax.set_title(f"STILL vs FORWARD — step {i+1}/{n}   mean gap = {mean_gap(i):.2f} nodes")
        ax.legend(loc="upper right", fontsize=9)

    anim = FuncAnimation(fig, draw, frames=n, interval=1000 / args.fps)
    anim.save(args.out, writer=PillowWriter(fps=args.fps))
    plt.close(fig)

    print(f"Saved comparison animation ({n} frames) -> {args.out}")
    print(f"Final mean gap between the two flocks: {mean_gap(n-1):.2f} nodes")


if __name__ == "__main__":
    main()
