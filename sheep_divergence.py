"""Determinism / divergence experiment for Craftium/SheepInfoVL-v0.

Question: with everything else pinned (same seed, same env, same build), how do
the sheep trajectories differ between a run where the player stands STILL and a
run where the player moves FORWARD?

Method
------
Both runs use the same seed and are held identical (no-op) for a "settle" window
so the flock spawns to the *same* initial state. From step `settle` onward:
  - run A: player keeps standing still (action 0 = NOP)
  - run B: player walks forward   (action 1 = forward)
Everything else is pinned. We then diff each sheep's path by its stable `id`.

Outputs (in --out-dir):
  - divergence.csv         per-step mean/max sheep displacement between A and B
  - divergence_onset.csv   per-sheep first step where its two paths separate
  - divergence.png         plot (if matplotlib is available)
  - summary.json           headline numbers

Run headless, e.g.:  xvfb-run -a python sheep_divergence.py
"""

import argparse
import json
import math
import os

import gymnasium as gym
import craftium  # noqa: F401  (registers Craftium/* envs)

# Action indices for SheepInfoVL-v0's DiscreteActionWrapper:
#   0 = NOP (still), 1 = forward, 2 = left, 3 = right, 4 = jump, 5.. = mouse
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


def run_episode(action_after_settle, seed, settle, record_steps, num_sheep, spawn_radius,
                env_id="Craftium/SheepInfoVL-v0"):
    """Run one episode; return (traj, player_traj).

    traj: {sheep_id: {rec_step: (x, y, z)}} for rec_step in 0..record_steps-1
    player_traj: {rec_step: (x, y, z)}
    """
    env = gym.make(
        env_id,
        obs_width=64,
        obs_height=64,
        seed=seed,
        # Normal x11 SDL driver (works under Xvfb and real displays alike).
        offscreen_sdl=False,
        minetest_conf=dict(
            num_sheep=num_sheep,
            sheep_spawn_radius=spawn_radius,
            sheep_report_radius=200,  # keep every sheep in the report the whole run
        ),
    )
    env.reset(seed=seed)
    path = obs_path_of(env)

    traj = {}
    player_traj = {}
    total = settle + record_steps
    for t in range(total):
        act = STILL if t < settle else action_after_settle
        env.step(act)

        if t < settle:
            continue
        rec = t - settle

        flock = read_flock(path)
        if flock is None:
            continue
        p = flock.get("player", {}).get("pos")
        if p is not None:
            player_traj[rec] = (p["x"], p["y"], p["z"])
        for s in (flock.get("sheep") or []):
            pos = s["pos"]
            traj.setdefault(s["id"], {})[rec] = (pos["x"], pos["y"], pos["z"])

    env.close()
    return traj, player_traj


