class_name FusepointProductShell
extends CanvasLayer

const STATE_TITLE := &"title"
const STATE_LOADOUT := &"loadout"
const STATE_LOADING := &"loading"
const STATE_BRIEFING := &"briefing"
const STATE_GAMEPLAY := &"gameplay"
const STATE_PAUSE := &"pause"
const STATE_SETTINGS := &"settings"
const STATE_DEATH := &"death_recovery"
const STATE_RESULT := &"result"
const BRIEFING_CAPTIONS: Array[String] = [
	"11:40 — KESTREL RIDGE MILITARY BASE\nRIFT FRONT SIGNALS CONFIRMED INSIDE THE PERIMETER.",
	"SECTOR C ROCKET MAINTENANCE BAY\nA FIVE-MINUTE DETONATION DEVICE IS ARMED.",
	"RETAKE ALPHA. SECURE BRAVO.\nRECOVER BOTH DEFUSAL KEYS.",
	"BREACH CHARLIE AND DISMANTLE THE DEVICE.\nSUPPORT IS NOT COMING.",
]
const BRIEFING_BEAT_SECONDS := 2.4
const TRANSITION_HISTORY_LIMIT := 32
const SAFE_AREA_RATIO := 0.05

@onready var root: Control = $Root
@onready var pages: Control = $Root/Pages
@onready var settings_store: FusepointSettingsStore = $SettingsStore
@onready var mission: Node = get_node("../MissionController")
@onready var player: CharacterBody3D = get_node("../PrototypePlayer")
@onready var weapon: Node = get_node("../PrototypePlayer/Head/Camera3D/WeaponController")
@onready var roster: Node = get_node("../EnemyRoster")
@onready var hud: CanvasLayer = get_node("../TacticalHUD")
@onready var terminal: Node = get_node("../TerminalPresentation")

var app_state := STATE_TITLE
var _return_from_settings := STATE_TITLE
var _selected_weapon := &"ak74m"
var _loading_remaining := 0.0
var _transition_serial := 0
var _briefing_elapsed := 0.0
var _briefing_caption_index := -1
var _briefing_complete := false
var _briefing_skip_count := 0
var _deployment_requested := false
var _applied_ui_scale := 1.0
var _applied_subtitle_size := 18
var _reduced_camera_motion := false
var _screen_shake := true
var _last_input_family := &"keyboard_mouse"
var _focus_by_state: Dictionary = {}
var _last_transition_receipt: Dictionary = {}
var _transition_history: Array[Dictionary] = []
var _last_transition_rejection := &""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_controls()
	player.player_died.connect(_on_player_died)
	terminal.presentation_completed.connect(_on_terminal_presentation_completed)
	settings_store.settings_applied.connect(_on_settings_applied)
	_set_gameplay_enabled(false)
	_load_settings_controls()
	settings_store.apply_runtime()
	_show_page(STATE_TITLE)


func _connect_controls() -> void:
	$Root/Pages/TitlePage/Menu/StartButton.pressed.connect(_open_loadout)
	$Root/Pages/TitlePage/Menu/SettingsButton.pressed.connect(_open_settings_from.bind(STATE_TITLE))
	$Root/Pages/TitlePage/Menu/QuitButton.pressed.connect(get_tree().quit)
	$Root/Pages/LoadoutPage/Content/Weapons/AKButton.pressed.connect(_select_weapon.bind(&"ak74m"))
	$Root/Pages/LoadoutPage/Content/Weapons/SaigaButton.pressed.connect(_select_weapon.bind(&"saiga12"))
	$Root/Pages/LoadoutPage/Content/Actions/ConfirmButton.pressed.connect(_start_loading)
	$Root/Pages/LoadoutPage/Content/Actions/BackButton.pressed.connect(_show_page.bind(STATE_TITLE))
	$Root/Pages/BriefingPage/Actions/DeployButton.pressed.connect(_briefing_primary_action)
	$Root/Pages/BriefingPage/Actions/BackButton.pressed.connect(_show_page.bind(STATE_LOADOUT))
	$Root/Pages/PausePage/Menu/ResumeButton.pressed.connect(_resume_gameplay)
	$Root/Pages/PausePage/Menu/SettingsButton.pressed.connect(_open_settings_from.bind(STATE_PAUSE))
	$Root/Pages/PausePage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/PausePage/Menu/HomeButton.pressed.connect(_return_home)
	$Root/Pages/SettingsPage/Actions/ApplyButton.pressed.connect(_apply_settings)
	$Root/Pages/SettingsPage/Actions/CancelButton.pressed.connect(_cancel_settings)
	$Root/Pages/DeathPage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/DeathPage/Menu/HomeButton.pressed.connect(_return_home)
	$Root/Pages/ResultPage/Menu/ReplayButton.pressed.connect(_replay)
	$Root/Pages/ResultPage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/ResultPage/Menu/HomeButton.pressed.connect(_return_home)


