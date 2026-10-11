# Harnesses

Scratch pad for LLMs and for quick experiments. Anything in here goes: create, edit, rewrite or delete files freely, nothing depends on them and they are not tests.

- They are the measurement and repro scripts that the notes in `docs/` refer to (`test/harnesses/<name>`). A harness may be stale or broken, the engine and the docs win over it. If one is wrong, fix it or delete it.
- They are allowed to be verbose and to duplicate code. Useful generic parts get promoted into the engine later (see `goluwa/render3d/frame_benchmark.lua` and `test/benchmarks/` for what that looks like), the rest stays here.
- Run them like any script, always with `--background`: `luajit glw --3d --background lua "import('test/harnesses/gmw/run.lua')"`. Use `timeout`, a failed listener can leave the engine running.
- Output (screenshots, logs, profiles) is git-ignored. Write throwaway one-offs to `./tmp/`, put a script here when it is worth keeping for the next session.
- Some scripts still write their output next to themselves or into `tmp/`, and some need game mounts (gmod, Crysis) or the old gm_construct maps.
