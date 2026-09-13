# addons/blocks/

A standalone Block primitive library for Godot 4, vendored into FrogMog as a git
submodule (`TJ-Dev-Studio/blocks`). `README.md` covers what the library is and how
to use it. This file holds what consuming it will not tell you.

**This is a separate repository.** A change here is a commit in the blocks repo
plus a submodule pointer bump in the consumer. The repo ships with zero
dependencies on FrogMog and must stay that way — nothing in `addons/blocks/` may
reference a FrogMog autoload, map, or asset path.

## The two mergers are the performance contract

`BlockMeshMerger` and `BlockCollisionMerger` are physics and render twins of the
same idea: a world of 150k blocks cannot afford a node per block. Both run at
compile time, and both *free* the per-block nodes they absorb.

- **A surviving `MeshInstance3D` means that block was never merged** — a group
  under `MIN_MERGE_BLOCKS` (2), a block carrying a neuron, or a scene visual.
  Freeing it anyway is what made decor vanish on mobile only. Note an extent over
  `MAX_MERGE_EXTENT` (40m) does **not** skip merging: those assemblies are
  bucketed into `CHUNK_SIZE` (16m) chunks and merged per-chunk, and each chunk is
  then subject to the same `MIN_MERGE_BLOCKS` floor.
- **The collision merger collapses to one body per (layer, mask, stairs) group.**
  Every shape and every layer/mask survives; the nodes do not.
- **Neither runs in the Design Studio.** The picker raycasts against a body per
  block, so `keep_collision_for_editor` disables stripping, which gates merging
  too.

## Tint rides in ARRAY_CUSTOM0

A block whose **only** material override is `color_tint` must not get its own
`ShaderMaterial`. Doing so mints one material per `(id, tint)` pair, so every tint
becomes its own merge group and its own draw call — that was 65% of the hub's
mesh outputs before GC-91.

Group those blocks under the **base** material and carry the tint as a vertex
attribute in `ARRAY_CUSTOM0`, where `a = 1` marks "stamped". The consuming shader
reads it in `vertex()` and falls back to the `tint_color` uniform when unstamped.

A block with any *other* override — roughness, metallic, noise — keeps its forked
material. Those genuinely differ.

## Geometry changes are invisible to the cache

The consumer's world cache hashes declared JSON content, not this library's code.
Change how a primitive is **built** — tessellation, subdivision, vertex layout —
and every cached copy keeps the old geometry while reporting success. The
consumer must bump its cache version constant in the same change. Both of the
last two bumps were exactly this: box subdivision, then sphere/dome/capsule
tessellation.

## Size fields are not extents

`size.x` is a **radius** for cylinder, capsule, sphere and dome — it maps straight
to `radius` in `block_builder.gd`. It is a half-extent only for boxes.

## Tests are the gate

800+ tests ship with the library and `/block-test` runs them headlessly. Run them
after any change in `building/`, `core/`, or `physics/` — the mergers in
particular have failure modes that are invisible until a specific world shape hits
them, which is why the suites carry so many fixtures.