func _input(event: InputEvent) -> void:
	_observe_input_family(event)
	if app_state != STATE_GAMEPLAY and event.is_action_pressed(&"menu_accept"):
		var focused := get_viewport().gui_get_focus_owner()
		if focused is BaseButton:
			var button := focused as BaseButton
			if button.toggle_mode:
				button.button_pressed = not button.button_pressed
			button.pressed.emit()
			get_viewport().set_input_as_handled()
			return
	if not (event.is_action_pressed(&"pause") or event.is_action_pressed(&"menu_back")):
		return
	match app_state:
		STATE_LOADOUT, STATE_BRIEFING:
			_show_page(STATE_TITLE if app_state == STATE_LOADOUT else STATE_LOADOUT)
		STATE_SETTINGS:
			_cancel_settings()
		STATE_PAUSE:
			_resume_gameplay()
		STATE_GAMEPLAY:
			_pause_gameplay()
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if app_state == STATE_LOADING and _loading_remaining > 0.0:
		_loading_remaining = maxf(_loading_remaining - delta, 0.0)
		$Root/Pages/LoadingPage/Progress.value = (1.0 - _loading_remaining / 1.35) * 100.0
		if _loading_remaining <= 0.0:
			_show_page(STATE_BRIEFING)
	elif app_state == STATE_BRIEFING and not _briefing_complete:
		_update_briefing(delta)


func _show_page(state: StringName) -> void:
	var previous_state := app_state
	var focused_before := get_viewport().gui_get_focus_owner()
	if focused_before != null and previous_state != STATE_GAMEPLAY:
		_focus_by_state[previous_state] = focused_before.get_path()
	_transition_serial += 1
	app_state = state
	pages.visible = state != STATE_GAMEPLAY
	for child in pages.get_children():
		(child as Control).visible = child.name == _page_name(state)
	if state == STATE_BRIEFING:
		_start_briefing()
	if state != STATE_GAMEPLAY:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_focus_first_button.call_deferred()
	_commit_transition(previous_state, state, &"page_change")


func _page_name(state: StringName) -> String:
	return {
		STATE_TITLE: "TitlePage",
		STATE_LOADOUT: "LoadoutPage",
		STATE_LOADING: "LoadingPage",
		STATE_BRIEFING: "BriefingPage",
		STATE_PAUSE: "PausePage",
		STATE_SETTINGS: "SettingsPage",
		STATE_DEATH: "DeathPage",
		STATE_RESULT: "ResultPage",
	}.get(state, "TitlePage")


func _focus_first_button() -> void:
	var page := pages.get_node_or_null(_page_name(app_state))
	if page == null:
		return
	var remembered_path: NodePath = _focus_by_state.get(app_state, NodePath())
	if not remembered_path.is_empty():
		var remembered := get_node_or_null(remembered_path) as BaseButton
		if remembered != null and remembered.visible and not remembered.disabled:
			remembered.grab_focus()
			_finalize_transition_focus()
			return
	for control in page.find_children("*", "Button", true, false):
		var button := control as Button
		if button.visible and not button.disabled:
			button.grab_focus()
			_finalize_transition_focus()
			return


