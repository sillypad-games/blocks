extends Node3D
## Test suite for BlockMeshMerger — draw call reduction and internal face culling.
##
## Tests cover:
##   - Basic merge: same-material meshes combined into one draw
##   - Material grouping: different materials → separate merged meshes
##   - Neuron skip: blocks with neurons excluded from merge
##   - Extent limit: assemblies > 40m are chunk-merged, not skipped
##   - Minimum block count: < MIN_MERGE_BLOCKS (2) skip merge
##   - Face culling: touching BoxMesh internal faces removed
##   - Coverage threshold: small blocks don't cull large walls
##   - Non-box shapes: cylinders/spheres skip face culling but still merge
##   - Shadow mode grouping: different shadow modes → separate groups
##   - Edge cases: scene visuals, empty assemblies, single-material groups

var _pass_count := 0
var _fail_count := 0
var _test_count := 0
var _registry: BlockRegistry


func _ready() -> void:
	print("")
	print("=" .repeat(60))
	print("  MESH MERGER TEST SUITE")
	print("=" .repeat(60))

	_registry = BlockRegistry.new()
	add_child(_registry)

	await _test_basic_merge()
	await _test_material_grouping()
	await _test_neuron_skip()
	await _test_extent_limit()
	await _test_min_block_count()
	_test_face_culling_basics()
	_test_face_culling_coverage()
	await _test_non_box_shapes()
	await _test_shadow_mode_grouping()
	await _test_scene_visual_skip()
	await _test_mixed_assembly()
	await _test_edge_cases()
	await _test_override_material_grouping()
	await _test_tint_only_collapses_to_base_material()
	await _test_multi_material_merger_exclusion()
	await _test_seed_stamp()
	await _test_seed_stamp_face_culled()
	await _test_seed_stamp_deterministic()
	await _test_seed_stamp_size_channel()

	print("")
	print("=" .repeat(60))
	var total := _pass_count + _fail_count
	if _fail_count == 0:
		print("  ALL %d TESTS PASSED" % total)
	else:
		print("  %d PASSED, %d FAILED (of %d)" % [_pass_count, _fail_count, total])
	print("=" .repeat(60))
	print("")

	if _fail_count > 0:
		get_tree().quit(1)
	else:
		get_tree().quit(0)


func _assert(condition: bool, test_name: String) -> void:
	_test_count += 1
	if condition:
		_pass_count += 1
		print("  PASS  %s" % test_name)
	else:
		_fail_count += 1
		print("  FAIL  %s" % test_name)


func _section(name: String) -> void:
	print("")
	print("--- %s ---" % name)


## Create a basic box block for testing.
func _make_box(bname: String, size: Vector3, pos: Vector3,
		material: String = "wood", shadow: bool = false) -> Block:
	var b := Block.new()
	b.block_name = bname
	b.category = BlockCategories.STRUCTURE
	b.collision_shape = BlockCategories.SHAPE_BOX
	b.collision_size = size
	b.position = pos
	b.interaction = BlockCategories.INTERACT_SOLID
	b.material_id = material
	b.cast_shadow = shadow
	b.mesh_type = 0
	b.ensure_id()
	return b


## Create a cylinder block for testing.
func _make_cylinder(bname: String, radius: float, height: float,
		pos: Vector3, material: String = "metal_dark") -> Block:
	var b := Block.new()
	b.block_name = bname
	b.category = BlockCategories.PROP
	b.collision_shape = BlockCategories.SHAPE_CYLINDER
	b.collision_size = Vector3(radius, height, 0)
	b.position = pos
	b.interaction = BlockCategories.INTERACT_SOLID
	b.material_id = material
	b.mesh_type = 0
	b.ensure_id()
	return b


## Create a sphere block for testing.
func _make_sphere(bname: String, radius: float,
		pos: Vector3, material: String = "stone") -> Block:
	var b := Block.new()
	b.block_name = bname
	b.category = BlockCategories.PROP
	b.collision_shape = BlockCategories.SHAPE_SPHERE
	b.collision_size = Vector3(radius, radius * 2.0, 0)
	b.position = pos
	b.interaction = BlockCategories.INTERACT_SOLID
	b.material_id = material
	b.mesh_type = 0
	b.ensure_id()
	return b


## Build blocks under an assembly root, register them, and run the merger.
## Returns the assembly root Node3D for inspection.
func _build_assembly(blocks: Array, run_merge: bool = true) -> Node3D:
	var asm_root := Node3D.new()
	asm_root.name = "TestAssembly"
	add_child(asm_root)

	for block: Block in blocks:
		_registry.register(block)
		BlockBuilder.build(block, asm_root)

	if run_merge:
		BlockMeshMerger.merge(asm_root, blocks)

	return asm_root


## Count MeshInstance3D children (direct + nested under block roots).
func _count_mesh_instances(parent: Node3D) -> int:
	var count := 0
	for child in parent.get_children():
		if child is MeshInstance3D:
			count += 1
		# Also check inside block root nodes (Node3D > Mesh)
		if child is Node3D and not child is MeshInstance3D:
			for grandchild in child.get_children():
				if grandchild is MeshInstance3D:
					count += 1
	return count


## Count only "Merged_*" MeshInstance3D nodes.
func _count_merged_meshes(parent: Node3D) -> int:
	var count := 0
	for child in parent.get_children():
		if child is MeshInstance3D and child.name.begins_with("Merged_"):
			count += 1
	return count


## Count surviving original "Mesh" nodes (not freed by merger).
func _count_original_meshes(parent: Node3D) -> int:
	var count := 0
	for child in parent.get_children():
		if child is Node3D and not child is MeshInstance3D:
			var mesh_node := child.get_node_or_null("Mesh")
			if mesh_node != null and is_instance_valid(mesh_node):
				# Check if it's not pending deletion
				if not mesh_node.is_queued_for_deletion():
					count += 1
	return count


## Clean up assembly root and registry between test groups.
func _cleanup(asm_root: Node3D) -> void:
	if asm_root and is_instance_valid(asm_root):
		asm_root.queue_free()
	_registry.clear()


# =========================================================================
# Test Groups
# =========================================================================


