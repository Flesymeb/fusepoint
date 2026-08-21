class_name FusepointEnemyRoster
extends Node3D

signal roster_ready(summary: Dictionary)
signal roster_event_committed(event: Dictionary)

const ENEMY_SCENE := preload("res://scenes/enemy_agent.tscn")
const REGION_ORDER: Array[StringName] = [&"alpha", &"bravo", &"charlie"]
const ROSTER := [
	{"id":"rift-a-01","region":"alpha","role":"defender","slot":"alpha_core","route_pressure":false,"offset":Vector3(-1,0,-1)},
	{"id":"rift-a-02","region":"alpha","role":"approach","slot":"alpha_west_lane","route_pressure":true,"offset":Vector3(-8,0,5)},
	{"id":"rift-a-03","region":"alpha","role":"flanker","slot":"alpha_east_lane","route_pressure":true,"offset":Vector3(7,0,3)},
	{"id":"rift-b-01","region":"bravo","role":"defender","slot":"bravo_core_north","route_pressure":false,"offset":Vector3(-1,0,1)},
	{"id":"rift-b-02","region":"bravo","role":"defender","slot":"bravo_core_south","route_pressure":false,"offset":Vector3(2,0,-2)},
	{"id":"rift-b-03","region":"bravo","role":"approach","slot":"bravo_west_route","route_pressure":true,"offset":Vector3(-8,0,-5)},
	{"id":"rift-b-04","region":"bravo","role":"flanker","slot":"bravo_east_route","route_pressure":true,"offset":Vector3(8,0,-3)},
	{"id":"rift-b-05","region":"bravo","role":"fallback","slot":"bravo_fallback","route_pressure":true,"offset":Vector3(1,0,8)},
	{"id":"rift-c-01","region":"charlie","role":"defender","slot":"charlie_core_west","route_pressure":false,"offset":Vector3(-2,0,0)},
	{"id":"rift-c-02","region":"charlie","role":"defender","slot":"charlie_core_east","route_pressure":false,"offset":Vector3(2,0,1)},
	{"id":"rift-c-03","region":"charlie","role":"defender","slot":"charlie_core_rear","route_pressure":false,"offset":Vector3(0,0,3)},
	{"id":"rift-c-04","region":"charlie","role":"approach","slot":"charlie_south_route","route_pressure":true,"offset":Vector3(-4,0,-8)},
	{"id":"rift-c-05","region":"charlie","role":"approach","slot":"charlie_west_route","route_pressure":true,"offset":Vector3(-9,0,-2)},
	{"id":"rift-c-06","region":"charlie","role":"flanker","slot":"charlie_east_route","route_pressure":true,"offset":Vector3(9,0,-3)},
	{"id":"rift-c-07","region":"charlie","role":"flanker","slot":"charlie_north_route","route_pressure":true,"offset":Vector3(5,0,8)},
	{"id":"rift-c-08","region":"charlie","role":"fallback","slot":"charlie_fallback_west","route_pressure":true,"offset":Vector3(-7,0,7)},
	{"id":"rift-c-09","region":"charlie","role":"sentry","slot":"charlie_outer_south","route_pressure":true,"offset":Vector3(7,0,-9)},
	{"id":"rift-c-10","region":"charlie","role":"sentry","slot":"charlie_outer_north","route_pressure":true,"offset":Vector3(0,0,11)},
]

@export var player_path: NodePath
@export var mission_controller_path: NodePath
@export var navigation_region_path: NodePath
@export var alpha_path: NodePath
@export var bravo_path: NodePath
@export var charlie_path: NodePath

var enemies: Dictionary = {}
var activation_sequence := 0
var roster_initialized := false
var slot_projection_reports: Array[Dictionary] = []
var roster_events: Array[Dictionary] = []
var restore_epoch := 0
var restore_in_progress := false
var restore_applied_actor_count := 0
var last_restore_receipt: Dictionary = {}
var _roster_event_sequence := 0
var _last_progression_signature := ""
var diagnostic_mode := &"player"
var _diagnostic_camera: Camera3D
var _diagnostic_actor_index := 0

