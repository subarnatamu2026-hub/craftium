"""Demo for Craftium/SheepInfoVL-v0.

Spawns a flock of sheep (VoxeLibre's mobs_mc:sheep) around the agent. The env's
Lua mod writes the full state of every nearby sheep to `sheep_obs.json` in the
world directory on every step; this script reads that file after each
env.step() and exposes it as `info["sheep"]`.

Each sheep entry looks like:
    {"id": 3, "name": "mobs_mc:sheep", "hp": 8,
     "pos": {"x":.., "y":.., "z":..}, "vel": {"x":.., "y":.., "z":..},
     "yaw": .., "dist": ..}

Run headless with a virtual display, e.g.:
    xvfb-run -a python sheep_info_demo.py
"""

import argparse
import json
import os

import gymnasium as gym
import craftium  # noqa: F401  (registers the Craftium/* environments)


def find_obs_path(env):
    """Locate the sheep_obs.json the Lua mod writes, inside the run's world dir."""
    mt = env.unwrapped.mt
    # world_name isn't stored on the instance; the env uses the default "world".
    world_name = getattr(mt, "world_name", "world")
    return os.path.join(mt.run_dir, "worlds", world_name, "sheep_obs.json")


def read_sheep(obs_path):
    """Read and parse the latest flock observation; return None if unavailable."""
    try:
        with open(obs_path, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        # Not written yet, or caught mid-write. Caller should just try again next step.
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--num-sheep", type=int, default=50)
    parser.add_argument("--spawn-radius", type=int, default=10)
    parser.add_argument("--report-radius", type=int, default=40)
    parser.add_argument("--steps", type=int, default=300)
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    env = gym.make(
        "Craftium/SheepInfoVL-v0",
        obs_width=256,
        obs_height=256,
        seed=args.seed,
        # Use the normal x11 SDL driver rather than "offscreen". This works both
        # with a real display (WSLg / an X server) and under Xvfb, and avoids the
        # "offscreen not available" failure on SDL builds without that driver.
        offscreen_sdl=False,
        minetest_conf=dict(
            num_sheep=args.num_sheep,
            sheep_spawn_radius=args.spawn_radius,
            sheep_report_radius=args.report_radius,
        ),
    )

    observation, info = env.reset()
    obs_path = find_obs_path(env)
    print(f"Reading flock state from: {obs_path}")

    for t in range(1, args.steps + 1):
        action = 4 if t % 2 == 0 else 0  # pan the camera (mouse x+) now and then
        observation, reward, terminated, truncated, info = env.step(action)

        flock = read_sheep(obs_path)
        if flock is not None:
            info["sheep"] = flock["sheep"]          # list of per-sheep dicts
            info["num_sheep"] = flock["num_sheep"]

            if t % 25 == 0:
                sheep = flock["sheep"]
                # Tally how many sheep are in each AI state this step.
                states = {}
                for s in sheep:
                    st = s.get("intent", {}).get("state", "?")
                    states[st] = states.get(st, 0) + 1
                print(f"[step {t}] {flock['num_sheep']} sheep in range | states: {states}")
                if sheep:
                    nearest = min(sheep, key=lambda s: s["dist"])
                    p = nearest["pos"]
                    intent = nearest.get("intent", {})
                    print(f"    nearest: id={nearest['id']} hp={nearest['hp']} "
                          f"dist={nearest['dist']:.1f} "
                          f"pos=({p['x']:.1f},{p['y']:.1f},{p['z']:.1f}) "
                          f"state={intent.get('state')} "
                          f"following={intent.get('following')} fleeing={intent.get('fleeing')}")

        if terminated or truncated:
            observation, info = env.reset()
            obs_path = find_obs_path(env)  # run_dir may change across hard resets

    env.close()


if __name__ == "__main__":
    main()