func _test_basic_merge() -> void:
	_section("Basic Merge")

	# 4 same-material box blocks → should merge into 1 merged mesh
	var blocks: Array = []
	for i in range(4):
		blocks.append(_make_box("wall_%d" % i, Vector3(2, 3, 0.5),
			Vector3(i * 2.5, 0, 0), "wood"))

	var asm := _build_assembly(blocks)

	# Allow one frame for queue_free to process
	await get_tree().process_frame

	var merged := _count_merged_meshes(asm)
	_assert(merged == 1, "4 same-material blocks → 1 merged mesh")

	var originals := _count_original_meshes(asm)
	_assert(originals == 0, "original mesh nodes freed after merge")

	# Merged mesh should have the correct material
	for child in asm.get_children():
		if child is MeshInstance3D and child.name.begins_with("Merged_"):
			_assert(child.material_override != null, "merged mesh has material override")
			_assert(child.mesh != null, "merged mesh has valid mesh")
			_assert(child.mesh is ArrayMesh, "merged mesh is ArrayMesh")

	# Collision bodies should still exist (merger only touches visuals)
	var body_count := 0
	for block: Block in blocks:
		if block.node and is_instance_valid(block.node):
			var body := block.node.get_node_or_null("Body")
			if body != null:
				body_count += 1
	_assert(body_count == 4, "all 4 collision bodies preserved")

	_cleanup(asm)


func _test_material_grouping() -> void:
	_section("Material Grouping")

	# 6 blocks: 3 wood + 3 stone → should produce 2 merged meshes
	var blocks: Array = []
	for i in range(3):
		blocks.append(_make_box("wood_%d" % i, Vector3(2, 3, 0.5),
			Vector3(i * 2.5, 0, 0), "wood"))
	for i in range(3):
		blocks.append(_make_box("stone_%d" % i, Vector3(2, 3, 0.5),
			Vector3(i * 2.5, 0, 5), "stone"))

	var asm := _build_assembly(blocks)
	await get_tree().process_frame

	var merged := _count_merged_meshes(asm)
	_assert(merged == 2, "2 materials → 2 merged meshes")

	_cleanup(asm)