@onready var player: Node3D = get_node(player_path) as Node3D
@onready var mission_controller: Node = get_node(mission_controller_path)
@onready var navigation_region: NavigationRegion3D = get_node(navigation_region_path) as NavigationRegion3D


func _ready() -> void:
	await _wait_for_navigation()
	_instantiate_roster()
	_update_region_activation()
	roster_initialized = enemies.size() == 18
	var summary := _summary()
	roster_ready.emit(summary)
	if not roster_initialized:
		push_error("Fusepoint enemy roster expected 18 stable actors, got %d" % enemies.size())


func _process(_delta: float) -> void:
	if roster_initialized and not restore_in_progress:
		_update_region_activation()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F10:
		_toggle_overhead_camera()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F9:
		_focus_active_actor()
		get_viewport().set_input_as_handled()


func _toggle_overhead_camera() -> void:
	_ensure_diagnostic_camera()
	if diagnostic_mode == &"player":
		var center := _objective_for(_active_region()).global_position
		_diagnostic_camera.global_position = center + Vector3(0.0, 34.0, 10.0)
		_diagnostic_camera.look_at(center, Vector3.UP)
		_diagnostic_camera.current = true
		diagnostic_mode = &"overhead"
	else:
		var player_camera := player.get_node_or_null("Head/Camera3D") as Camera3D
		if player_camera != null:
			player_camera.current = true
		diagnostic_mode = &"player"


func _focus_active_actor() -> void:
	_ensure_diagnostic_camera()
	var active: Array[FusepointEnemyAgent] = []
	for enemy: FusepointEnemyAgent in enemies.values():
		if enemy.mission_active and enemy.is_alive():
			active.append(enemy)
	if active.is_empty():
		return
	_diagnostic_actor_index = posmod(_diagnostic_actor_index, active.size())
	var subject := active[_diagnostic_actor_index]
	_diagnostic_actor_index += 1
	_diagnostic_camera.global_position = subject.global_position + Vector3(3.4, 2.35, 4.8)
	_diagnostic_camera.look_at(subject.global_position + Vector3.UP * 1.05, Vector3.UP)
	_diagnostic_camera.current = true
	diagnostic_mode = StringName("actor:%s" % subject.stable_id)


func _ensure_diagnostic_camera() -> void:
	if _diagnostic_camera != null:
		return
	_diagnostic_camera = Camera3D.new()
	_diagnostic_camera.name = "EncounterDiagnosticCamera"
	add_child(_diagnostic_camera)


