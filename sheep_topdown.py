"""Top-down visualization of the sheep flock.

Runs a SheepInfo env, records every sheep's position each step from the
sheep_obs.json side-channel, then renders a top-down (x-z plane) animation of
the whole flock moving around the agent — a clear overview of all 50 sheep that
doesn't depend on in-game rendering.

Sheep are coloured by their AI state (stand/walk/runaway/eat); the agent is the
black star at the centre.

Run headless, e.g.:
    xvfb-run -a python sheep_topdown.py --env-id Craftium/SheepInfoMG-v0
Output: flock_topdown.gif  (open it in VS Code's Explorer).
"""

import argparse
import json
import os

import gymnasium as gym
import craftium  # noqa: F401


STATE_COLORS = {
    "stand": "#8888aa",
    "walk": "#2ca02c",
    "runaway": "#d62728",
    "eat": "#1f77b4",
}


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


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--env-id", type=str, default="Craftium/SheepInfoMG-v0")
    ap.add_argument("--steps", type=int, default=300)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--num-sheep", type=int, default=50)
    ap.add_argument("--out", type=str, default="flock_topdown.gif")
    ap.add_argument("--fps", type=int, default=15)
    args = ap.parse_args()

    env = gym.make(
        args.env_id,
        obs_width=64,
        obs_height=64,
        seed=args.seed,
        offscreen_sdl=False,
        minetest_conf=dict(
            num_sheep=args.num_sheep,
            sheep_spawn_radius=10,
            sheep_report_radius=60,
        ),
    )
    env.reset(seed=args.seed)
    path = obs_path_of(env)

    # Record one snapshot per step: list of (x, z, state) plus the player x,z.
    snapshots = []
    for t in range(args.steps):
        # Slowly turn so the sheep wander naturally; the view is top-down anyway.
        env.step(4 if t % 3 == 0 else 0)
        flock = read_flock(path)
        if flock is None:
            continue
        sheep = [(s["pos"]["x"], s["pos"]["z"], s.get("intent", {}).get("state", "?"))
                 for s in (flock.get("sheep") or [])]
        pp = flock.get("player", {}).get("pos")
        player = (pp["x"], pp["z"]) if pp else (0.0, 0.0)
        snapshots.append((sheep, player))
    env.close()

    if not snapshots:
        print("No flock data was captured — nothing to animate.")
        return

    # Work out fixed axis bounds so the animation doesn't jump around.
    xs = [x for snap, _ in snapshots for (x, _z, _s) in snap]
    zs = [z for snap, _ in snapshots for (_x, z, _s) in snap]
    if not xs:
        print("Flock snapshots were empty — nothing to animate.")
        return
    pad = 3
    xlim = (min(xs) - pad, max(xs) + pad)
    zlim = (min(zs) - pad, max(zs) + pad)

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation, PillowWriter

    fig, ax = plt.subplots(figsize=(7, 7))

    def draw(i):
        ax.clear()
        sheep, player = snapshots[i]
        for x, z, state in sheep:
            ax.scatter(x, z, s=60, c=STATE_COLORS.get(state, "#333333"),
                       edgecolors="black", linewidths=0.4)
        ax.scatter(player[0], player[1], marker="*", s=300, c="black", zorder=5,
                   label="agent")
        ax.set_xlim(*xlim)
        ax.set_ylim(*zlim)
        ax.set_aspect("equal")
        ax.set_xlabel("x (nodes)")
        ax.set_ylabel("z (nodes)")
        ax.set_title(f"Flock top-down — step {i+1}/{len(snapshots)}  "
                     f"({len(sheep)} sheep)")
        # Legend of state colours.
        handles = [plt.Line2D([0], [0], marker="o", linestyle="", markerfacecolor=c,
                              markeredgecolor="black", label=name)
                   for name, c in STATE_COLORS.items()]
        ax.legend(handles=handles, loc="upper right", fontsize=8, title="state")

    anim = FuncAnimation(fig, draw, frames=len(snapshots), interval=1000 / args.fps)
    anim.save(args.out, writer=PillowWriter(fps=args.fps))
    plt.close(fig)
    print(f"Saved top-down animation ({len(snapshots)} frames) -> {args.out}")


if __name__ == "__main__":
    main()