func _test_neuron_skip() -> void:
	_section("Neuron Skip")

	# 4 blocks, 1 has a neuron → neuron block excluded from merge
	var blocks: Array = []
	for i in range(4):
		var b := _make_box("block_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 3, 0, 0), "wood")
		if i == 2:
			# Attach a stub neuron (any non-null value triggers skip)
			b.neuron = RefCounted.new()
		blocks.append(b)

	var asm := _build_assembly(blocks)
	await get_tree().process_frame

	# 3 mergeable blocks → 1 merged mesh, neuron block keeps its Mesh.
	# MIN_MERGE_BLOCKS is 2, so 3 mergeable blocks clear the floor.
	var merged := _count_merged_meshes(asm)
	_assert(merged == 1, "3 mergeable blocks (>= MIN_MERGE_BLOCKS=2) → 1 merged mesh")

	_cleanup(asm)

	# Now test with 5 blocks, 1 has neuron → 4 mergeable
	blocks.clear()
	for i in range(5):
		var b := _make_box("block_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 3, 0, 0), "wood")
		if i == 3:
			b.neuron = RefCounted.new()
		blocks.append(b)

	asm = _build_assembly(blocks)
	await get_tree().process_frame

	merged = _count_merged_meshes(asm)
	_assert(merged == 1, "5 blocks (1 neuron) → 4 mergeable → 1 merged mesh")

	# The neuron block should keep its original mesh
	var neuron_block: Block = blocks[3]
	if neuron_block.node and is_instance_valid(neuron_block.node):
		var mesh_node := neuron_block.node.get_node_or_null("Mesh")
		_assert(mesh_node != null and is_instance_valid(mesh_node)
			and not mesh_node.is_queued_for_deletion(),
			"neuron block preserves its original Mesh node")
	else:
		_assert(false, "neuron block preserves its original Mesh node")

	_cleanup(asm)


func _test_extent_limit() -> void:
	_section("Extent Limit")

	# Blocks spread over > 40m are no longer skipped — they are bucketed into
	# CHUNK_SIZE (16m) spatial chunks and merged per-chunk, so each merged AABB
	# stays small enough for visibility_range culling.
	#   x = 0, 10, 20, 30, 40, 50  →  chunk cx = floor(x / 16)
	#   chunk 0: [0, 10]   2 blocks → merges  (>= MIN_MERGE_BLOCKS)
	#   chunk 1: [20, 30]  2 blocks → merges
	#   chunk 2: [40]      1 block  → below the floor, left unmerged
	#   chunk 3: [50]      1 block  → below the floor, left unmerged
	# So this one layout covers both chunking rules at once.
	var blocks: Array = []
	for i in range(6):
		blocks.append(_make_box("spread_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 10, 0, 0), "wood"))  # spans 50m

	var asm := _build_assembly(blocks)
	await get_tree().process_frame

	var merged := _count_merged_meshes(asm)
	_assert(merged == 2, "assembly > 40m extent → chunk-merged (2 full chunks, 2 singletons skipped)")

	_cleanup(asm)

	# Blocks within 40m → should merge
	blocks.clear()
	for i in range(6):
		blocks.append(_make_box("close_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 5, 0, 0), "wood"))  # spans 25m

	asm = _build_assembly(blocks)
	await get_tree().process_frame

	merged = _count_merged_meshes(asm)
	_assert(merged == 1, "assembly within 40m → merge succeeds")

	_cleanup(asm)


func _test_min_block_count() -> void:
	_section("Minimum Block Count")

	# 1 block → below MIN_MERGE_BLOCKS (2) → no merge. This is the only case
	# left that actually exercises the floor; merging 1 mesh into 1 saves nothing.
	var blocks: Array = []
	blocks.append(_make_box("lone", Vector3(2, 2, 2), Vector3.ZERO, "wood"))

	var asm := _build_assembly(blocks)
	await get_tree().process_frame

	var merged := _count_merged_meshes(asm)
	_assert(merged == 0, "1 block (< MIN_MERGE_BLOCKS=2) → no merge")

	_cleanup(asm)

	# 3 blocks → at/above MIN_MERGE_BLOCKS (2) → merge
	blocks.clear()
	for i in range(3):
		blocks.append(_make_box("small_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 3, 0, 0), "wood"))

	asm = _build_assembly(blocks)
	await get_tree().process_frame

	merged = _count_merged_meshes(asm)
	_assert(merged == 1, "3 blocks (>= MIN_MERGE_BLOCKS=2) → merge triggers")

	_cleanup(asm)

	# Exactly 4 blocks → should merge
	blocks.clear()
	for i in range(4):
		blocks.append(_make_box("exact_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 3, 0, 0), "wood"))

	asm = _build_assembly(blocks)
	await get_tree().process_frame

	merged = _count_merged_meshes(asm)
	_assert(merged == 1, "exactly 4 blocks → merge triggers")

	_cleanup(asm)


func _test_face_culling_basics() -> void:
	_section("Face Culling — Basics")

	# Two touching boxes side-by-side on X axis
	# Box A: pos (0,0,0) size (2,2,2) → X range [-1, 1]
	# Box B: pos (2,0,0) size (2,2,2) → X range [1, 3]
	# A's +X face touches B's -X face at x=1
	var blocks: Array = []
	blocks.append(_make_box("a", Vector3(2, 2, 2), Vector3(0, 0, 0), "wood"))
	blocks.append(_make_box("b", Vector3(2, 2, 2), Vector3(2, 0, 0), "wood"))
	# Need 4 blocks for merge, add 2 more non-touching
	blocks.append(_make_box("c", Vector3(2, 2, 2), Vector3(0, 0, 10), "wood"))
	blocks.append(_make_box("d", Vector3(2, 2, 2), Vector3(2, 0, 10), "wood"))

	# Call face culling directly to inspect results
	var meshes: Array = []
	for block: Block in blocks:
		_registry.register(block)
		BlockBuilder.build(block, self)
		var mesh_inst := block.node.get_node_or_null("Mesh") as MeshInstance3D
		if mesh_inst and mesh_inst.mesh:
			meshes.append({
				"mesh": mesh_inst.mesh,
				"transform": block.node.transform * mesh_inst.transform,
				"node": mesh_inst,
				"shape": block.collision_shape,
			})

	var culled := BlockMeshMerger._find_culled_faces(meshes)
	_assert(not culled.is_empty(), "touching boxes detected internal faces")

	# First pair (index 0 and 1) should have culled faces
	var has_0 := culled.has(0)
	var has_1 := culled.has(1)
	_assert(has_0 or has_1, "at least one of the touching pair has culled faces")

	# Second pair (index 2 and 3) should also have culled faces
	var has_2 := culled.has(2)
	var has_3 := culled.has(3)
	_assert(has_2 or has_3, "second touching pair also has culled faces")

	# Non-adjacent pairs should NOT cull each other (0 and 2 are 10m apart)
	# Verify by checking that culled normals for block 0 are only from block 1
	if has_0:
		var normals: Array = culled[0]
		_assert(normals.size() <= 1, "block 0 has at most 1 culled face direction")

	# Clean up built nodes
	for block: Block in blocks:
		if block.node and is_instance_valid(block.node):
			block.node.queue_free()
	_registry.clear()

	# Stacked boxes on Y axis
	var stack_blocks: Array = []
	stack_blocks.append(_make_box("bottom", Vector3(2, 2, 2), Vector3(0, 0, 0), "wood"))
	stack_blocks.append(_make_box("top", Vector3(2, 2, 2), Vector3(0, 2, 0), "wood"))
	stack_blocks.append(_make_box("pad1", Vector3(2, 2, 2), Vector3(10, 0, 0), "wood"))
	stack_blocks.append(_make_box("pad2", Vector3(2, 2, 2), Vector3(10, 2, 0), "wood"))

	var stack_meshes: Array = []
	for block: Block in stack_blocks:
		_registry.register(block)
		BlockBuilder.build(block, self)
		var mesh_inst := block.node.get_node_or_null("Mesh") as MeshInstance3D
		if mesh_inst and mesh_inst.mesh:
			stack_meshes.append({
				"mesh": mesh_inst.mesh,
				"transform": block.node.transform * mesh_inst.transform,
				"node": mesh_inst,
				"shape": block.collision_shape,
			})

	var stack_culled := BlockMeshMerger._find_culled_faces(stack_meshes)
	_assert(not stack_culled.is_empty(), "vertically stacked boxes detect internal faces")

	for block: Block in stack_blocks:
		if block.node and is_instance_valid(block.node):
			block.node.queue_free()
	_registry.clear()


func _test_face_culling_coverage() -> void:
	_section("Face Culling — Coverage Threshold")

	# Small block next to large block — shouldn't cull the large face
	# Large wall: 6m × 6m × 0.5m at origin
	# Small baseboard: 0.3m × 0.3m × 0.5m touching the wall
	# Coverage: 0.3/6 = 5% — way below 75% threshold
	var blocks: Array = []
	blocks.append(_make_box("big_wall", Vector3(6, 6, 0.5), Vector3(0, 0, 0), "wood"))
	blocks.append(_make_box("baseboard", Vector3(0.3, 0.3, 0.5), Vector3(3.15, -2.85, 0), "wood"))
	blocks.append(_make_box("pad1", Vector3(2, 2, 0.5), Vector3(0, 0, 5), "wood"))
	blocks.append(_make_box("pad2", Vector3(2, 2, 0.5), Vector3(3, 0, 5), "wood"))

	var meshes: Array = []
	for block: Block in blocks:
		_registry.register(block)
		BlockBuilder.build(block, self)
		var mesh_inst := block.node.get_node_or_null("Mesh") as MeshInstance3D
		if mesh_inst and mesh_inst.mesh:
			meshes.append({
				"mesh": mesh_inst.mesh,
				"transform": block.node.transform * mesh_inst.transform,
				"node": mesh_inst,
				"shape": block.collision_shape,
			})

	var culled := BlockMeshMerger._find_culled_faces(meshes)

	# The big wall (index 0) should NOT have its face culled by the baseboard
	# (baseboard covers only ~5% of the wall face, well below 75% threshold)
	var big_wall_culled: bool = culled.has(0) and (culled[0] as Array).size() > 0
	_assert(not big_wall_culled, "big wall face not culled by small baseboard (coverage < 75%)")

	# The baseboard (index 1) CAN have its face culled by the wall
	# because the wall covers 100% of the baseboard's face
	# But only if they're actually touching
	# This depends on exact positioning

	for block: Block in blocks:
		if block.node and is_instance_valid(block.node):
			block.node.queue_free()
	_registry.clear()


func _test_non_box_shapes() -> void:
	_section("Non-Box Shapes")

	# Cylinders and spheres should NOT participate in face culling
	# but SHOULD still be merged by material
	var blocks: Array = []
	blocks.append(_make_cylinder("cyl_0", 0.5, 3.0, Vector3(0, 0, 0), "metal_dark"))
	blocks.append(_make_cylinder("cyl_1", 0.5, 3.0, Vector3(1.0, 0, 0), "metal_dark"))
	blocks.append(_make_cylinder("cyl_2", 0.5, 3.0, Vector3(2.0, 0, 0), "metal_dark"))
	blocks.append(_make_cylinder("cyl_3", 0.5, 3.0, Vector3(3.0, 0, 0), "metal_dark"))

	# Test face culling directly — should return empty (no boxes)
	var meshes: Array = []
	for block: Block in blocks:
		_registry.register(block)
		BlockBuilder.build(block, self)
		var mesh_inst := block.node.get_node_or_null("Mesh") as MeshInstance3D
		if mesh_inst and mesh_inst.mesh:
			meshes.append({
				"mesh": mesh_inst.mesh,
				"transform": block.node.transform * mesh_inst.transform,
				"node": mesh_inst,
				"shape": block.collision_shape,
			})

	var culled := BlockMeshMerger._find_culled_faces(meshes)
	_assert(culled.is_empty(), "cylinders produce no culled faces")

	for block: Block in blocks:
		if block.node and is_instance_valid(block.node):
			block.node.queue_free()
	_registry.clear()

	# But they should still merge into combined meshes
	blocks.clear()
	for i in range(4):
		blocks.append(_make_cylinder("cyl_%d" % i, 0.5, 3.0,
			Vector3(i * 2, 0, 0), "metal_dark"))

	var asm := _build_assembly(blocks)
	await get_tree().process_frame

	var merged := _count_merged_meshes(asm)
	_assert(merged == 1, "4 same-material cylinders → 1 merged mesh")

	_cleanup(asm)

	# Mixed shapes same material
	blocks.clear()
	blocks.append(_make_box("box", Vector3(2, 2, 2), Vector3(0, 0, 0), "stone"))
	blocks.append(_make_cylinder("cyl", 0.5, 3.0, Vector3(3, 0, 0), "stone"))
	blocks.append(_make_sphere("sph", 1.0, Vector3(6, 0, 0), "stone"))
	blocks.append(_make_box("box2", Vector3(2, 2, 2), Vector3(9, 0, 0), "stone"))

	asm = _build_assembly(blocks)
	await get_tree().process_frame

	merged = _count_merged_meshes(asm)
	_assert(merged == 1, "mixed shapes same material → 1 merged mesh")

	_cleanup(asm)


func _test_shadow_mode_grouping() -> void:
	_section("Shadow Mode Grouping")

	# Blocks with different shadow settings should NOT merge together
	var blocks: Array = []
	blocks.append(_make_box("shadow_0", Vector3(2, 2, 2), Vector3(0, 0, 0), "wood", true))
	blocks.append(_make_box("shadow_1", Vector3(2, 2, 2), Vector3(3, 0, 0), "wood", true))
	blocks.append(_make_box("noshadow_0", Vector3(2, 2, 2), Vector3(6, 0, 0), "wood", false))
	blocks.append(_make_box("noshadow_1", Vector3(2, 2, 2), Vector3(9, 0, 0), "wood", false))

	var asm := _build_assembly(blocks)
	await get_tree().process_frame

	var merged := _count_merged_meshes(asm)
	_assert(merged == 2, "same material but different shadow modes → 2 merged meshes")

	_cleanup(asm)


func _test_scene_visual_skip() -> void:
	_section("Scene Visual Skip")

	# mesh_type == 1 (scene visuals) should never be merged
	var blocks: Array = []
	for i in range(4):
		var b := _make_box("scene_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 3, 0, 0), "wood")
		b.mesh_type = 1  # scene visual
		blocks.append(b)

	var asm_root := Node3D.new()
	asm_root.name = "SceneAssembly"
	add_child(asm_root)

	for block: Block in blocks:
		_registry.register(block)
		# Build manually — scene visuals won't create Mesh nodes without actual scenes
		var root := Node3D.new()
		root.name = block.block_name
		root.position = block.position
		asm_root.add_child(root)
		block.node = root

	BlockMeshMerger.merge(asm_root, blocks)
	await get_tree().process_frame

	var merged := _count_merged_meshes(asm_root)
	_assert(merged == 0, "scene visual blocks (mesh_type=1) never merged")

	_cleanup(asm_root)


func _test_mixed_assembly() -> void:
	_section("Mixed Assembly — Real-World Simulation")

	# Simulate a small building: walls, floor, decorative cylinders, neuron light
	var blocks: Array = []

	# 4 walls — same material "stone"
	blocks.append(_make_box("wall_n", Vector3(6, 3, 0.3), Vector3(0, 1.5, -3), "stone"))
	blocks.append(_make_box("wall_s", Vector3(6, 3, 0.3), Vector3(0, 1.5, 3), "stone"))
	blocks.append(_make_box("wall_e", Vector3(0.3, 3, 6), Vector3(3, 1.5, 0), "stone"))
	blocks.append(_make_box("wall_w", Vector3(0.3, 3, 6), Vector3(-3, 1.5, 0), "stone"))

	# Floor — same material
	blocks.append(_make_box("floor", Vector3(6, 0.3, 6), Vector3(0, 0, 0), "stone"))

	# 2 pillars — different material "bark"
	blocks.append(_make_cylinder("pillar_1", 0.3, 3.0, Vector3(-2, 1.5, -2), "bark"))
	blocks.append(_make_cylinder("pillar_2", 0.3, 3.0, Vector3(2, 1.5, -2), "bark"))

	# 1 lantern with neuron — should be excluded
	var lantern := _make_sphere("lantern", 0.2, Vector3(0, 2.8, 0), "glow_yellow")
	lantern.neuron = RefCounted.new()
	blocks.append(lantern)

	var asm := _build_assembly(blocks)
	await get_tree().process_frame

	var merged := _count_merged_meshes(asm)
	# 5 stone blocks → 1 merged (stone)
	# 2 bark cylinders → 1 group but < 2 can still be in same material group
	# Wait — 2 is < MIN_MERGE_BLOCKS? No, MIN_MERGE_BLOCKS is for the WHOLE assembly
	# The whole assembly has 7 mergeable blocks (8 total - 1 neuron)
	# Material groups: stone=5, bark=2, glow_yellow=0 (neuron skip)
	# stone group: 5 meshes → merge → 1 merged mesh
	# bark group: 2 meshes → still < 2 entries → skip (need >= 2 per group)
	# Wait, the code checks per-group: "if meshes.size() < 2: continue"
	# So bark group with 2 entries → will merge
	_assert(merged == 2, "building: 5 stone + 2 bark → 2 merged meshes (lantern excluded)")

	# Lantern should keep its mesh
	if lantern.node and is_instance_valid(lantern.node):
		var mesh_node := lantern.node.get_node_or_null("Mesh")
		_assert(mesh_node != null and not mesh_node.is_queued_for_deletion(),
			"neuron lantern keeps its original mesh")
	else:
		_assert(false, "neuron lantern keeps its original mesh")

	_cleanup(asm)


func _test_edge_cases() -> void:
	_section("Edge Cases")

	# Empty blocks array
	var asm_root := Node3D.new()
	asm_root.name = "EmptyAsm"
	add_child(asm_root)
	var empty_blocks: Array = []
	BlockMeshMerger.merge(asm_root, empty_blocks)
	_assert(_count_merged_meshes(asm_root) == 0, "empty blocks array → no crash, no merge")
	_cleanup(asm_root)

	# Single block → below minimum
	var single_blocks: Array = [_make_box("lone", Vector3(2, 2, 2), Vector3.ZERO, "wood")]
	asm_root = Node3D.new()
	asm_root.name = "SingleAsm"
	add_child(asm_root)
	_registry.register(single_blocks[0])
	BlockBuilder.build(single_blocks[0], asm_root)
	BlockMeshMerger.merge(asm_root, single_blocks)
	_assert(_count_merged_meshes(asm_root) == 0, "single block → no merge")
	_cleanup(asm_root)

	# All blocks have neurons → nothing mergeable
	var neuron_blocks: Array = []
	for i in range(6):
		var b := _make_box("neuron_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 3, 0, 0), "wood")
		b.neuron = RefCounted.new()
		neuron_blocks.append(b)

	asm_root = Node3D.new()
	asm_root.name = "AllNeuronAsm"
	add_child(asm_root)
	for block: Block in neuron_blocks:
		_registry.register(block)
		BlockBuilder.build(block, asm_root)
	BlockMeshMerger.merge(asm_root, neuron_blocks)
	await get_tree().process_frame
	_assert(_count_merged_meshes(asm_root) == 0, "all neuron blocks → no merge")
	_cleanup(asm_root)

	# Blocks with no material override → should skip gracefully
	var no_mat_blocks: Array = []
	for i in range(4):
		var b := _make_box("nomat_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 3, 0, 0), "")
		no_mat_blocks.append(b)

	asm_root = _build_assembly(no_mat_blocks)
	await get_tree().process_frame
	# Should not crash — verify merge ran without error by checking node tree is intact
	var children_ok := asm_root.get_child_count() > 0
	_assert(children_ok, "blocks with empty material_id → no crash, assembly intact")
	_cleanup(asm_root)

	# Blocks with SHAPE_NONE → no mesh built, no merge
	var shapeless: Array = []
	for i in range(4):
		var b := Block.new()
		b.block_name = "shapeless_%d" % i
		b.category = BlockCategories.PROP
		b.collision_shape = BlockCategories.SHAPE_NONE
		b.collision_size = Vector3(2, 2, 2)
		b.position = Vector3(i * 3, 0, 0)
		b.interaction = BlockCategories.INTERACT_NONE
		b.material_id = "wood"
		b.mesh_type = 0
		b.ensure_id()
		shapeless.append(b)

	asm_root = Node3D.new()
	asm_root.name = "ShapelessAsm"
	add_child(asm_root)
	for block: Block in shapeless:
		_registry.register(block)
		BlockBuilder.build(block, asm_root)
	BlockMeshMerger.merge(asm_root, shapeless)
	await get_tree().process_frame
	_assert(_count_merged_meshes(asm_root) == 0, "SHAPE_NONE blocks → no mesh, no merge")
	_cleanup(asm_root)

	# Boundary: exactly 40m extent → should merge
	var boundary_blocks: Array = []
	boundary_blocks.append(_make_box("start", Vector3(2, 2, 2), Vector3(0, 0, 0), "wood"))
	boundary_blocks.append(_make_box("mid1", Vector3(2, 2, 2), Vector3(13, 0, 0), "wood"))
	boundary_blocks.append(_make_box("mid2", Vector3(2, 2, 2), Vector3(26, 0, 0), "wood"))
	boundary_blocks.append(_make_box("end", Vector3(2, 2, 2), Vector3(39, 0, 0), "wood"))
	# Extent = 39m (max_x - min_x) → within 40m limit

	asm_root = _build_assembly(boundary_blocks)
	await get_tree().process_frame
	var merged := _count_merged_meshes(asm_root)
	_assert(merged == 1, "39m extent (just under 40m limit) → merge succeeds")
	_cleanup(asm_root)

	# Just over 40m → crosses into the chunked path rather than being skipped.
	#   x = 0, 14, 28, 41  →  chunk cx = floor(x / 16)
	#   chunk 0: [0, 14]  2 blocks → merges
	#   chunk 1: [28]     1 block  → below MIN_MERGE_BLOCKS, left unmerged
	#   chunk 2: [41]     1 block  → below MIN_MERGE_BLOCKS, left unmerged
	var over_blocks: Array = []
	over_blocks.append(_make_box("start", Vector3(2, 2, 2), Vector3(0, 0, 0), "wood"))
	over_blocks.append(_make_box("mid1", Vector3(2, 2, 2), Vector3(14, 0, 0), "wood"))
	over_blocks.append(_make_box("mid2", Vector3(2, 2, 2), Vector3(28, 0, 0), "wood"))
	over_blocks.append(_make_box("end", Vector3(2, 2, 2), Vector3(41, 0, 0), "wood"))
	# Extent = 41m → over MAX_MERGE_EXTENT, so chunk-merged

	asm_root = _build_assembly(over_blocks)
	await get_tree().process_frame
	merged = _count_merged_meshes(asm_root)
	_assert(merged == 1, "41m extent (over MAX_MERGE_EXTENT) → chunk-merged, not skipped")
	_cleanup(asm_root)


func _test_override_material_grouping() -> void:
	_section("Override Material Grouping (Phase 9-02)")

	# 6 blocks total, all "bark" material but 3 distinct override combos:
	#   Group A: roughness=0.9  (2 blocks) → same override key → same instance → same group
	#   Group B: no overrides   (2 blocks) → base cache instance → different group from A
	#   Group C: roughness=0.5  (2 blocks) → different key from A → different group
	# Expect: 3 merged meshes (one per unique material instance)
	var blocks: Array = []

	for i in range(2):
		var b := _make_box("override_a_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 3, 0, 0), "bark")
		b.material_params = {"roughness": 0.9}
		blocks.append(b)

	for i in range(2):
		var b := _make_box("base_b_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 3, 0, 5), "bark")
		# No overrides — will use base cache instance
		blocks.append(b)

	for i in range(2):
		var b := _make_box("override_c_%d" % i, Vector3(2, 2, 2),
			Vector3(i * 3, 0, 10), "bark")
		b.material_params = {"roughness": 0.5}
		blocks.append(b)

	var asm := _build_assembly(blocks)
	await get_tree().process_frame

	var merged := _count_merged_meshes(asm)
	_assert(merged == 3, "6 blocks with 3 distinct override combos → 3 merged meshes")

	# Verify each merged mesh has a distinct material instance
	var mat_ids: Array = []
	for child in asm.get_children():
		if child is MeshInstance3D and child.name.begins_with("Merged_"):
			mat_ids.append(child.material_override.get_instance_id())
	_assert(mat_ids.size() == 3, "3 merged meshes found in assembly root")
	# All three material instances must be distinct
	var unique_ids := {}
	for mid in mat_ids:
		unique_ids[mid] = true
	_assert(unique_ids.size() == 3, "all 3 merged meshes have distinct material instances")

	# Additional check: blocks with identical override keys share same instance
	# Build two separate blocks with identical params and verify merger would group them
	var b_check1 := _make_box("check1", Vector3(2, 2, 2), Vector3(0, 0, 20), "bark")
	b_check1.material_params = {"roughness": 0.9}
	var b_check2 := _make_box("check2", Vector3(2, 2, 2), Vector3(3, 0, 20), "bark")
	b_check2.material_params = {"roughness": 0.9}
	var parent := Node3D.new()
	add_child(parent)
	_registry.register(b_check1)
	_registry.register(b_check2)
	BlockBuilder.build(b_check1, parent)
	BlockBuilder.build(b_check2, parent)
	var mi1 := b_check1.node.get_node_or_null("Mesh") as MeshInstance3D
	var mi2 := b_check2.node.get_node_or_null("Mesh") as MeshInstance3D
	_assert(mi1 != null and mi2 != null, "override grouping: check blocks built")
	_assert(mi1.material_override == mi2.material_override,
		"override grouping: identical params → same material instance → same merger group key")
	parent.queue_free()

	# Verify blocks with DIFFERENT override params get different instances (different group keys)
	var b_diff1 := _make_box("diff1", Vector3(2, 2, 2), Vector3(0, 0, 25), "bark")
	b_diff1.material_params = {"roughness": 0.3}
	var b_diff2 := _make_box("diff2", Vector3(2, 2, 2), Vector3(3, 0, 25), "bark")
	b_diff2.material_params = {"roughness": 0.8}
	var parent2 := Node3D.new()
	add_child(parent2)
	_registry.register(b_diff1)
	_registry.register(b_diff2)
	BlockBuilder.build(b_diff1, parent2)
	BlockBuilder.build(b_diff2, parent2)
	var mi_d1 := b_diff1.node.get_node_or_null("Mesh") as MeshInstance3D
	var mi_d2 := b_diff2.node.get_node_or_null("Mesh") as MeshInstance3D
	_assert(mi_d1 != null and mi_d2 != null, "override diff: check blocks built")
	_assert(mi_d1.material_override != mi_d2.material_override,
		"override diff: different params → different material instances → different merger group keys")
	parent2.queue_free()

	_cleanup(asm)


# =========================================================================
# Phase 12-02: Multi-material merger exclusion (MMTL-03)
# =========================================================================

func _test_multi_material_merger_exclusion() -> void:
	_section("Multi-Material Merger Exclusion (Phase 12-02 MMTL-03)")

	# 5 same-material box blocks. The 5th has a non-empty materials_list.
	# Merger should skip the 5th → only 4 eligible → should produce 1 merged mesh.
	# The 5th block's "Mesh" node must survive (not be freed by merger).
	var blocks: Array = []
	for i in range(4):
		blocks.append(_make_box(
			"mm_excl_%d" % i,
			Vector3(2, 2, 2),
			Vector3(i * 2.5, 0, 0),
			"wood"
		))

	# 5th block with multi-material — same base material_id but non-empty materials_list
	var mm_block := _make_box("mm_excl_multi", Vector3(2, 2, 2), Vector3(10, 0, 0), "wood")
	mm_block.materials_list = [
		{"palette_key": "metal_dark"},
		{"palette_key": "glow_yellow"}
	]
	blocks.append(mm_block)

	# Build all 5 — use run_merge=false so we can inspect before merge
	var asm_root := Node3D.new()
	asm_root.name = "MMExclusionTest"
	add_child(asm_root)
	for block: Block in blocks:
		_registry.register(block)
		BlockBuilder.build(block, asm_root)

	# Verify mm_block was built and has a Mesh node
	var mm_mesh_before: Node = mm_block.node.get_node_or_null("Mesh") if mm_block.node != null else null
	_assert(mm_mesh_before != null, "MMTL-03: multi-material block has 'Mesh' node before merge")

	# Now run the merger
	BlockMeshMerger.merge(asm_root, blocks)
	await get_tree().process_frame

	# Merged mesh count: only 4 single-material blocks qualify → 1 merged mesh
	var merged := _count_merged_meshes(asm_root)
	_assert(merged == 1,
		"MMTL-03: 4 single-material + 1 multi-material → 1 merged mesh (multi excluded)")

	# The multi-material block's Mesh node should still exist (not freed by merger)
	var mm_mesh_after: Node = mm_block.node.get_node_or_null("Mesh") if mm_block.node != null else null
	_assert(mm_mesh_after != null and is_instance_valid(mm_mesh_after) and not mm_mesh_after.is_queued_for_deletion(),
		"MMTL-03: multi-material block 'Mesh' node survives merge (not freed)")

	_cleanup(asm_root)


# --- GC-93: per-block seed stamp -------------------------------------------


## Fetch the vertex COLOR array of the first Merged_* mesh under a root.
## Returns an empty array if the surface carries no colours at all, which is
## itself the failure the tests below are watching for: _stamp_seeds() bails out
## (leaving no ARRAY_COLOR) whenever its vertex accounting disagrees with what
## SurfaceTool actually committed.
func _merged_colors(parent: Node3D) -> PackedColorArray:
	for child in parent.get_children():
		if child is MeshInstance3D and child.name.begins_with("Merged_"):
			var mesh: Mesh = (child as MeshInstance3D).mesh
			if mesh == null or mesh.get_surface_count() == 0:
				return PackedColorArray()
			var arrays: Array = mesh.surface_get_arrays(0)
			if arrays.size() <= Mesh.ARRAY_COLOR or arrays[Mesh.ARRAY_COLOR] == null:
				return PackedColorArray()
			return arrays[Mesh.ARRAY_COLOR]
	return PackedColorArray()


## Vertex count of the first Merged_* mesh, for span-accounting checks.
func _merged_vertex_count(parent: Node3D) -> int:
	for child in parent.get_children():
		if child is MeshInstance3D and child.name.begins_with("Merged_"):
			var mesh: Mesh = (child as MeshInstance3D).mesh
			if mesh == null or mesh.get_surface_count() == 0:
				return 0
			return mesh.surface_get_array_len(0)
	return 0


func _test_seed_stamp() -> void:
	_section("GC-93 per-block seed stamp")

	# Two same-material boxes, far enough apart that no face culling triggers —
	# this exercises the append_from() fast path.
	var blocks: Array = [
		_make_box("seed_a", Vector3(1, 1, 1), Vector3(0, 0, 0)),
		_make_box("seed_b", Vector3(1, 1, 1), Vector3(6, 0, 0)),
	]
	var asm_root := _build_assembly(blocks)
	await get_tree().process_frame

	var colors := _merged_colors(asm_root)
	var vcount := _merged_vertex_count(asm_root)

	# An empty colour array means _stamp_seeds() refused to stamp — its span
	# accounting did not match the committed surface. That is the single
	# assumption this whole feature rests on (append_from appends exactly the
	# source's vertex count), so it gets its own assertion.
	_assert(colors.size() > 0, "GC93-01: merged mesh carries a vertex COLOR array")
	_assert(colors.size() == vcount,
		"GC93-02: colour count %d matches committed vertex count %d" % [colors.size(), vcount])

	# Alpha is the "stamped" marker — unstamped geometry defaults to white.
	var all_marked := true
	for c: Color in colors:
		if c.a > 0.01:
			all_marked = false
			break
	_assert(all_marked, "GC93-03: every stamped vertex carries a == 0.0")

	# The point of the whole change: two blocks in ONE merged mesh must not
	# share a tint. Before this, the shader hashed NODE_POSITION_WORLD, which is
	# a single value per merged node.
	var seeds: Dictionary = {}
	for c: Color in colors:
		seeds[snappedf(c.r, 0.001)] = true
	_assert(seeds.size() >= 2,
		"GC93-04: two merged blocks carry distinct seeds (got %d)" % seeds.size())

	# Size channel decodes back to the block's real smallest dimension.
	var decoded := BlockMeshMerger.decode_size(colors[0].b)
	_assert(absf(decoded - 1.0) < 0.02,
		"GC93-05: size channel decodes to 1.0m (got %.3f)" % decoded)

	_cleanup(asm_root)


func _test_seed_stamp_face_culled() -> void:
	_section("GC-93 seed stamp survives face culling")

	# Two touching boxes: the shared X faces get culled, so BOTH entries take
	# the sub-SurfaceTool + index() path instead of append_from(entry.mesh).
	# index() DEDUPLICATES, so the appended vertex count is the committed length
	# of the sub-mesh rather than the number of add_vertex calls — the easiest
	# way to get the span accounting wrong and silently lose the stamp.
	var blocks: Array = [
		_make_box("cull_a", Vector3(2, 2, 2), Vector3(0, 0, 0)),
		_make_box("cull_b", Vector3(2, 2, 2), Vector3(2, 0, 0)),
	]
	var asm_root := _build_assembly(blocks)
	await get_tree().process_frame

	var colors := _merged_colors(asm_root)
	var vcount := _merged_vertex_count(asm_root)
	_assert(colors.size() > 0 and colors.size() == vcount,
		"GC93-06: face-culled merge still stamped (%d colours, %d vertices)" % [colors.size(), vcount])

	var seeds: Dictionary = {}
	for c: Color in colors:
		seeds[snappedf(c.r, 0.001)] = true
	_assert(seeds.size() >= 2,
		"GC93-07: face-culled blocks keep distinct seeds (got %d)" % seeds.size())

	_cleanup(asm_root)


func _test_seed_stamp_deterministic() -> void:
	_section("GC-93 seed determinism")

	# The seed is baked into the compiled world cache, so the same geometry must
	# hash the same on every run and every machine. Block ids cannot be used for
	# this: ensure_id() seeds them with Time.get_ticks_msec().
	var first: Array = [
		_make_box("det_a", Vector3(1, 1, 1), Vector3(0, 0, 0)),
		_make_box("det_b", Vector3(1, 1, 1), Vector3(6, 0, 0)),
	]
	var root_a := _build_assembly(first)
	await get_tree().process_frame
	var colors_a := _merged_colors(root_a)
	_cleanup(root_a)

	var second: Array = [
		_make_box("det_a", Vector3(1, 1, 1), Vector3(0, 0, 0)),
		_make_box("det_b", Vector3(1, 1, 1), Vector3(6, 0, 0)),
	]
	var root_b := _build_assembly(second)
	await get_tree().process_frame
	var colors_b := _merged_colors(root_b)

	var same := colors_a.size() == colors_b.size() and colors_a.size() > 0
	if same:
		for i: int in range(colors_a.size()):
			if absf(colors_a[i].r - colors_b[i].r) > 0.001:
				same = false
				break
	_assert(same, "GC93-08: identical geometry produces identical seeds across builds")

	# Distinct blocks must not collide, or neighbours render the same tint and
	# the edge stays invisible — the defect this feature exists to fix.
	var distinct := absf(_merged_colors(root_b)[0].r - colors_b[colors_b.size() - 1].r) > 0.001
	_assert(distinct, "GC93-09: differing positions produce differing seeds")

	_cleanup(root_b)


func _test_seed_stamp_size_channel() -> void:
	_section("GC-93 size channel")

	# Micro-blocks are what the screen-size gate exists to suppress: a 6cm block
	# must encode a small enough size that the shader fades its tint out before
	# it can alias. Zero components must NOT be read as the minimum — a sphere
	# is [radius, height, 0] and a cylinder's x is a radius, so a naive min()
	# would report 0m and silently kill variation on every sphere in the world.
	var blocks: Array = [
		_make_box("micro_a", Vector3(0.06, 0.06, 0.06), Vector3(0, 0, 0)),
		_make_box("micro_b", Vector3(0.06, 0.06, 0.06), Vector3(6, 0, 0)),
	]
	var asm_root := _build_assembly(blocks)
	await get_tree().process_frame
	var colors := _merged_colors(asm_root)
	var decoded := BlockMeshMerger.decode_size(colors[0].b) if colors.size() > 0 else -1.0
	# Tight tolerance on purpose: this is the exact quantity the anti-static
	# screen-size gate keys on, and the sqrt encoding exists to make it accurate
	# here rather than at the 4m end where nothing reads it.
	_assert(absf(decoded - 0.06) < 0.005,
		"GC93-10: 6cm block encodes ~0.06m (got %.4f)" % decoded)
	_cleanup(asm_root)

	# A wall panel presents a 2x3m FACE. Gating it on its smallest dimension
	# would judge it a 0.2m sliver and fade its tint out at arm's length; the
	# middle extent (2.0m) is the short side of the face actually being looked
	# at. Measured across the hub's procedural blocks this is the difference
	# between a median gate dimension of 0.11m and 0.20m — i.e. between a fix
	# that dies at 7m and one that survives across a room.
	var slabs: Array = [
		_make_box("slab_a", Vector3(2.0, 0.2, 3.0), Vector3(0, 0, 0)),
		_make_box("slab_b", Vector3(2.0, 0.2, 3.0), Vector3(8, 0, 0)),
	]
	var slab_root := _build_assembly(slabs)
	await get_tree().process_frame
	var slab_colors := _merged_colors(slab_root)
	var slab_decoded := BlockMeshMerger.decode_size(slab_colors[0].b) if slab_colors.size() > 0 else -1.0
	_assert(absf(slab_decoded - 2.0) < 0.05,
		"GC93-12: 2x0.2x3 panel gates on its 2.0m middle extent (got %.3f)" % slab_decoded)
	_cleanup(slab_root)

	# scale_factor is applied to the block ROOT at build time and inherited by
	# the merged vertices, so a gate reading only authored extents judges a
	# shrunk block at full size. Shipped content authors scale_factor down to
	# 0.55.
	var scaled_a := _make_box("scaled_a", Vector3(1, 1, 1), Vector3(0, 0, 0))
	scaled_a.scale_factor = 0.5
	var scaled_b := _make_box("scaled_b", Vector3(1, 1, 1), Vector3(6, 0, 0))
	scaled_b.scale_factor = 0.5
	var scaled_root := _build_assembly([scaled_a, scaled_b])
	await get_tree().process_frame
	var scaled_colors := _merged_colors(scaled_root)
	var scaled_decoded := BlockMeshMerger.decode_size(scaled_colors[0].b) if scaled_colors.size() > 0 else -1.0
	_assert(absf(scaled_decoded - 0.5) < 0.02,
		"GC93-13: scale_factor 0.5 halves the gate dimension (got %.3f)" % scaled_decoded)
	_cleanup(scaled_root)

	var spheres: Array = [
		_make_sphere("sph_a", 0.5, Vector3(0, 0, 0)),
		_make_sphere("sph_b", 0.5, Vector3(6, 0, 0)),
	]
	var sph_root := _build_assembly(spheres)
	await get_tree().process_frame
	var sph_colors := _merged_colors(sph_root)
	var sph_decoded := BlockMeshMerger.decode_size(sph_colors[0].b) if sph_colors.size() > 0 else -1.0
	# A radius-0.5 sphere is a 1.0m BALL. BlockBuilder feeds dims.x to
	# SphereMesh.radius, so reading the authored vector as extents would encode
	# 0.5m and fade the tint at half the right distance. Assert the DIAMETER —
	# an earlier version of this test asserted only "> 0.01" and passed happily
	# on the wrong value, which is worse than having no test at all.
	_assert(absf(sph_decoded - 1.0) < 0.02,
		"GC93-11: sphere radius 0.5 encodes its 1.0m diameter (got %.4f)" % sph_decoded)
	_cleanup(sph_root)


## GC-91: tint-only overrides merge under the BASE material with the tint in
## ARRAY_CUSTOM0 — the 65%-of-outputs collapse. Blocks with OTHER overrides
## still fork (covered by _test_override_material_grouping).
func _test_tint_only_collapses_to_base_material() -> void:
	_section("Tint-only collapse (GC-91)")
	var blocks: Array = []
	var tints := [Color(0.9, 0.5, 0.5), Color(0.5, 0.9, 0.5), Color(0.5, 0.5, 0.9), Color(0.7, 0.7, 0.2)]
	for i in 8:
		var b := _make_box("tint_%d" % i, Vector3(2, 2, 2), Vector3(i * 3.0, 1, 0), "wood")
		b.color_tint = tints[i % 4]        # 4 distinct tints, ONE base material
		blocks.append(b)
	var root := _build_assembly(blocks)
	await get_tree().process_frame

	var merged: Array = []
	for c in root.get_children():
		if c is MeshInstance3D and c.name.begins_with("Merged"):
			merged.append(c)
	_assert(merged.size() == 1, "8 tint-only blocks (4 tints, 1 base) → 1 merged mesh (got %d)" % merged.size())
	if merged.size() == 1:
		var mi: MeshInstance3D = merged[0]
		var mat = mi.material_override
		_assert(mat != null and str(mat.resource_name) == "wood", "merged material is the BASE 'wood' (got '%s')" % (str(mat.resource_name) if mat else "null"))
		var arrays: Array = (mi.mesh as ArrayMesh).surface_get_arrays(0)
		var custom0 = arrays[Mesh.ARRAY_CUSTOM0]
		_assert(custom0 != null and not (custom0 is PackedByteArray and custom0.is_empty()), "ARRAY_CUSTOM0 is present on the merged surface")
		# Decode a sample: CUSTOM0 comes back as PackedByteArray (RGBA8) or PackedColorArray.
		var a_ok := false
		if custom0 is PackedColorArray and (custom0 as PackedColorArray).size() > 0:
			a_ok = (custom0 as PackedColorArray)[0].a > 0.5
		elif custom0 is PackedByteArray and (custom0 as PackedByteArray).size() >= 4:
			a_ok = (custom0 as PackedByteArray)[3] > 127
		_assert(a_ok, "CUSTOM0.a marks the vertices as tint-stamped")
		# Every vertex has a stamp: length matches the vertex array.
		var nverts: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var ncustom: int = (custom0 as PackedColorArray).size() if custom0 is PackedColorArray else ((custom0 as PackedByteArray).size() / 4 if custom0 is PackedByteArray else 0)
		_assert(ncustom == nverts, "CUSTOM0 covers every vertex (%d of %d)" % [ncustom, nverts])
	root.queue_free()