func _active_region() -> StringName:
	var state: Dictionary = mission_controller.call(&"_mcp_state")
	var points: Dictionary = state.get("capture_points", {})
	if StringName((points.get(&"bravo", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis":
		return &"charlie"
	if StringName((points.get(&"alpha", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis":
		return &"bravo"
	return &"alpha"


func _wait_for_navigation() -> void:
	for _frame in 180:
		var arena := navigation_region.get_parent()
		if arena != null and arena.get("navigation_ready") == true:
			return
		await get_tree().physics_frame
	push_warning("Enemy roster timed out waiting for authored-map navigation.")


func _instantiate_roster() -> void:
	var nav_map: RID = navigation_region.get_navigation_map()
	var placed_positions: Array[Vector3] = []
	for index in ROSTER.size():
		var source: Dictionary = ROSTER[index]
		var entry := source.duplicate(true)
		entry["index"] = index
		entry["difficulty"] = FPSCombatEnemy.Difficulty.MEDIUM if index < 8 else FPSCombatEnemy.Difficulty.HARD
		var agent := ENEMY_SCENE.instantiate() as FusepointEnemyAgent
		agent.name = String(entry["id"]).replace("-", "_")
		agent.configure_roster_entry(entry, player)
		var objective := _objective_for(StringName(entry["region"]))
		var requested: Vector3 = objective.global_position - Vector3.UP * 1.2 + (entry["offset"] as Vector3)
		var primary_projection: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, requested)
		var projected := _select_distinct_navigation_slot(nav_map, requested, primary_projection, placed_positions)
		var used_separation_fallback := not projected.is_equal_approx(primary_projection)
		placed_positions.append(projected)
		agent.global_position = projected + Vector3.UP * 0.04
		agent.look_at(objective.global_position, Vector3.UP)
		add_child(agent)
		agent.authoritative_enemy_event.connect(_on_enemy_event)
		enemies[agent.stable_id] = agent
		slot_projection_reports.append({
			"id": agent.stable_id,
			"slot": agent.route_slot,
			"requested": requested,
			"projected": projected,
			"projection_distance": requested.distance_to(projected),
			"navigation_slot_bound": true,
			"separation_fallback": used_separation_fallback,
		})


func _select_distinct_navigation_slot(
	nav_map: RID,
	requested: Vector3,
	primary: Vector3,
	placed_positions: Array[Vector3],
) -> Vector3:
	if _is_separated_slot(primary, placed_positions):
		return primary
	var best := primary
	var best_score := INF
	for radius: float in [1.5, 2.25, 3.0, 4.0]:
		for step: int in 8:
			var angle := TAU * float(step) / 8.0
			var sample := requested + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			var projected := NavigationServer3D.map_get_closest_point(nav_map, sample)
			if projected.distance_to(sample) > 2.0 or not _is_separated_slot(projected, placed_positions):
				continue
			var score := requested.distance_to(projected)
			if score < best_score:
				best = projected
				best_score = score
	return best


func _is_separated_slot(candidate: Vector3, placed_positions: Array[Vector3]) -> bool:
	for placed: Vector3 in placed_positions:
		if candidate.distance_to(placed) < 1.4:
			return false
	return true


func _update_region_activation() -> void:
	var state: Dictionary = mission_controller.call(&"_mcp_state")
	var points: Dictionary = state.get("capture_points", {})
	var alpha_secured := StringName((points.get(&"alpha", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis"
	var bravo_secured := StringName((points.get(&"bravo", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis"
	var signature := "%s:%s" % [alpha_secured, bravo_secured]
	if signature == _last_progression_signature:
		return
	_last_progression_signature = signature
	var active_region := &"charlie" if bravo_secured else &"bravo" if alpha_secured else &"alpha"
	activation_sequence += 1
	for enemy: FusepointEnemyAgent in enemies.values():
		enemy.set_mission_active(enemy.region_id == active_region, activation_sequence)
	_commit_roster_event(&"region_activated", {"region": active_region, "sequence": activation_sequence})


func contest_count(point_id: StringName, objective_position: Vector3, radius := 4.5) -> int:
	var count := 0
	for enemy: FusepointEnemyAgent in enemies.values():
		if enemy.region_id == point_id and enemy.is_contesting(objective_position, radius):
			count += 1
	return count


func snapshot_all() -> Dictionary:
	var snapshots := {}
	for id: StringName in enemies:
		snapshots[id] = (enemies[id] as FusepointEnemyAgent).authoritative_snapshot()
	return snapshots


func begin_restore_epoch() -> int:
	if restore_in_progress or not roster_initialized:
		return -1
	restore_epoch += 1
	restore_in_progress = true
	restore_applied_actor_count = 0
	last_restore_receipt.clear()
	for enemy: FusepointEnemyAgent in enemies.values():
		enemy.begin_checkpoint_restore(restore_epoch)
	return restore_epoch


func apply_restore_snapshot(saved: Dictionary, epoch: int) -> bool:
	if not restore_in_progress or epoch != restore_epoch or saved.size() != enemies.size():
		return false
	var applied := 0
	for id: StringName in enemies:
		var actor_snapshot: Dictionary = saved.get(id, saved.get(String(id), {}))
		if actor_snapshot.is_empty():
			return false
		if not (enemies[id] as FusepointEnemyAgent).apply_checkpoint_snapshot(actor_snapshot, epoch):
			return false
		applied += 1
	restore_applied_actor_count = applied
	return applied == enemies.size()


func commit_restore_epoch(epoch: int) -> Dictionary:
	if not restore_in_progress or epoch != restore_epoch or restore_applied_actor_count != enemies.size():
		return {}
	var actor_receipts: Array[Dictionary] = []
	for enemy: FusepointEnemyAgent in enemies.values():
		if not enemy.finish_checkpoint_restore(epoch):
			return {}
		actor_receipts.append({
			"id": enemy.stable_id,
			"restored_epoch": epoch,
			"quiescent": true,
			"readiness": &"fresh_perception_pending",
		})
	restore_in_progress = false
	_last_progression_signature = _progression_signature()
	last_restore_receipt = {
		"restore_epoch": epoch,
		"actor_count": actor_receipts.size(),
		"all_snapshots_applied": actor_receipts.size() == enemies.size(),
		"actors": actor_receipts,
	}
	_commit_roster_event(&"checkpoint_restore_transaction", last_restore_receipt)
	return last_restore_receipt.duplicate(true)


func restore_all(saved: Dictionary) -> Dictionary:
	var epoch := begin_restore_epoch()
	if epoch < 0 or not apply_restore_snapshot(saved, epoch):
		return {}
	return commit_restore_epoch(epoch)


func _objective_for(region_id: StringName) -> Node3D:
	match region_id:
		&"alpha": return get_node(alpha_path) as Node3D
		&"bravo": return get_node(bravo_path) as Node3D
		_: return get_node(charlie_path) as Node3D


func _on_enemy_event(event: Dictionary) -> void:
	if restore_in_progress:
		return
	_commit_roster_event(&"enemy_event", event)
	if event.get("kind", &"") != &"action_changed" and mission_controller.has_method(&"report_enemy_event"):
		mission_controller.call(&"report_enemy_event", event)


func _commit_roster_event(kind: StringName, payload: Dictionary) -> void:
	_roster_event_sequence += 1
	var event := {
		"event_id": "roster-%06d" % _roster_event_sequence,
		"kind": kind,
		"payload": payload.duplicate(true),
	}
	roster_events.append(event)
	while roster_events.size() > 128:
		roster_events.pop_front()
	roster_event_committed.emit(event)


func _summary() -> Dictionary:
	var region_counts := {&"alpha": 0, &"bravo": 0, &"charlie": 0}
	var route_pressure_counts := {&"alpha": 0, &"bravo": 0, &"charlie": 0}
	var active_count := 0
	var alive_count := 0
	var actor_states: Array[Dictionary] = []
	for enemy: FusepointEnemyAgent in enemies.values():
		region_counts[enemy.region_id] += 1
		if enemy.route_pressure:
			route_pressure_counts[enemy.region_id] += 1
		active_count += 1 if enemy.mission_active else 0
		alive_count += 1 if enemy.is_alive() else 0
		actor_states.append(enemy.authoritative_snapshot())
	return {
		"ready": roster_initialized,
		"stable_identity_count": enemies.size(),
		"region_counts": region_counts,
		"route_pressure_counts": route_pressure_counts,
		"active_count": active_count,
		"alive_count": alive_count,
		"activation_sequence": activation_sequence,
		"restore_epoch": restore_epoch,
		"restore_in_progress": restore_in_progress,
		"restore_applied_actor_count": restore_applied_actor_count,
		"last_restore_receipt": last_restore_receipt,
		"slot_projection_reports": slot_projection_reports,
		"unique_slot_count": _unique_slot_count(),
		"actors": actor_states,
		"last_event": roster_events.back() if not roster_events.is_empty() else {},
		"diagnostic_mode": diagnostic_mode,
	}


func _unique_slot_count() -> int:
	var slots := {}
	for enemy: FusepointEnemyAgent in enemies.values():
		slots[enemy.route_slot] = true
	return slots.size()


func _progression_signature() -> String:
	var state: Dictionary = mission_controller.call(&"_mcp_state")
	var points: Dictionary = state.get("capture_points", {})
	var alpha_secured := StringName((points.get(&"alpha", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis"
	var bravo_secured := StringName((points.get(&"bravo", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis"
	return "%s:%s" % [alpha_secured, bravo_secured]


func _mcp_state() -> Dictionary:
	return _summary()
