extends Node3D

const EXPECTED_SOURCE_SHA256 := "6298ee68eb4df52d4fe8bdd332a1813492de600f595c214ef934f35fd3ee3e1a"
const EXPECTED_WORLD_EXTENTS := Vector3(217.404864, 24.222379, 232.932841)

@onready var map_wrapper: Node3D = $NavigationRegion3D/AuthoredEnvironmentWrapper
@onready var map_instance: Node3D = $NavigationRegion3D/AuthoredEnvironmentWrapper/StandoffArena
@onready var map_collision: StaticBody3D = $MapCollision
@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D

var map_bounds := AABB()
var visible_mesh_count := 0
var material_slot_count := 0
var collision_triangle_count := 0
var collision_ready := false
var navigation_bake_started := false
var navigation_ready := false
var navigation_vertex_count := 0
var navigation_polygon_count := 0


func _ready() -> void:
	navigation_region.bake_finished.connect(_on_navigation_bake_finished)
	await get_tree().process_frame
	_configure_map_materials()
	_measure_map()
	_build_map_collision()
	_start_navigation_bake()


func _configure_map_materials() -> void:
	for node in map_instance.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			material_slot_count += 1
			var source_material := mesh_instance.get_active_material(surface_index) as BaseMaterial3D
			if source_material == null:
				continue
			var material := source_material.duplicate() as BaseMaterial3D
			material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
			mesh_instance.set_surface_override_material(surface_index, material)


func _measure_map() -> void:
	var has_bounds := false
	for node in map_instance.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null or not mesh_instance.visible:
			continue
		visible_mesh_count += 1
		var world_aabb := _transform_aabb(mesh_instance.mesh.get_aabb(), mesh_instance.global_transform)
		if not has_bounds:
			map_bounds = world_aabb
			has_bounds = true
		else:
			map_bounds = map_bounds.merge(world_aabb)


func _transform_aabb(local_aabb: AABB, world_transform: Transform3D) -> AABB:
	var minimum := world_transform * local_aabb.position
	var maximum := minimum
	for x_index in 2:
		for y_index in 2:
			for z_index in 2:
				var corner := local_aabb.position + Vector3(
					local_aabb.size.x * x_index,
					local_aabb.size.y * y_index,
					local_aabb.size.z * z_index
				)
				var world_corner := world_transform * corner
				minimum = minimum.min(world_corner)
				maximum = maximum.max(world_corner)
	return AABB(minimum, maximum - minimum)


func _build_map_collision() -> void:
	var faces := PackedVector3Array()
	var collision_inverse := map_collision.global_transform.affine_inverse()
	for node in map_instance.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var to_collision := collision_inverse * mesh_instance.global_transform
		for vertex in mesh_instance.mesh.get_faces():
			faces.append(to_collision * vertex)
	if faces.size() < 3:
		push_error("Standoff Arena exposed no usable mesh faces for collision.")
		return
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "AuthoredMapConcaveCollision"
	collision_shape.shape = shape
	map_collision.add_child(collision_shape)
	collision_triangle_count = faces.size() / 3
	collision_ready = true
	print("Arena collision built from %d triangles." % collision_triangle_count)


func _start_navigation_bake() -> void:
	if navigation_region.navigation_mesh == null:
		push_error("Arena NavigationRegion3D has no NavigationMesh resource.")
		return
	navigation_bake_started = true
	navigation_region.bake_navigation_mesh(true)


func _on_navigation_bake_finished() -> void:
	var navigation_mesh := navigation_region.navigation_mesh
	navigation_vertex_count = navigation_mesh.get_vertices().size()
	navigation_polygon_count = navigation_mesh.get_polygon_count()
	navigation_ready = navigation_polygon_count > 0
	if not navigation_ready:
		push_warning("Arena navigation bake completed without walkable polygons.")


func _mcp_state() -> Dictionary:
	return {
		"asset_id": "standoff_arena_authored_environment",
		"source_sha256": EXPECTED_SOURCE_SHA256,
		"environment_instance_count": 1,
		"environment_instance_path": map_instance.get_path(),
		"wrapper_scale": map_wrapper.scale,
		"wrapper_position": map_wrapper.position,
		"measured_bounds_position": map_bounds.position,
		"measured_bounds_size": map_bounds.size,
		"expected_world_extents": EXPECTED_WORLD_EXTENTS,
		"visible_mesh_count": visible_mesh_count,
		"material_slot_count": material_slot_count,
		"collision_ready": collision_ready,
		"collision_triangle_count": collision_triangle_count,
		"navigation_bake_started": navigation_bake_started,
		"navigation_ready": navigation_ready,
		"navigation_vertex_count": navigation_vertex_count,
		"navigation_polygon_count": navigation_polygon_count,
		"ground_datum_y": 0.0,
	}