func _open_loadout() -> void:
	_show_page(STATE_LOADOUT)
	_select_weapon(_selected_weapon)


func _select_weapon(weapon_id: StringName) -> void:
	_selected_weapon = weapon_id
	var ak := $Root/Pages/LoadoutPage/Content/Weapons/AKButton as Button
	var saiga := $Root/Pages/LoadoutPage/Content/Weapons/SaigaButton as Button
	ak.button_pressed = weapon_id == &"ak74m"
	saiga.button_pressed = weapon_id == &"saiga12"
	$Root/Pages/LoadoutPage/Content/Selection.text = "SELECTED  •  %s" % ("AK-74M ASSAULT" if weapon_id == &"ak74m" else "SAIGA-12 BREACH")


func _start_loading() -> void:
	if app_state != STATE_LOADOUT:
		return
	_loading_remaining = 1.35
	$Root/Pages/LoadingPage/Progress.value = 0.0
	_show_page(STATE_LOADING)


func _start_briefing() -> void:
	_briefing_elapsed = 0.0
	_briefing_caption_index = -1
	_briefing_complete = false
	_deployment_requested = false
	$Root/Pages/BriefingPage/Error.text = ""
	var deploy_button := $Root/Pages/BriefingPage/Actions/DeployButton as Button
	deploy_button.text = "SKIP BRIEFING  ▶"
	deploy_button.disabled = false
	_update_briefing(0.0)


func _update_briefing(delta: float) -> void:
	_briefing_elapsed += maxf(delta, 0.0)
	var next_index := mini(int(_briefing_elapsed / BRIEFING_BEAT_SECONDS), BRIEFING_CAPTIONS.size() - 1)
	if next_index != _briefing_caption_index:
		_briefing_caption_index = next_index
		$Root/Pages/BriefingPage/Copy.text = BRIEFING_CAPTIONS[next_index]
	if _briefing_elapsed >= BRIEFING_BEAT_SECONDS * BRIEFING_CAPTIONS.size():
		_complete_briefing(false)


func _briefing_primary_action() -> void:
	if app_state != STATE_BRIEFING:
		return
	if not _briefing_complete:
		_complete_briefing(true)
		return
	_deploy()


func _complete_briefing(skipped: bool) -> void:
	if _briefing_complete:
		return
	_briefing_complete = true
	if skipped:
		_briefing_skip_count += 1
	$Root/Pages/BriefingPage/Copy.text = "MISSION PACKAGE SYNCHRONIZED\nAUTHORIZE DEPLOYMENT WHEN READY."
	$Root/Pages/BriefingPage/Actions/DeployButton.text = "AUTHORIZE DEPLOYMENT  ▶"


func _deploy() -> void:
	if app_state != STATE_BRIEFING or not _briefing_complete or _deployment_requested:
		return
	_deployment_requested = true
	if not weapon.call(&"equip_loadout", _selected_weapon):
		_deployment_requested = false
		$Root/Pages/BriefingPage/Error.text = "LOADOUT UNAVAILABLE — RETURN AND SELECT A VALID WEAPON"
		return
	if not mission.call(&"begin_deployment"):
		_deployment_requested = false
		$Root/Pages/BriefingPage/Error.text = "DEPLOYMENT ALREADY COMMITTED"
		return
	get_tree().paused = false
	_set_gameplay_enabled(true)
	_show_page(STATE_GAMEPLAY)


func _set_gameplay_enabled(enabled: bool) -> void:
	player.call(&"set_gameplay_input_enabled", enabled)
	weapon.call(&"set_gameplay_input_enabled", enabled)
	roster.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
	hud.call(&"set_hud_enabled", enabled)


func _pause_gameplay() -> void:
	if app_state != STATE_GAMEPLAY:
		return
	$Root/Pages/PausePage/Menu/RestartButton.visible = int(mission.get("checkpoint_version")) > 0
	player.call(&"set_gameplay_input_enabled", false)
	weapon.call(&"set_gameplay_input_enabled", false)
	get_tree().paused = true
	_show_page(STATE_PAUSE)