def dist(a, b):
    return math.sqrt((a[0] - b[0])**2 + (a[1] - b[1])**2 + (a[2] - b[2])**2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--env-id", type=str, default="Craftium/SheepInfoVL-v0",
                    help="env to run; use Craftium/SheepInfoMG-v0 (works on WSL software GL)")
    ap.add_argument("--num-sheep", type=int, default=50)
    ap.add_argument("--spawn-radius", type=int, default=10)
    ap.add_argument("--settle", type=int, default=60,
                    help="no-op steps before diverging the action (lets the flock spawn identically)")
    ap.add_argument("--record-steps", type=int, default=400,
                    help="steps to record after the settle window")
    ap.add_argument("--epsilon", type=float, default=0.05,
                    help="distance (nodes) above which two paths count as diverged")
    ap.add_argument("--out-dir", type=str, default="divergence_out")
    args = ap.parse_args()

    print("== Run A: player STILL ==")
    trajA, _ = run_episode(STILL, args.seed, args.settle, args.record_steps,
                           args.num_sheep, args.spawn_radius, env_id=args.env_id)
    print("== Run B: player FORWARD ==")
    trajB, playerB = run_episode(FORWARD, args.seed, args.settle, args.record_steps,
                                 args.num_sheep, args.spawn_radius, env_id=args.env_id)

    os.makedirs(args.out_dir, exist_ok=True)
    ids = sorted(set(trajA) & set(trajB))
    print(f"Tracking {len(ids)} sheep present in both runs.")

    # Sanity: how identical are the two runs at the first recorded step (rec=0)?
    init_gap = []
    for i in ids:
        if 0 in trajA[i] and 0 in trajB[i]:
            init_gap.append(dist(trajA[i][0], trajB[i][0]))
    init_max = max(init_gap) if init_gap else float("nan")
    print(f"Initial-state match at settle boundary: max sheep gap = {init_max:.4f} nodes "
          f"({'OK, identical start' if init_max < 1e-6 else 'NOT identical - see note below'})")

    # Per-step mean / max divergence across sheep.
    per_step = []  # (rec, mean, max, n)
    for rec in range(args.record_steps):
        gaps = [dist(trajA[i][rec], trajB[i][rec])
                for i in ids if rec in trajA[i] and rec in trajB[i]]
        if gaps:
            per_step.append((rec, sum(gaps) / len(gaps), max(gaps), len(gaps)))

    with open(os.path.join(args.out_dir, "divergence.csv"), "w") as f:
        f.write("rec_step,mean_gap,max_gap,n_sheep\n")
        for rec, mean, mx, n in per_step:
            f.write(f"{rec},{mean:.6f},{mx:.6f},{n}\n")

    # Per-sheep divergence onset (first rec where gap > epsilon), plus how far that
    # sheep started from the player's forward path (coupling channel indicator).
    onsets = []
    with open(os.path.join(args.out_dir, "divergence_onset.csv"), "w") as f:
        f.write("sheep_id,onset_step,init_dist_to_player\n")
        p0 = playerB.get(0)
        for i in ids:
            onset = ""
            for rec in range(args.record_steps):
                if rec in trajA[i] and rec in trajB[i] and dist(trajA[i][rec], trajB[i][rec]) > args.epsilon:
                    onset = rec
                    onsets.append(rec)
                    break
            d0 = ""
            if p0 is not None and 0 in trajB[i]:
                d0 = f"{dist(trajB[i][0], p0):.2f}"
            f.write(f"{i},{onset},{d0}\n")

    # Headline summary.
    final = per_step[-1] if per_step else (0, float("nan"), float("nan"), 0)
    summary = dict(
        seed=args.seed, settle=args.settle, record_steps=args.record_steps,
        epsilon=args.epsilon, n_sheep_tracked=len(ids),
        initial_max_gap=init_max,
        n_sheep_ever_diverged=len(onsets),
        earliest_onset=(min(onsets) if onsets else None),
        median_onset=(sorted(onsets)[len(onsets)//2] if onsets else None),
        final_mean_gap=final[1], final_max_gap=final[2],
    )
    with open(os.path.join(args.out_dir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)

    print("\n=== SUMMARY ===")
    for k, v in summary.items():
        print(f"  {k}: {v}")

    # Optional plot.
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        recs = [r for r, _, _, _ in per_step]
        means = [m for _, m, _, _ in per_step]
        maxs = [mx for _, _, mx, _ in per_step]
        plt.figure(figsize=(9, 5))
        plt.plot(recs, means, label="mean sheep gap")
        plt.plot(recs, maxs, label="max sheep gap", alpha=0.6)
        plt.xlabel("steps after action diverges")
        plt.ylabel("distance between the two runs (nodes)")
        plt.title("Sheep trajectory divergence: player STILL vs FORWARD (all else pinned)")
        plt.legend()
        plt.tight_layout()
        out_png = os.path.join(args.out_dir, "divergence.png")
        plt.savefig(out_png, dpi=120)
        print(f"\nPlot saved: {out_png}")
    except ImportError:
        print("\n(matplotlib not installed - CSVs written, skipping the plot.)")

    if not (init_max < 1e-6):
        print("\nNOTE: the two runs did not start from a bitwise-identical flock. That itself\n"
              "is a finding: even the pre-settle no-op phase isn't perfectly reproducible on\n"
              "this build (shared global RNG / floating dtime). Increase --settle or pin the\n"
              "timestep to tighten it; the divergence curve still shows the effect.")


if __name__ == "__main__":
    main()
