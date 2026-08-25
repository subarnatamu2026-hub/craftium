"""Demo for the Craftium/SheepNearby-v0 environment.

Spawns a flock of 50 sheep around the agent in Luanti (via Craftium) and drives
the agent for a few hundred steps, slowly panning the camera so you can see the
whole flock. A handful of RGB observation frames are saved as PNGs.

Run it with:

    python sheep_nearby_demo.py                 # 50 sheep (default)
    python sheep_nearby_demo.py --num-sheep 100 # a bigger flock

On a headless machine wrap it in a virtual display, e.g.:

    xvfb-run -a python sheep_nearby_demo.py

(or install `xvfbwrapper` and start an Xvfb display as in run_env_openloop.py).
"""

import argparse
import os

import gymnasium as gym
import craftium  # noqa: F401  (registers the Craftium/* environments)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--num-sheep", type=int, default=50,
                        help="how many sheep to spawn around the agent")
    parser.add_argument("--spawn-radius", type=int, default=10,
                        help="radius (in nodes) the flock is scattered within")
    parser.add_argument("--steps", type=int, default=300,
                        help="number of environment steps to run")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--out-dir", type=str, default="sheep_frames",
                        help="directory to save observation frames into")
    args = parser.parse_args()

    # `minetest_conf` values are written into minetest.conf and read on the Lua
    # side via minetest.settings:get(...). The env's init.lua reads `num_sheep`
    # and `sheep_spawn_radius` from there.
    env = gym.make(
        "Craftium/SheepNearby-v0",
        obs_width=256,
        obs_height=256,
        seed=args.seed,
        minetest_conf=dict(
            num_sheep=args.num_sheep,
            sheep_spawn_radius=args.spawn_radius,
        ),
    )

    observation, info = env.reset()

    os.makedirs(args.out_dir, exist_ok=True)
    saved = []

    def save_frame(obs, name):
        try:
            from PIL import Image
        except ImportError:
            return  # Pillow not installed; skip saving quietly.
        path = os.path.join(args.out_dir, name)
        Image.fromarray(obs).save(path)
        saved.append(path)

    save_frame(observation, "frame_0000.png")

    # The default action wrapper for this env is discrete:
    #   0 forward, 1 left, 2 right, 3 jump,
    #   4 mouse x+, 5 mouse x-, 6 mouse y+, 7 mouse y-
    # We mostly turn the camera (mouse x+) to pan across the flock.
    PAN_RIGHT = 4

    for t in range(1, args.steps + 1):
        action = PAN_RIGHT if t % 2 == 0 else 0  # pan, with occasional NO-OPs
        observation, reward, terminated, truncated, info = env.step(action)

        if t % 50 == 0:
            save_frame(observation, f"frame_{t:04d}.png")

        if terminated or truncated:
            observation, info = env.reset()

    env.close()

    if saved:
        print(f"Saved {len(saved)} frames to '{args.out_dir}/':")
        for p in saved:
            print(f"  {p}")
    else:
        print("Ran the flock demo. (Install Pillow to also save PNG frames.)")


if __name__ == "__main__":
    main()
