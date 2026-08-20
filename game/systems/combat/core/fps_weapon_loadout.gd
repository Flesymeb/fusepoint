class_name FPSWeaponLoadout
extends Node

## Couples gameplay weapon stats to an arbitrary profile-driven viewmodel. The
## visual driver is optional, but when present its weapon_changed signal is the
## authoritative point at which gameplay stats change.

signal weapon_changed(weapon_id: StringName, index: int, snapshot: Dictionary)
signal shot_resolved(event: Dictionary)
signal ammo_changed(magazine: int, reserve: int, weapon_id: StringName)

@export var weapon_specs: Array[FPSWeaponSpec] = []
@export_range(0, 32, 1) var starting_weapon_index := 0
@export_node_path("FPSHitscanWeapon") var hitscan_weapon_path: NodePath
@export_node_path("Node") var viewmodel_driver_path: NodePath
@export var handle_fire_input := true
@export var handle_reload_input := true
@export var handle_number_keys := true
@export var fire_action: StringName = &"fire"
@export var reload_action: StringName = &"reload"

var current_weapon_index := -1
var _hitscan: FPSHitscanWeapon
var _viewmodel: Node
var _states: Dictionary = {}
var _fire_held := false


func _ready() -> void:
	_hitscan = get_node_or_null(hitscan_weapon_path) as FPSHitscanWeapon
	_viewmodel = get_node_or_null(viewmodel_driver_path) if not viewmodel_driver_path.is_empty() else null
	if _hitscan == null:
		push_error("FPSWeaponLoadout requires an FPSHitscanWeapon")
		return
	_hitscan.shot_resolved.connect(shot_resolved.emit)
	_hitscan.ammo_changed.connect(ammo_changed.emit)
	if _viewmodel != null:
		if _viewmodel.has_signal("weapon_changed"):
			_viewmodel.connect("weapon_changed", _on_viewmodel_weapon_changed)
		if _viewmodel.has_signal("aiming_changed"):
			_viewmodel.connect("aiming_changed", _hitscan.set_aiming)
	if weapon_specs.is_empty():
		push_error("FPSWeaponLoadout requires at least one FPSWeaponSpec")
		return
	equip_weapon(clampi(starting_weapon_index, 0, weapon_specs.size() - 1), true)


func _unhandled_input(event: InputEvent) -> void:
	if handle_fire_input and InputMap.has_action(fire_action):
		if event.is_action_pressed(fire_action):
			_fire_held = true
			fire_current()
		elif event.is_action_released(fire_action):
			_fire_held = false
	if handle_reload_input and InputMap.has_action(reload_action) and event.is_action_pressed(reload_action):
		reload_current()
	if handle_number_keys and event.is_pressed() and not event.is_echo():
		if InputMap.has_action(&"weapon_slot_1") and event.is_action_pressed(&"weapon_slot_1"):
			equip_weapon(0)
		elif InputMap.has_action(&"weapon_slot_2") and event.is_action_pressed(&"weapon_slot_2"):
			equip_weapon(1)


func _process(_delta: float) -> void:
	if not _fire_held:
		return
	if not handle_fire_input or not InputMap.has_action(fire_action):
		_fire_held = false
		return
	if not Input.is_action_pressed(fire_action):
		_fire_held = false
		return
	var spec := current_spec()
	if handle_fire_input and spec != null and spec.automatic and _hitscan != null and _hitscan.can_fire():
		fire_current()


func fire_current(bypass_cooldown := false) -> Dictionary:
	return _hitscan.try_fire(Vector3.ZERO, bypass_cooldown) if _hitscan != null else {
		"accepted": false,
		"reason": "missing_hitscan_weapon",
	}


func reload_current() -> bool:
	return _hitscan.start_reload() if _hitscan != null else false


func cycle_weapon(direction: int) -> bool:
	if direction == 0 or weapon_specs.size() < 2:
		return false
	if _viewmodel != null and _viewmodel.has_method("cycle_weapon"):
		return bool(_viewmodel.call("cycle_weapon", direction))
	return equip_weapon(posmod(current_weapon_index + signi(direction), weapon_specs.size()))


func equip_weapon(index: int, immediate := false) -> bool:
	if index < 0 or index >= weapon_specs.size() or weapon_specs[index] == null:
		return false
	if _viewmodel != null and _viewmodel.has_method("equip_weapon"):
		var accepted := bool(_viewmodel.call("equip_weapon", index, true, immediate))
		if not accepted:
			return false
		if _viewmodel.has_signal("weapon_changed"):
			if immediate:
				_apply_weapon_index(index)
			return true
	_apply_weapon_index(index)
	return true


func equip_weapon_id(weapon_id: StringName, immediate := false) -> bool:
	for index: int in weapon_specs.size():
		if weapon_specs[index] != null and weapon_specs[index].weapon_id == weapon_id:
			return equip_weapon(index, immediate)
	return false


func current_spec() -> FPSWeaponSpec:
	if current_weapon_index < 0 or current_weapon_index >= weapon_specs.size():
		return null
	return weapon_specs[current_weapon_index]


func snapshot() -> Dictionary:
	return {
		"weapon_index": current_weapon_index,
		"weapon_count": weapon_specs.size(),
		"weapon": current_spec().snapshot() if current_spec() != null else {},
		"runtime": _hitscan.state_snapshot() if _hitscan != null else {},
	}


func _on_viewmodel_weapon_changed(weapon_id: StringName, weapon_index: int) -> void:
	var index := weapon_index
	if index < 0 or index >= weapon_specs.size() or weapon_specs[index].weapon_id != weapon_id:
		index = -1
		for candidate: int in weapon_specs.size():
			if weapon_specs[candidate] != null and weapon_specs[candidate].weapon_id == weapon_id:
				index = candidate
				break
	if index >= 0:
		_apply_weapon_index(index)


func _apply_weapon_index(index: int) -> void:
	if _hitscan == null or index < 0 or index >= weapon_specs.size():
		return
	if current_weapon_index >= 0:
		var previous := current_spec()
		if previous != null:
			_states[String(previous.weapon_id)] = {
				"magazine": _hitscan.magazine,
				"reserve": _hitscan.reserve,
			}
	current_weapon_index = index
	var spec := current_spec()
	_hitscan.configure(spec, _states.get(String(spec.weapon_id), {}))
	weapon_changed.emit(spec.weapon_id, current_weapon_index, snapshot())