func _resume_gameplay() -> void:
	if app_state != STATE_PAUSE:
		return
	get_tree().paused = false
	player.call(&"set_gameplay_input_enabled", true)
	weapon.call(&"set_gameplay_input_enabled", true)
	_show_page(STATE_GAMEPLAY)


func _open_settings_from(return_state: StringName) -> void:
	_return_from_settings = return_state
	_load_settings_controls()
	_show_page(STATE_SETTINGS)


func _load_settings_controls() -> void:
	var values := settings_store.snapshot()
	$Root/Pages/SettingsPage/Settings/MasterVolume.value = float(values["master_volume"]) * 100.0
	$Root/Pages/SettingsPage/Settings/UIScale.value = float(values["ui_scale"]) * 100.0
	$Root/Pages/SettingsPage/Settings/FOV.value = float(values["fov"])
	$Root/Pages/SettingsPage/Settings/SubtitleSize.value = float(values["subtitle_size"])
	$Root/Pages/SettingsPage/Settings/ReducedMotion.button_pressed = bool(values["reduced_camera_motion"])
	$Root/Pages/SettingsPage/Settings/ScreenShake.button_pressed = bool(values["screen_shake"])
	$Root/Pages/SettingsPage/Settings/HoldADS.button_pressed = bool(values["hold_ads"])


func _apply_settings() -> void:
	settings_store.save_settings({
		"master_volume": $Root/Pages/SettingsPage/Settings/MasterVolume.value / 100.0,
		"ui_scale": $Root/Pages/SettingsPage/Settings/UIScale.value / 100.0,
		"fov": $Root/Pages/SettingsPage/Settings/FOV.value,
		"subtitle_size": $Root/Pages/SettingsPage/Settings/SubtitleSize.value,
		"reduced_camera_motion": $Root/Pages/SettingsPage/Settings/ReducedMotion.button_pressed,
		"screen_shake": $Root/Pages/SettingsPage/Settings/ScreenShake.button_pressed,
		"hold_ads": $Root/Pages/SettingsPage/Settings/HoldADS.button_pressed,
	})
	_cancel_settings()


func _on_settings_applied(values: Dictionary) -> void:
	apply_accessibility_settings(values)


func apply_accessibility_settings(values: Dictionary) -> void:
	_applied_ui_scale = clampf(float(values.get("ui_scale", 1.0)), 1.0, 2.0)
	_applied_subtitle_size = clampi(int(values.get("subtitle_size", 18)), 14, 32)
	_reduced_camera_motion = values.get("reduced_camera_motion", false) == true
	_screen_shake = values.get("screen_shake", true) == true
	$Root/Pages/BriefingPage/Copy.add_theme_font_size_override("font_size", _applied_subtitle_size)
	_apply_readability_scale(root, _applied_ui_scale)
	if hud.has_method(&"apply_accessibility_settings"):
		hud.call(&"apply_accessibility_settings", values)


func _apply_readability_scale(scope: Node, requested_scale: float) -> void:
	var multiplier := 1.0 + (requested_scale - 1.0) * 0.22
	for node: Node in scope.find_children("*", "Control", true, false):
		var control := node as Control
		if not (control is Label or control is Button or control is CheckButton):
			continue
		if not control.has_meta(&"fusepoint_base_font_size"):
			control.set_meta(&"fusepoint_base_font_size", control.get_theme_font_size("font_size"))
		var base_size := int(control.get_meta(&"fusepoint_base_font_size"))
		if base_size <= 0 or base_size >= 34:
			continue
		control.add_theme_font_size_override("font_size", maxi(base_size, int(round(base_size * multiplier))))


func _cancel_settings() -> void:
	_show_page(_return_from_settings)


func _on_player_died(_event: Dictionary) -> void:
	if app_state != STATE_GAMEPLAY or StringName(mission.get("mission_state")) != &"active_gameplay":
		return
	get_tree().paused = true
	player.call(&"set_gameplay_input_enabled", false)
	weapon.call(&"set_gameplay_input_enabled", false)
	$Root/Pages/DeathPage/Menu/RestartButton.visible = int(mission.get("checkpoint_version")) > 0
	_show_page(STATE_DEATH)


func _restart_checkpoint() -> void:
	if mission.call(&"request_checkpoint_restore") != true:
		_record_transition_rejection(&"checkpoint_restart", &"checkpoint_unavailable_or_illegal")
		return
	get_tree().paused = false
	_set_gameplay_enabled(true)
	_show_page(STATE_GAMEPLAY)


func _observe_input_family(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_last_input_family = &"gamepad"
	elif event is InputEventKey or event is InputEventMouse:
		_last_input_family = &"keyboard_mouse"


func _commit_transition(previous_state: StringName, next_state: StringName, reason: StringName) -> void:
	_last_transition_rejection = &""
	_last_transition_receipt = {
		"transition_id": "shell-transition-%06d" % _transition_serial,
		"sequence": _transition_serial,
		"previous_state": previous_state,
		"next_state": next_state,
		"reason": reason,
		"accepted": true,
		"rejection_reason": &"",
		"input_family": _last_input_family,
		"focused_control": "",
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled") == true,
		"ui_scale": _applied_ui_scale,
	}
	_transition_history.append(_last_transition_receipt.duplicate(true))
	while _transition_history.size() > TRANSITION_HISTORY_LIMIT:
		_transition_history.pop_front()


func _finalize_transition_focus() -> void:
	var focused := get_viewport().gui_get_focus_owner()
	var focused_path := str(focused.get_path()) if focused != null else ""
	_last_transition_receipt["focused_control"] = focused_path
	if not _transition_history.is_empty():
		_transition_history[-1]["focused_control"] = focused_path


func _record_transition_rejection(action: StringName, reason: StringName) -> void:
	_transition_serial += 1
	_last_transition_rejection = reason
	var focused := get_viewport().gui_get_focus_owner()
	_last_transition_receipt = {
		"transition_id": "shell-transition-%06d" % _transition_serial,
		"sequence": _transition_serial,
		"previous_state": app_state,
		"next_state": app_state,
		"reason": action,
		"accepted": false,
		"rejection_reason": reason,
		"input_family": _last_input_family,
		"focused_control": str(focused.get_path()) if focused != null else "",
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled") == true,
		"ui_scale": _applied_ui_scale,
	}
	_transition_history.append(_last_transition_receipt.duplicate(true))
	while _transition_history.size() > TRANSITION_HISTORY_LIMIT:
		_transition_history.pop_front()


func _layout_snapshot() -> Dictionary:
	var viewport_size := root.size
	var safe_margin := viewport_size * SAFE_AREA_RATIO
	var safe_rect := Rect2(safe_margin, viewport_size - safe_margin * 2.0)
	var violations: Array[String] = []
	if app_state != STATE_GAMEPLAY:
		var page := pages.get_node_or_null(_page_name(app_state))
		if page != null:
			for child: Node in page.find_children("*", "Control", true, false):
				var control := child as Control
				if not control.is_visible_in_tree() or not (control is Label or control is BaseButton or control is Range):
					continue
				var rect := control.get_global_rect()
				if not safe_rect.encloses(rect):
					violations.append(str(control.get_path()))
	return {
		"viewport_size": viewport_size,
		"safe_margin": safe_margin,
		"safe_rect": safe_rect,
		"critical_control_count": 0 if app_state == STATE_GAMEPLAY else (pages.get_node(_page_name(app_state)) as Control).find_children("*", "Control", true, false).size(),
		"violation_count": violations.size(),
		"violations": violations,
		"within_safe_area": violations.is_empty(),
	}


func _return_home() -> void:
	get_tree().paused = false
	terminal.reset_presentation(true, true)
	mission.call(&"reset_for_replay")
	_set_gameplay_enabled(false)
	_show_page(STATE_TITLE)


func _replay() -> void:
	get_tree().paused = false
	terminal.reset_presentation(true, true)
	mission.call(&"reset_for_replay")
	_set_gameplay_enabled(false)
	_show_page(STATE_LOADOUT)


func _on_terminal_presentation_completed(_event_id: String, result: StringName) -> void:
	if app_state == STATE_GAMEPLAY:
		_show_result(result)


func _show_result(result: StringName) -> void:
	_set_gameplay_enabled(false)
	var success := result == &"bomb_defused"
	$Root/Pages/ResultPage/Outcome.text = "MISSION COMPLETE" if success else "MISSION FAILED"
	$Root/Pages/ResultPage/Outcome.modulate = Color(0.2, 0.92, 0.82) if success else Color(1.0, 0.27, 0.18)
	var snapshot: Dictionary = mission.call(&"result_snapshot")
	var components: Dictionary = snapshot.get("score_components", {})
	var remaining := int(snapshot.get("remaining_seconds", 0))
	var completion := int(snapshot.get("completion_seconds", 0))
	var rank := int(snapshot.get("leaderboard_rank", 0))
	var rank_text := "—" if rank <= 0 else "#%d" % rank
	$Root/Pages/ResultPage/Metrics.text = "RESULT  %s    SCORE  %d\nCOMPLETION  %02d:%02d    REMAINING  %02d:%02d\nALPHA  %s    BRAVO  %s\nELIMINATIONS  %d    DEATHS  %d    RESTARTS  %d\n\nSCORE COMPONENTS\nTIME %+d  •  A %+d  •  B %+d  •  ELIMS %+d\nDIAGNOSIS %+d  •  ISOLATION %+d  •  DETONATOR %+d\nDEATHS %+d  •  RESTARTS %+d\n\nFASTEST-SUCCESS DELTA  %+.1fs    LEADERBOARD  %s" % [
		String(result).replace("_", " ").to_upper(), int(snapshot.get("score", 0)),
		completion / 60, completion % 60, remaining / 60, remaining % 60,
		"SECURED" if snapshot.get("alpha_captured", false) else "HOSTILE",
		"SECURED" if snapshot.get("bravo_captured", false) else "HOSTILE",
		int(snapshot.get("eliminations", 0)), int(snapshot.get("deaths", 0)), int(snapshot.get("restart_count", 0)),
		int(components.get("time", 0)), int(components.get("alpha", 0)), int(components.get("bravo", 0)), int(components.get("eliminations", 0)),
		int(components.get("diagnosis", 0)), int(components.get("power_isolation", 0)), int(components.get("detonator_removal", 0)),
		int(components.get("deaths", 0)), int(components.get("checkpoint_restarts", 0)),
		float(snapshot.get("fastest_success_delta", 0.0)), rank_text,
	]
	$Root/Pages/ResultPage/Menu/RestartButton.visible = not success and remaining > 0 and int(mission.get("checkpoint_version")) > 0
	_show_page(STATE_RESULT)


func _mcp_state() -> Dictionary:
	return {
		"app_state": app_state,
		"pages_visible": pages.visible,
		"selected_weapon": _selected_weapon,
		"transition_serial": _transition_serial,
		"last_transition_receipt": _last_transition_receipt,
		"transition_history": _transition_history,
		"last_transition_rejection": _last_transition_rejection,
		"last_input_family": _last_input_family,
		"briefing_elapsed": _briefing_elapsed,
		"briefing_caption_index": _briefing_caption_index,
		"briefing_caption_line_count": ($Root/Pages/BriefingPage/Copy as Label).text.count("\n") + 1,
		"briefing_complete": _briefing_complete,
		"briefing_skip_count": _briefing_skip_count,
		"deployment_requested": _deployment_requested,
		"applied_ui_scale": _applied_ui_scale,
		"applied_subtitle_size": _applied_subtitle_size,
		"reduced_camera_motion": _reduced_camera_motion,
		"screen_shake": _screen_shake,
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled"),
		"mission_state": mission.get("mission_state"),
		"terminal_presentation": terminal.snapshot(),
		"focused_control": str(get_viewport().gui_get_focus_owner().get_path()) if get_viewport().gui_get_focus_owner() != null else "",
		"layout": _layout_snapshot(),
	}
