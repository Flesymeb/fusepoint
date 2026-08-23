class_name FusepointProductShell
extends CanvasLayer

const STATE_TITLE := &"title"
const STATE_LOADOUT := &"loadout"
const STATE_LOADING := &"loading"
const STATE_BRIEFING := &"briefing"
const STATE_DEPLOYMENT := &"deployment"
const STATE_GAMEPLAY := &"gameplay"
const STATE_PAUSE := &"pause"
const STATE_SETTINGS := &"settings"
const STATE_DEATH := &"death_recovery"
const STATE_RECOVERING := &"recovery_transition"
const STATE_VICTORY := &"victory"
const STATE_DETONATION := &"detonation"
const STATE_SUCCESS_RESULT := &"success_result"
const STATE_FAILURE_RESULT := &"failure_result"
const DEATH_LOCK_SECONDS := 3.0
const BRIEFING_CAPTIONS: Array[String] = [
	"11:40 — KESTREL RIDGE MILITARY BASE\nRIFT FRONT SIGNALS CONFIRMED INSIDE THE PERIMETER.",
	"SECTOR C ROCKET MAINTENANCE BAY\nA FIVE-MINUTE DETONATION DEVICE IS ARMED.",
	"RETAKE ALPHA. SECURE BRAVO.\nRECOVER BOTH DEFUSAL KEYS.",
	"BREACH CHARLIE AND DISMANTLE THE DEVICE.\nSUPPORT IS NOT COMING.",
]
const BRIEFING_BEAT_SECONDS := 2.5
const TRANSITION_HISTORY_LIMIT := 32
const TERMINAL_RESULT_RECEIPT_LIMIT := 4
const SAFE_AREA_RATIO := 0.05
const LAYOUT_CONTRACT_ID := &"fusepoint_safe_area_v4_container_reflow"
const SETTINGS_COMPONENT_ASSET_ID := "github:Maaack/Godot-Menus-Template"
const SETTINGS_COMPONENT_RECEIPT := "res://ui/shell/maaacks_main_menu/agent_asset_receipt.json"
const SETTINGS_COMPONENT_MAIN_MENU := "res://ui/shell/maaacks_main_menu/main_menu.tscn"
const SETTINGS_COMPONENT_MAIN_SCRIPT := "res://ui/shell/maaacks_main_menu/main_menu.gd"
const SETTINGS_COMPONENT_BASE_SCENE := "res://addons/maaacks_menus_template/base/nodes/menus/main_menu/main_menu.tscn"
const SETTINGS_COMPONENT_SCENE: PackedScene = preload("res://ui/shell/maaacks_main_menu/main_menu.tscn")
const SETTINGS_COMPONENT_ROW_HEIGHT := 40.0
const NON_PAGE_STATES: Array[StringName] = [STATE_DEPLOYMENT, STATE_GAMEPLAY, STATE_VICTORY, STATE_DETONATION]
const LIFECYCLE_TABLE := {
	&"title": {"predecessors":[&"title",&"loadout",&"briefing",&"settings",&"pause",&"death_recovery",&"success_result",&"failure_result"], "authority":&"shell", "blocking":true, "focus":"Root/Pages/TitlePage/Menu/StartButton"},
	&"loadout": {"predecessors":[&"title",&"briefing",&"success_result",&"failure_result"], "authority":&"shell", "blocking":true, "focus":"Root/Pages/LoadoutPage/Content/Weapons/AKButton"},
	&"loading": {"predecessors":[&"loadout"], "authority":&"shell", "blocking":true, "focus":""},
	&"briefing": {"predecessors":[&"loading"], "authority":&"shell", "blocking":true, "focus":"Root/Pages/BriefingPage/Actions/DeployButton"},
	&"deployment": {"predecessors":[&"briefing"], "authority":&"mission", "blocking":true, "focus":""},
	&"gameplay": {"predecessors":[&"deployment",&"pause",&"recovery_transition"], "authority":&"mission", "blocking":false, "focus":""},
	&"pause": {"predecessors":[&"gameplay",&"settings"], "authority":&"shell", "blocking":true, "focus":"Root/Pages/PausePage/Menu/ResumeButton"},
	&"settings": {"predecessors":[&"title",&"pause"], "authority":&"shell", "blocking":true, "focus":"Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume"},
	&"death_recovery": {"predecessors":[&"gameplay"], "authority":&"player_death", "blocking":true, "focus":"Root/Pages/DeathPage/Menu/RestartButton"},
	&"recovery_transition": {"predecessors":[&"gameplay",&"death_recovery",&"pause",&"failure_result"], "authority":&"mission_recovery", "blocking":true, "focus":"Root/Pages/DeathPage/Menu/RestartButton"},
	&"victory": {"predecessors":[&"gameplay"], "authority":&"terminal", "blocking":true, "focus":""},
	&"detonation": {"predecessors":[&"gameplay"], "authority":&"terminal", "blocking":true, "focus":""},
	&"success_result": {"predecessors":[&"victory"], "authority":&"terminal", "blocking":true, "focus":"Root/Pages/ResultPage/Menu/ReplayButton"},
	&"failure_result": {"predecessors":[&"detonation"], "authority":&"terminal", "blocking":true, "focus":"Root/Pages/ResultPage/Menu/ReplayButton"},
}
const LIFECYCLE_ACTIONS := {
	&"replay": {"legal_from":[&"success_result",&"failure_result"], "target":&"loadout"},
	&"checkpoint_restart": {"legal_from":[&"gameplay",&"pause",&"death_recovery",&"failure_result"], "target":&"recovery_transition"},
	&"home": {"legal_from":[&"pause",&"death_recovery",&"success_result",&"failure_result"], "target":&"title"},
}

@onready var root: Control = $Root
@onready var pages: Control = $Root/Pages
@onready var settings_store: FusepointSettingsStore = $SettingsStore
@onready var mission: Node = get_node("../MissionController")
@onready var player: CharacterBody3D = get_node("../PrototypePlayer")
@onready var weapon: Node = get_node("../PrototypePlayer/Head/Camera3D/WeaponController")
@onready var roster: Node = get_node("../EnemyRoster")
@onready var hud: CanvasLayer = get_node("../TacticalHUD")
@onready var terminal: Node = get_node("../TerminalPresentation")
@onready var damage_feedback: Node = get_node("../PlayerDamageFeedback")
@onready var briefing_video: VideoStreamPlayer = $Root/Pages/BriefingPage/OpeningVideo
@onready var settings_scroll: ScrollContainer = $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll
@onready var settings_grid: GridContainer = $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings

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
var _death_lock_remaining := 0.0
var _active_recovery_epoch := 0
var _lifecycle_action_serial := 0
var _last_lifecycle_action_receipt: Dictionary = {}
var _lifecycle_action_history: Array[Dictionary] = []
var _observed_terminal_results: Dictionary = {}
var _terminal_result_receipts: Array[Dictionary] = []
var _opening_media_status := &"uninitialized"
var _opening_completion_source := &""
var _opening_completion_count := 0
var _activation_serial := 0
var _activation_frame := -1
var _last_activation_receipt: Dictionary = {}
var _settings_focus_history: Array[Dictionary] = []
var _last_settings_focus_receipt: Dictionary = {}
var _curated_menu_instance: Control
var _settings_component_row_height := SETTINGS_COMPONENT_ROW_HEIGHT
var _curated_menu_start_count := 0
var _last_curated_menu_lifecycle_receipt: Dictionary = {}
var _tester_setup_serial := 0
var _last_tester_setup_receipt: Dictionary = {}
var _tester_setup_history: Array[Dictionary] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The shell owns page input only while a blocking page is rendered. Keeping
	# either full-screen parent on STOP can swallow mouse look with hidden pages.
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_instantiate_curated_menu_component()
	_connect_controls()
	player.player_died.connect(_on_player_died)
	mission.mission_event_committed.connect(_on_mission_event_committed)
	terminal.presentation_completed.connect(_on_terminal_presentation_completed)
	damage_feedback.restore_feedback_completed.connect(_on_restore_feedback_completed)
	settings_store.settings_applied.connect(_on_settings_applied)
	root.resized.connect(_apply_responsive_layout)
	briefing_video.finished.connect(_on_opening_video_finished)
	_assert_curated_menu_binding()
	_set_gameplay_enabled(false)
	_load_settings_controls()
	settings_store.apply_runtime()
	_apply_responsive_layout.call_deferred()
	_show_page(STATE_TITLE)


func _connect_controls() -> void:
	$Root/Pages/LoadoutPage/Content/Weapons/AKButton.pressed.connect(_select_weapon.bind(&"ak74m"))
	$Root/Pages/LoadoutPage/Content/Weapons/SaigaButton.pressed.connect(_select_weapon.bind(&"saiga12"))
	$Root/Pages/LoadoutPage/Content/Actions/ConfirmButton.pressed.connect(_start_loading)
	$Root/Pages/LoadoutPage/Content/Actions/BackButton.pressed.connect(_show_page.bind(STATE_TITLE))
	$Root/Pages/BriefingPage/Actions/DeployButton.pressed.connect(_briefing_primary_action)
	$Root/Pages/BriefingPage/Actions/PauseButton.pressed.connect(_toggle_opening_pause)
	$Root/Pages/BriefingPage/Actions/BackButton.pressed.connect(_show_page.bind(STATE_LOADOUT))
	$Root/Pages/PausePage/Menu/ResumeButton.pressed.connect(_resume_gameplay)
	$Root/Pages/PausePage/Menu/SettingsButton.pressed.connect(_open_settings_from.bind(STATE_PAUSE))
	$Root/Pages/PausePage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/PausePage/Menu/HomeButton.pressed.connect(_return_home)
	$Root/Pages/SettingsPage/SafeArea/Layout/Actions/ApplyButton.pressed.connect(_apply_settings)
	$Root/Pages/SettingsPage/SafeArea/Layout/Actions/CancelButton.pressed.connect(_cancel_settings)
	$Root/Pages/DeathPage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/DeathPage/Menu/HomeButton.pressed.connect(_return_home)
	$Root/Pages/ResultPage/Menu/ReplayButton.pressed.connect(_replay)
	$Root/Pages/ResultPage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/ResultPage/Menu/HomeButton.pressed.connect(_return_home)
	for slider: Range in [
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/UIScale,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/FOV,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleSize,
	]:
		slider.value_changed.connect(func(_value: float) -> void: _sync_settings_value_copy())
	for toggle: BaseButton in [
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotion,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ScreenShake,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/HoldADS,
	]:
		toggle.toggled.connect(func(_pressed: bool) -> void: _sync_settings_value_copy())
	_configure_settings_navigation()
	_configure_settings_layout_contract()


func _settings_controls() -> Array[Control]:
	return [
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/UIScale,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/FOV,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleSize,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotion,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ScreenShake,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/HoldADS,
		$Root/Pages/SettingsPage/SafeArea/Layout/Actions/ApplyButton,
		$Root/Pages/SettingsPage/SafeArea/Layout/Actions/CancelButton,
	]


func _settings_labels() -> Array[Control]:
	return [
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterLabel,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/UIScaleLabel,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/FOVLabel,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleLabel,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotionLabel,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ShakeLabel,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ADSLabel,
	]


func _setting_label_for(control: Control) -> Control:
	var controls := _settings_controls()
	var index := controls.find(control)
	return _settings_labels()[index] if index >= 0 and index < 7 else control


func _settings_critical_nodes() -> Array[Control]:
	var nodes: Array[Control] = [$Root/Pages/SettingsPage/SafeArea/Layout/Title]
	nodes.append_array(_settings_labels())
	nodes.append_array(_settings_controls())
	return nodes


func _configure_settings_navigation() -> void:
	var controls := _settings_controls()
	for control: Control in controls:
		control.focus_mode = Control.FOCUS_ALL
		if not control.focus_entered.is_connected(_on_settings_focus_entered.bind(control)):
			control.focus_entered.connect(_on_settings_focus_entered.bind(control))
	var first := controls[0]
	var last_setting := controls[6]
	var apply_button := controls[7]
	var cancel_button := controls[8]
	for index in 7:
		var control := controls[index]
		var above: Control = apply_button if index == 0 else controls[index - 1]
		var below: Control = apply_button if index == 6 else controls[index + 1]
		control.focus_neighbor_top = control.get_path_to(above)
		control.focus_neighbor_bottom = control.get_path_to(below)
	apply_button.focus_neighbor_top = apply_button.get_path_to(last_setting)
	apply_button.focus_neighbor_bottom = apply_button.get_path_to(first)
	apply_button.focus_neighbor_right = apply_button.get_path_to(cancel_button)
	cancel_button.focus_neighbor_top = cancel_button.get_path_to(last_setting)
	cancel_button.focus_neighbor_bottom = cancel_button.get_path_to(first)
	cancel_button.focus_neighbor_left = cancel_button.get_path_to(apply_button)


func _configure_settings_layout_contract() -> void:
	# The product keeps its authoritative lifecycle while adapting the registered
	# Maaack main/pause bundle's compact 40-pixel row rhythm.
	var component_row_height := _settings_component_row_height
	for label_control: Control in _settings_labels():
		var label := label_control as Label
		label.custom_minimum_size = Vector2(0.0, maxf(36.0, component_row_height))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.clip_text = false
	for control: Control in _settings_controls().slice(0, 7):
		control.custom_minimum_size.y = maxf(48.0 if control is BaseButton else 38.0, component_row_height)
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _assert_curated_menu_binding() -> void:
	for source_path: String in [
		SETTINGS_COMPONENT_RECEIPT,
		SETTINGS_COMPONENT_MAIN_MENU,
		SETTINGS_COMPONENT_MAIN_SCRIPT,
		SETTINGS_COMPONENT_BASE_SCENE,
	]:
		if not FileAccess.file_exists(source_path):
			push_error("Required curated menu source is not materialized: %s" % source_path)
	if not is_instance_valid(_curated_menu_instance):
		push_error("Required curated menu PackedScene was not instantiated")


func _instantiate_curated_menu_component() -> void:
	_curated_menu_instance = SETTINGS_COMPONENT_SCENE.instantiate() as Control
	if _curated_menu_instance == null:
		push_error("Curated Maaack main_menu.tscn root is not a Control")
		return
	_curated_menu_instance.name = "MaaacksMainMenuRuntime"
	_curated_menu_instance.visible = true
	_curated_menu_instance.process_mode = Node.PROCESS_MODE_ALWAYS
	_curated_menu_instance.set_process_input(true)
	root.add_child(_curated_menu_instance)
	if _curated_menu_instance.has_signal(&"game_started"):
		_curated_menu_instance.connect(&"game_started", _on_curated_menu_game_started)
	if _curated_menu_instance.has_signal(&"game_exited"):
		_curated_menu_instance.connect(&"game_exited", get_tree().quit)
	if _curated_menu_instance.has_signal(&"settings_requested"):
		_curated_menu_instance.connect(&"settings_requested", _open_settings_from.bind(STATE_TITLE))
	var source_button := _curated_menu_instance.get_node_or_null(
		^"MenuContainer/MenuButtonsMargin/MenuButtonsContainer/MenuButtonsBoxContainer/NewGameButton"
	) as Button
	if source_button != null:
		_settings_component_row_height = maxf(
			SETTINGS_COMPONENT_ROW_HEIGHT,
			source_button.custom_minimum_size.y
		)


func _on_curated_menu_game_started() -> void:
	_curated_menu_start_count += 1
	_last_curated_menu_lifecycle_receipt = {
		"event": &"game_started",
		"source_path": str(_curated_menu_instance.get_path()),
		"source_scene": _curated_menu_instance.scene_file_path,
		"count": _curated_menu_start_count,
		"committed_frame": Engine.get_process_frames(),
		"predecessor_state": app_state,
	}
	_open_loadout()
	_last_curated_menu_lifecycle_receipt["result_state"] = app_state
func _on_settings_focus_entered(control: Control) -> void:
	if settings_scroll.is_ancestor_of(control):
		_reveal_settings_pair.call_deferred(control)
	else:
		_finalize_settings_focus_receipt.call_deferred(control)


func _reveal_settings_pair(control: Control) -> void:
	if app_state != STATE_SETTINGS or not is_instance_valid(control):
		return
	settings_scroll.ensure_control_visible(control)
	var label := _setting_label_for(control)
	var scroll_rect := settings_scroll.get_global_rect()
	var pair_rect := label.get_global_rect().merge(control.get_global_rect())
	if pair_rect.position.y < scroll_rect.position.y:
		settings_scroll.scroll_vertical -= int(ceil(scroll_rect.position.y - pair_rect.position.y))
	elif pair_rect.end.y > scroll_rect.end.y:
		settings_scroll.scroll_vertical += int(ceil(pair_rect.end.y - scroll_rect.end.y))
	_finalize_settings_focus_receipt.call_deferred(control)


func _finalize_settings_focus_receipt(control: Control) -> void:
	if app_state != STATE_SETTINGS or not is_instance_valid(control):
		return
	var scroll_rect := settings_scroll.get_global_rect()
	var control_rect := control.get_global_rect()
	var label := _setting_label_for(control)
	var label_rect := label.get_global_rect()
	var pair_visible := not settings_scroll.is_ancestor_of(control) or (scroll_rect.encloses(control_rect) and scroll_rect.encloses(label_rect))
	var actions_rect: Rect2 = ($Root/Pages/SettingsPage/SafeArea/Layout/Actions as Control).get_global_rect()
	_last_settings_focus_receipt = {
		"run_epoch": int(mission.get("run_epoch")),
		"page": STATE_SETTINGS,
		"input_family": _last_input_family,
		"focused_control": control.get_path(),
		"focus_visible_in_scroll": pair_visible,
		"associated_label": label.get_path(),
		"associated_label_rect": label_rect,
		"label_control_pair_visible": pair_visible,
		"persistent_action_path_visible": Rect2(root.size * SAFE_AREA_RATIO, root.size * 0.9).encloses(actions_rect),
		"scroll_vertical": settings_scroll.scroll_vertical,
		"scroll_viewport_rect": scroll_rect,
		"control_rect": control_rect,
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled") == true,
		"ui_scale": _applied_ui_scale,
		"accepted": true,
	}
	_settings_focus_history.append(_last_settings_focus_receipt.duplicate(true))
	while _settings_focus_history.size() > TRANSITION_HISTORY_LIMIT:
		_settings_focus_history.pop_front()


func _input(event: InputEvent) -> void:
	_observe_input_family(event)
	if event.is_action_pressed(&"tester_alpha_checkpoint"):
		_tester_prepare_alpha_checkpoint()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"tester_shell_death"):
		_tester_prepare_shell_death()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"tester_shell_failure_result"):
		_tester_prepare_failure_result()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"tester_shell_replay"):
		_tester_prepare_replay()
		get_viewport().set_input_as_handled()
		return
	if app_state == STATE_BRIEFING and not _briefing_complete and (
		event.is_action_pressed(&"skip_presentation") or _is_physical_briefing_skip(event)
	):
		_complete_briefing(true)
		_deploy()
		get_viewport().set_input_as_handled()
		return
	if app_state == STATE_GAMEPLAY and event.is_action_pressed(&"restart"):
		_restart_checkpoint()
		get_viewport().set_input_as_handled()
		return
	if pages.visible and app_state != STATE_GAMEPLAY and event.is_action_pressed(&"menu_accept"):
		if _activate_focused_control_once():
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


func _is_physical_briefing_skip(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo and (
		event.physical_keycode == KEY_G or event.keycode == KEY_G
	)


func _tester_prepare_alpha_checkpoint() -> void:
	var receipt := _new_tester_setup_receipt(&"alpha_checkpoint_entry")
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var mission_setup: Dictionary = mission.call(&"tester_prepare_alpha_checkpoint")
	receipt["mission_setup"] = mission_setup
	if mission_setup.get("accepted", false) != true:
		receipt["failure_reason"] = mission_setup.get("failure_reason", &"mission_setup_rejected")
		_store_tester_setup_receipt(receipt)
		return
	_restart_checkpoint()
	var recovery: Dictionary = mission.get("last_checkpoint_restore_receipt")
	receipt["resolved"] = true
	receipt["accepted"] = app_state == STATE_RECOVERING and recovery.get("committed", false) == true
	receipt["recovery"] = recovery.duplicate(true)
	receipt["reset_isolation"] = {
		"authoritative_checkpoint_api": true,
		"route_acceptance_claimed": false,
		"single_recovery_command": not recovery.get("command_id", "").is_empty(),
		"input_locked_until_feedback_handoff": recovery.get("input_locked", false) == true,
		"roster_restore_count": int(recovery.get("restored_actor_count", 0)),
	}
	receipt["failure_reason"] = &"" if receipt["accepted"] else &"recovery_transition_rejected"
	_store_tester_setup_receipt(receipt)


func _tester_prepare_shell_death() -> void:
	var receipt := _new_tester_setup_receipt(&"ordinary_death")
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var run_epoch_before := int(mission.get("run_epoch"))
	var checkpoint_before := int(mission.get("checkpoint_version"))
	var timer_before := float(mission.get("remaining_time"))
	var damage_event_id := "%s:ordinary-death" % receipt["setup_id"]
	var applied: bool = player.call(&"apply_authoritative_damage", float(player.get("max_health")) + 1.0, damage_event_id, {
		"damage_class": &"tester_authoritative_damage",
		"source_path": get_path(),
		"source_position": player.global_position,
	})
	receipt["resolved"] = true
	receipt["accepted"] = applied and app_state == STATE_DEATH and player.get("health") <= 0.0
	receipt["authoritative_damage_event_id"] = damage_event_id
	receipt["reset_isolation"] = {
		"run_epoch_unchanged": int(mission.get("run_epoch")) == run_epoch_before,
		"checkpoint_version_unchanged": int(mission.get("checkpoint_version")) == checkpoint_before,
		"countdown_not_advanced": float(mission.get("remaining_time")) <= timer_before + 0.001,
		"death_lock_authoritative": app_state == STATE_DEATH and get_tree().paused,
	}
	receipt["failure_reason"] = &"" if receipt["accepted"] else &"authoritative_death_rejected"
	_store_tester_setup_receipt(receipt)


func _tester_prepare_failure_result() -> void:
	var receipt := _new_tester_setup_receipt(&"failure_result")
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var run_epoch_before := int(mission.get("run_epoch"))
	var terminal_count_before := int(mission.get("terminal_commit_count"))
	var countdown_receipt: Dictionary = mission.call(&"tester_request_countdown_zero")
	var presentation_receipt: Dictionary = terminal.call(&"tester_complete_active_presentation") if countdown_receipt.get("accepted", false) == true else {}
	receipt["resolved"] = true
	receipt["accepted"] = countdown_receipt.get("accepted", false) == true and presentation_receipt.get("accepted", false) == true and app_state == STATE_FAILURE_RESULT
	receipt["countdown"] = countdown_receipt
	receipt["presentation"] = presentation_receipt
	receipt["reset_isolation"] = {
		"run_epoch_unchanged": int(mission.get("run_epoch")) == run_epoch_before,
		"single_terminal_commit": int(mission.get("terminal_commit_count")) == terminal_count_before + 1,
		"duplicate_terminal_submit_count": int(mission.get("terminal_duplicate_submit_count")),
		"authoritative_result_state": app_state == STATE_FAILURE_RESULT,
	}
	receipt["failure_reason"] = &"" if receipt["accepted"] else &"authoritative_failure_result_rejected"
	_store_tester_setup_receipt(receipt)


func _tester_prepare_replay() -> void:
	var receipt := _new_tester_setup_receipt(&"replay")
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		_store_tester_setup_receipt(receipt)
		return
	if app_state not in [STATE_SUCCESS_RESULT, STATE_FAILURE_RESULT]:
		receipt["failure_reason"] = &"required_result_state_unavailable"
		_store_tester_setup_receipt(receipt)
		return
	var run_epoch_before := int(mission.get("run_epoch"))
	_replay()
	receipt["resolved"] = true
	receipt["accepted"] = app_state == STATE_LOADOUT and int(mission.get("run_epoch")) == run_epoch_before + 1
	receipt["reset_isolation"] = {
		"new_run_epoch": int(mission.get("run_epoch")),
		"previous_run_epoch": run_epoch_before,
		"mission_predeployment": StringName(mission.get("mission_state")) == &"predeployment",
		"gameplay_input_disabled": player.get("gameplay_input_enabled") == false,
		"terminal_cache_cleared": _observed_terminal_results.is_empty(),
	}
	receipt["failure_reason"] = &"" if receipt["accepted"] else &"authoritative_replay_rejected"
	_store_tester_setup_receipt(receipt)


func _new_tester_setup_receipt(kind: StringName) -> Dictionary:
	_tester_setup_serial += 1
	return {
		"setup_id": "tester-shell-%06d" % _tester_setup_serial,
		"kind": kind,
		"requested": true,
		"resolved": false,
		"accepted": false,
		"non_release": OS.is_debug_build(),
		"source_state": app_state,
		"run_epoch": int(mission.get("run_epoch")),
	}


func _tester_setup_available(required_state: StringName, receipt: Dictionary) -> bool:
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return false
	if app_state != required_state or StringName(mission.get("mission_state")) != &"active_gameplay":
		receipt["failure_reason"] = &"authoritative_gameplay_state_unavailable"
		return false
	return true


func _store_tester_setup_receipt(receipt: Dictionary) -> void:
	_last_tester_setup_receipt = receipt.duplicate(true)
	_tester_setup_history.append(_last_tester_setup_receipt.duplicate(true))
	while _tester_setup_history.size() > TRANSITION_HISTORY_LIMIT:
		_tester_setup_history.pop_front()


func _activate_focused_control_once() -> bool:
	var focused := get_viewport().gui_get_focus_owner()
	if not (focused is BaseButton):
		return false
	var button := focused as BaseButton
	if not button.is_visible_in_tree() or button.disabled:
		return false
	var frame := Engine.get_process_frames()
	if frame == _activation_frame:
		return true
	_activation_frame = frame
	_activation_serial += 1
	_last_activation_receipt = {
		"activation_id": "shell-activation-%06d" % _activation_serial,
		"frame": frame,
		"state": app_state,
		"input_family": _last_input_family,
		"focused_control": button.get_path(),
		"enabled": true,
		"emission_count": 1,
	}
	if button.toggle_mode:
		button.button_pressed = not button.button_pressed
	button.pressed.emit()
	return true


func _process(delta: float) -> void:
	if app_state == STATE_LOADING and _loading_remaining > 0.0:
		_loading_remaining = maxf(_loading_remaining - delta, 0.0)
		$Root/Pages/LoadingPage/Progress.value = (1.0 - _loading_remaining / 1.35) * 100.0
		if _loading_remaining <= 0.0:
			_show_page(STATE_BRIEFING)
	elif app_state == STATE_BRIEFING and not _briefing_complete:
		_update_briefing(delta)
	elif app_state == STATE_DEATH and _death_lock_remaining > 0.0:
		_death_lock_remaining = maxf(0.0, _death_lock_remaining - delta)
		var recovery_button := $Root/Pages/DeathPage/Menu/RestartButton as Button
		recovery_button.disabled = _death_lock_remaining > 0.0
		recovery_button.text = "RECOVERY READY IN %.1f" % _death_lock_remaining if recovery_button.disabled else _recovery_button_text()
		if not recovery_button.disabled:
			recovery_button.grab_focus()


func _show_page(state: StringName, reason := &"page_change", authority := &"shell") -> bool:
	var previous_state := app_state
	var rule: Dictionary = LIFECYCLE_TABLE.get(state, {})
	if rule.is_empty() or not (previous_state in (rule.get("predecessors", []) as Array)) or StringName(rule.get("authority", &"")) != authority:
		_record_transition_rejection(reason, &"illegal_lifecycle_edge")
		return false
	if previous_state == STATE_BRIEFING and state != STATE_BRIEFING:
		briefing_video.stop()
		briefing_video.visible = false
	var focused_before := get_viewport().gui_get_focus_owner()
	if focused_before != null and previous_state != STATE_GAMEPLAY:
		_focus_by_state[previous_state] = focused_before.get_path()
	_transition_serial += 1
	app_state = state
	pages.visible = state not in NON_PAGE_STATES
	root.visible = pages.visible
	if not pages.visible and focused_before != null:
		focused_before.release_focus()
	for child in pages.get_children():
		(child as Control).visible = child.name == _page_name(state)
	if is_instance_valid(_curated_menu_instance):
		var curated_title_active := state == STATE_TITLE and pages.visible
		_curated_menu_instance.visible = curated_title_active
		_curated_menu_instance.set_process_input(false)
		if curated_title_active:
			_enable_curated_menu_input_if_title.call_deferred()
		$Root/Pages/TitlePage.visible = false if curated_title_active else $Root/Pages/TitlePage.visible
	if state == STATE_BRIEFING:
		_start_briefing()
	if state not in [STATE_GAMEPLAY, STATE_DEPLOYMENT, STATE_VICTORY, STATE_DETONATION]:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_focus_first_button.call_deferred()
	_commit_transition(previous_state, state, reason)
	_apply_responsive_layout.call_deferred()
	return true


func _enable_curated_menu_input_if_title() -> void:
	if (
		app_state == STATE_TITLE
		and is_instance_valid(_curated_menu_instance)
		and _curated_menu_instance.is_visible_in_tree()
	):
		_curated_menu_instance.set_process_input(true)


func _page_name(state: StringName) -> String:
	return {
		STATE_TITLE: "TitlePage",
		STATE_LOADOUT: "LoadoutPage",
		STATE_LOADING: "LoadingPage",
		STATE_BRIEFING: "BriefingPage",
		STATE_PAUSE: "PausePage",
		STATE_SETTINGS: "SettingsPage",
		STATE_DEATH: "DeathPage",
		STATE_RECOVERING: "DeathPage",
		STATE_SUCCESS_RESULT: "ResultPage",
		STATE_FAILURE_RESULT: "ResultPage",
	}.get(state, "TitlePage")


func _focus_first_button() -> void:
	if app_state == STATE_TITLE and is_instance_valid(_curated_menu_instance) and _curated_menu_instance.is_visible_in_tree():
		var curated_start := _curated_menu_instance.get_node_or_null(
			^"MenuContainer/MenuButtonsMargin/MenuButtonsContainer/MenuButtonsBoxContainer/NewGameButton"
		) as Button
		if curated_start != null and not curated_start.disabled:
			curated_start.grab_focus()
			_finalize_transition_focus()
			return
	var page := pages.get_node_or_null(_page_name(app_state))
	if page == null:
		return
	var focus_path := String((LIFECYCLE_TABLE.get(app_state, {}) as Dictionary).get("focus", ""))
	if not focus_path.is_empty():
		var prescribed := get_node_or_null(focus_path) as Control
		var prescribed_enabled := not (prescribed is BaseButton) or not (prescribed as BaseButton).disabled
		if prescribed != null and prescribed.visible and prescribed.focus_mode != Control.FOCUS_NONE and prescribed_enabled:
			prescribed.grab_focus()
			_finalize_transition_focus()
			return
	var remembered_path: NodePath = _focus_by_state.get(app_state, NodePath())
	if not remembered_path.is_empty():
		var remembered := get_node_or_null(remembered_path) as Control
		var remembered_enabled := not (remembered is BaseButton) or not (remembered as BaseButton).disabled
		if remembered != null and remembered.visible and remembered.focus_mode != Control.FOCUS_NONE and remembered_enabled:
			remembered.grab_focus()
			_finalize_transition_focus()
			return
	for node: Node in page.find_children("*", "Control", true, false):
		var control := node as Control
		var enabled := not (control is BaseButton) or not (control as BaseButton).disabled
		if control.visible and control.focus_mode != Control.FOCUS_NONE and enabled:
			control.grab_focus()
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
	_opening_completion_source = &""
	_opening_completion_count = 0
	$Root/Pages/BriefingPage/Error.text = ""
	var deploy_button := $Root/Pages/BriefingPage/Actions/DeployButton as Button
	var pause_button := $Root/Pages/BriefingPage/Actions/PauseButton as Button
	deploy_button.text = "SKIP BRIEFING  ▶"
	deploy_button.disabled = false
	pause_button.text = "Ⅱ  PAUSE"
	pause_button.disabled = briefing_video.stream == null
	if briefing_video.stream != null:
		_opening_media_status = &"playing"
		briefing_video.visible = true
		briefing_video.paused = false
		briefing_video.play()
	else:
		_opening_media_status = &"matched_still_fallback"
		briefing_video.visible = false
	_update_briefing(0.0)


func _update_briefing(delta: float) -> void:
	if briefing_video.stream != null and briefing_video.paused:
		return
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


func _toggle_opening_pause() -> void:
	if app_state != STATE_BRIEFING or _briefing_complete or briefing_video.stream == null:
		return
	briefing_video.paused = not briefing_video.paused
	_opening_media_status = &"paused" if briefing_video.paused else &"playing"
	($Root/Pages/BriefingPage/Actions/PauseButton as Button).text = "▶  RESUME" if briefing_video.paused else "Ⅱ  PAUSE"


func _complete_briefing(skipped: bool) -> void:
	if _briefing_complete:
		return
	_briefing_complete = true
	_opening_completion_count += 1
	_opening_completion_source = &"skip" if skipped else &"video_finished" if _opening_media_status == &"finished" else &"timed_caption_complete"
	if briefing_video.is_playing():
		briefing_video.stop()
	($Root/Pages/BriefingPage/Actions/PauseButton as Button).disabled = true
	if skipped:
		_briefing_skip_count += 1
		_opening_media_status = &"skipped"
	elif _opening_media_status != &"matched_still_fallback":
		_opening_media_status = &"completed"
	$Root/Pages/BriefingPage/Copy.text = "MISSION PACKAGE SYNCHRONIZED\nAUTHORIZE DEPLOYMENT WHEN READY."
	$Root/Pages/BriefingPage/Actions/DeployButton.text = "AUTHORIZE DEPLOYMENT  ▶"


func _on_opening_video_finished() -> void:
	if app_state != STATE_BRIEFING or _briefing_complete:
		return
	_opening_media_status = &"finished"
	_complete_briefing(false)


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
	if not _show_page(STATE_DEPLOYMENT, &"deployment_committed", &"mission"):
		return
	_set_gameplay_enabled(true)
	_show_page(STATE_GAMEPLAY, &"deployment_handoff", &"mission")


func _set_gameplay_enabled(enabled: bool) -> void:
	player.call(&"set_gameplay_input_enabled", enabled)
	weapon.call(&"set_gameplay_input_enabled", enabled)
	roster.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
	hud.call(&"set_hud_enabled", enabled)


func _pause_gameplay() -> void:
	if app_state != STATE_GAMEPLAY:
		return
	$Root/Pages/PausePage/Menu/RestartButton.visible = not (mission.get("deployment_snapshot") as Dictionary).is_empty() or int(mission.get("checkpoint_version")) > 0
	player.call(&"set_gameplay_input_enabled", false)
	weapon.call(&"set_gameplay_input_enabled", false)
	roster.call(&"reset_transient_feedback")
	get_tree().paused = true
	_show_page(STATE_PAUSE)


func _resume_gameplay() -> void:
	if app_state != STATE_PAUSE:
		return
	get_tree().paused = false
	player.call(&"set_gameplay_input_enabled", true)
	weapon.call(&"set_gameplay_input_enabled", true)
	_show_page(STATE_GAMEPLAY, &"resume", &"mission")


func _open_settings_from(return_state: StringName) -> void:
	_return_from_settings = return_state
	_load_settings_controls()
	settings_scroll.scroll_vertical = 0
	_show_page(STATE_SETTINGS)


func _load_settings_controls() -> void:
	var values := settings_store.snapshot()
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume.value = float(values["master_volume"]) * 100.0
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/UIScale.value = float(values["ui_scale"]) * 100.0
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/FOV.value = float(values["fov"])
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleSize.value = float(values["subtitle_size"])
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotion.button_pressed = bool(values["reduced_camera_motion"])
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ScreenShake.button_pressed = bool(values["screen_shake"])
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/HoldADS.button_pressed = bool(values["hold_ads"])
	_sync_settings_value_copy()


func _sync_settings_value_copy() -> void:
	var master := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume as Range
	var ui := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/UIScale as Range
	var fov := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/FOV as Range
	var subtitle := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleSize as Range
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterLabel.text = "MASTER VOLUME   %d%%" % int(round(master.value))
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/UIScaleLabel.text = "UI SCALE   %d%%" % int(round(ui.value))
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/FOVLabel.text = "FIELD OF VIEW   %d°" % int(round(fov.value))
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleLabel.text = "SUBTITLE SIZE / OUTLINE   %d PX" % int(round(subtitle.value))
	var reduced := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotion as BaseButton
	var shake := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ScreenShake as BaseButton
	var ads := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/HoldADS as BaseButton
	reduced.text = "ENABLED" if reduced.button_pressed else "DISABLED"
	shake.text = "ENABLED" if shake.button_pressed else "DISABLED"
	ads.text = "HOLD" if ads.button_pressed else "TOGGLE"


func _apply_settings() -> void:
	settings_store.save_settings({
		"master_volume": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume.value / 100.0,
		"ui_scale": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/UIScale.value / 100.0,
		"fov": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/FOV.value,
		"subtitle_size": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleSize.value,
		"reduced_camera_motion": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotion.button_pressed,
		"screen_shake": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ScreenShake.button_pressed,
		"hold_ads": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/HoldADS.button_pressed,
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
	_apply_responsive_layout.call_deferred()
	if hud.has_method(&"apply_accessibility_settings"):
		hud.call(&"apply_accessibility_settings", values)


func _apply_readability_scale(scope: Node, requested_scale: float) -> void:
	var multiplier := 1.0 + (requested_scale - 1.0) * 0.38
	for node: Node in scope.find_children("*", "Control", true, false):
		var control := node as Control
		if not (control is Label or control is Button or control is CheckButton):
			continue
		if not control.has_meta(&"fusepoint_base_font_size"):
			control.set_meta(&"fusepoint_base_font_size", control.get_theme_font_size("font_size"))
		var base_size := int(control.get_meta(&"fusepoint_base_font_size"))
		if base_size <= 0 or base_size >= 42:
			continue
		control.add_theme_font_size_override("font_size", maxi(base_size, int(round(base_size * multiplier))))


func _set_rect(control_path: NodePath, rect: Rect2) -> void:
	var control := get_node_or_null(control_path) as Control
	if control == null:
		return
	control.position = rect.position
	control.size = rect.size


func _apply_responsive_layout() -> void:
	var viewport := root.size
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		return
	var margin := Vector2(maxf(viewport.x * SAFE_AREA_RATIO, 32.0), maxf(viewport.y * SAFE_AREA_RATIO, 24.0))
	var safe := Rect2(margin, viewport - margin * 2.0)
	var expanded := _applied_ui_scale > 1.5
	# Settings uses semantic typography scaling, then reflows its content. At the
	# largest accessibility scale each label/control pair becomes two full-width
	# rows inside the focus-following ScrollContainer; no CanvasLayer transform or
	# fixed 820/420 px accommodation is involved.
	var settings_single_column := expanded or safe.size.x < 960.0
	settings_grid.columns = 1 if settings_single_column else 2
	settings_grid.custom_minimum_size.x = 0.0
	settings_grid.add_theme_constant_override("h_separation", 0 if settings_single_column else 36)
	settings_grid.add_theme_constant_override("v_separation", 14 if settings_single_column else 18)
	for control: Control in _settings_controls().slice(0, 7):
		control.custom_minimum_size.x = 0.0 if settings_single_column else 280.0
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for label: Control in _settings_labels():
		label.custom_minimum_size.x = 0.0
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_set_rect(^"Root/Pages/TitlePage/Accent", Rect2(safe.position, Vector2(4.0, safe.size.y - 28.0)))
	_set_rect(^"Root/Pages/TitlePage/Brand", Rect2(safe.position + Vector2(28.0, 24.0), Vector2(560.0, 212.0)))
	_set_rect(^"Root/Pages/TitlePage/Menu", Rect2(safe.position + Vector2(24.0, 292.0), Vector2(430.0, 238.0)))
	_set_rect(^"Root/Pages/TitlePage/Status", Rect2(safe.position + Vector2(28.0, safe.size.y - 64.0), Vector2(560.0, 58.0)))
	_set_rect(^"Root/Pages/LoadoutPage/Header", Rect2(safe.position + Vector2(0.0, 4.0), Vector2(safe.size.x, 62.0)))
	_set_rect(^"Root/Pages/LoadoutPage/Content", Rect2(safe.position + Vector2(0.0, 82.0), Vector2(620.0, safe.size.y - 88.0)))
	_set_rect(^"Root/Pages/LoadoutPage/RoutePlate", Rect2(Vector2(safe.end.x - 448.0, safe.position.y + 82.0), Vector2(448.0, safe.size.y - 88.0)))
	_set_rect(^"Root/Pages/LoadingPage/Title", Rect2(Vector2(safe.position.x, safe.end.y - 198.0), Vector2(840.0, 60.0)))
	_set_rect(^"Root/Pages/LoadingPage/Detail", Rect2(Vector2(safe.position.x, safe.end.y - 130.0), Vector2(930.0, 64.0)))
	_set_rect(^"Root/Pages/LoadingPage/Progress", Rect2(Vector2(safe.position.x, safe.end.y - 34.0), Vector2(safe.size.x * 0.82, 8.0)))
	# The opening media is the briefing surface, not a card inside it. Keep copy
	# and controls on the safe-area grid while the retained VideoStreamPlayer
	# fills the complete viewport behind those native caption layers.
	_set_rect(^"Root/Pages/BriefingPage/OpeningVideo", Rect2(Vector2.ZERO, viewport))
	_set_rect(^"Root/Pages/BriefingPage/Title", Rect2(safe.position, Vector2(safe.size.x, 58.0)))
	_set_rect(^"Root/Pages/BriefingPage/Copy", Rect2(Vector2(safe.position.x + 12.0, safe.end.y - 194.0), Vector2(safe.size.x - 24.0, 86.0 if expanded else 98.0)))
	_set_rect(^"Root/Pages/BriefingPage/Actions", Rect2(Vector2(safe.position.x, safe.end.y - 92.0), Vector2(660.0, 64.0)))
	_set_rect(^"Root/Pages/BriefingPage/Error", Rect2(Vector2(safe.position.x + 684.0, safe.end.y - 82.0), Vector2(safe.size.x - 684.0, 44.0)))
	_set_rect(^"Root/Pages/PausePage/Title", Rect2(safe.position + Vector2(16.0, 54.0), Vector2(560.0, 72.0)))
	_set_rect(^"Root/Pages/PausePage/Menu", Rect2(safe.position + Vector2(16.0, 164.0), Vector2(420.0, 330.0)))
	_set_rect(^"Root/Pages/DeathPage/Title", Rect2(safe.position + Vector2(16.0, 108.0), Vector2(safe.size.x - 32.0, 86.0)))
	_set_rect(^"Root/Pages/DeathPage/Copy", Rect2(safe.position + Vector2(16.0, 222.0), Vector2(safe.size.x - 32.0, 100.0)))
	_set_rect(^"Root/Pages/DeathPage/Menu", Rect2(Vector2(safe.position.x + 16.0, safe.end.y - 120.0), Vector2(720.0, 72.0)))
	_set_rect(^"Root/Pages/ResultPage/Outcome", Rect2(safe.position + Vector2(16.0, 28.0), Vector2(safe.size.x - 32.0, 74.0)))
	_set_rect(^"Root/Pages/ResultPage/Metrics", Rect2(safe.position + Vector2(16.0, 118.0), Vector2(safe.size.x - 32.0, safe.size.y - 244.0)))
	_set_rect(^"Root/Pages/ResultPage/Menu", Rect2(Vector2(safe.position.x + 16.0, safe.end.y - 94.0), Vector2(820.0, 70.0)))


func _cancel_settings() -> void:
	_show_page(_return_from_settings)


func _on_player_died(_event: Dictionary) -> void:
	if app_state != STATE_GAMEPLAY or StringName(mission.get("mission_state")) != &"active_gameplay":
		return
	get_tree().paused = true
	player.call(&"enter_combat_death_lock")
	player.call(&"set_gameplay_input_enabled", false)
	weapon.call(&"set_gameplay_input_enabled", false)
	roster.call(&"reset_transient_feedback")
	_death_lock_remaining = DEATH_LOCK_SECONDS
	var recovery_button := $Root/Pages/DeathPage/Menu/RestartButton as Button
	recovery_button.visible = true
	recovery_button.disabled = true
	recovery_button.text = "RECOVERY READY IN %.1f" % DEATH_LOCK_SECONDS
	$Root/Pages/DeathPage/Copy.text = "Mission clock is locked during recovery.\n%s" % (
		"Restore the latest secured checkpoint without gaining time." if int(mission.get("checkpoint_version")) > 0
		else "Return to the deployment entry without gaining time."
	)
	_show_page(STATE_DEATH, &"ordinary_death", &"player_death")


func _restart_checkpoint() -> void:
	if app_state == STATE_DEATH and _death_lock_remaining > 0.0:
		_record_transition_rejection(&"mission_recovery", &"death_lock_active")
		return
	if not _commit_lifecycle_action(&"checkpoint_restart"):
		return
	if mission.call(&"request_recovery") != true:
		_last_lifecycle_action_receipt["accepted"] = false
		_last_lifecycle_action_receipt["failure_reason"] = &"mission_recovery_rejected"
		if not _lifecycle_action_history.is_empty():
			_lifecycle_action_history[-1] = _last_lifecycle_action_receipt.duplicate(true)
		_record_transition_rejection(&"checkpoint_restart", &"checkpoint_unavailable_or_illegal")
		return
	var receipt: Dictionary = mission.get("last_checkpoint_restore_receipt")
	_active_recovery_epoch = int(receipt.get("restore_epoch", 0))
	get_tree().paused = false
	_set_gameplay_enabled(false)
	var recovery_button := $Root/Pages/DeathPage/Menu/RestartButton as Button
	recovery_button.disabled = true
	recovery_button.text = "RESTORING MISSION STATE"
	_show_page(STATE_RECOVERING, &"recovery_receipt_committed", &"mission_recovery")


func _recovery_button_text() -> String:
	return "RECOVER DEPLOYMENT" if int(mission.get("checkpoint_version")) == 0 else "RESTART CHECKPOINT"


func _on_restore_feedback_completed(epoch: int) -> void:
	if app_state != STATE_RECOVERING or epoch != _active_recovery_epoch:
		return
	if mission.call(&"complete_recovery_handoff", epoch) != true:
		_record_transition_rejection(&"recovery_handoff", &"restore_receipt_invalid")
		return
	_active_recovery_epoch = 0
	get_tree().paused = false
	_set_gameplay_enabled(true)
	_show_page(STATE_GAMEPLAY, &"recovery_handoff", &"mission")
	if StringName(_last_tester_setup_receipt.get("kind", &"")) == &"alpha_checkpoint_entry":
		_last_tester_setup_receipt["handoff_resolved"] = true
		_last_tester_setup_receipt["handoff_epoch"] = epoch
		_last_tester_setup_receipt["result_state"] = app_state
		_last_tester_setup_receipt["accepted"] = app_state == STATE_GAMEPLAY and player.get("gameplay_input_enabled") == true
		if not _tester_setup_history.is_empty():
			_tester_setup_history[-1] = _last_tester_setup_receipt.duplicate(true)


func _commit_lifecycle_action(action: StringName) -> bool:
	var rule: Dictionary = LIFECYCLE_ACTIONS.get(action, {})
	if rule.is_empty() or not (app_state in (rule.get("legal_from", []) as Array)):
		_record_transition_rejection(action, &"illegal_lifecycle_action")
		return false
	_lifecycle_action_serial += 1
	_last_lifecycle_action_receipt = {
		"action_id": "run-%06d:shell-action-%06d" % [int(mission.get("run_epoch")), _lifecycle_action_serial],
		"run_epoch": int(mission.get("run_epoch")),
		"action": action,
		"source_state": app_state,
		"target_state": rule.get("target", &""),
		"authoritative_mission_state": mission.get("mission_state"),
		"recovery_epoch": int(mission.get("enemy_restore_epoch")),
		"terminal_event_id": String(mission.get("terminal_event_id")),
		"accepted": true,
	}
	_lifecycle_action_history.append(_last_lifecycle_action_receipt.duplicate(true))
	while _lifecycle_action_history.size() > TRANSITION_HISTORY_LIMIT:
		_lifecycle_action_history.pop_front()
	return true


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
		"lifecycle_authority": (LIFECYCLE_TABLE.get(next_state, {}) as Dictionary).get("authority", &"unknown"),
		"blocking": (LIFECYCLE_TABLE.get(next_state, {}) as Dictionary).get("blocking", true),
		"focus_target": (LIFECYCLE_TABLE.get(next_state, {}) as Dictionary).get("focus", ""),
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
	var settings_reflow := {}
	if app_state != STATE_GAMEPLAY:
		var page := pages.get_node_or_null(_page_name(app_state))
		if page != null:
			for child: Node in page.find_children("*", "Control", true, false):
				var control := child as Control
				if not control.is_visible_in_tree() or not (control is Label or control is BaseButton or control is Range):
					continue
				# Scroll content outside the viewport is intentionally reachable, not
				# clipped product UI. The ScrollContainer and focused reveal are the
				# safe-area acceptance boundary for Settings descendants.
				if app_state == STATE_SETTINGS and (control == settings_grid or settings_grid.is_ancestor_of(control)):
					continue
				var rect := control.get_global_rect()
				if not safe_rect.encloses(rect):
					violations.append(str(control.get_path()))
	if app_state == STATE_SETTINGS:
		var critical_controls := _settings_critical_nodes()
		var focus_owner := get_viewport().gui_get_focus_owner() as Control
		var scroll_rect := settings_scroll.get_global_rect()
		var focused_in_scroll := focus_owner != null and settings_scroll.is_ancestor_of(focus_owner)
		var focused_revealed := focus_owner != null and (not focused_in_scroll or scroll_rect.encloses(focus_owner.get_global_rect()))
		var inaccessible: Array[String] = []
		for control: Control in critical_controls:
			var requires_focus := control in _settings_controls()
			if not control.is_visible_in_tree() or (requires_focus and control.focus_mode == Control.FOCUS_NONE):
				inaccessible.append(str(control.get_path()))
		var focused_label := _setting_label_for(focus_owner) if focus_owner != null else null
		var focused_pair_revealed := focused_revealed and (focused_label == null or not focused_in_scroll or scroll_rect.encloses(focused_label.get_global_rect()))
		var action_row := $Root/Pages/SettingsPage/SafeArea/Layout/Actions as Control
		var action_path_visible := safe_rect.encloses(action_row.get_global_rect())
		var pair_geometries: Array[Dictionary] = []
		var setting_controls := _settings_controls()
		var setting_labels := _settings_labels()
		for index in 7:
			var pair_label := setting_labels[index]
			var pair_control := setting_controls[index]
			var label_rect := pair_label.get_global_rect()
			var control_rect := pair_control.get_global_rect()
			pair_geometries.append({
				"label": str(pair_label.get_path()),
				"control": str(pair_control.get_path()),
				"label_rect": label_rect,
				"control_rect": control_rect,
				"pair_rect": label_rect.merge(control_rect),
				"focused": pair_control == focus_owner,
				"fully_revealed": scroll_rect.encloses(label_rect) and scroll_rect.encloses(control_rect),
				"focus_reachable": pair_control.focus_mode != Control.FOCUS_NONE,
			})
		settings_reflow = {
			"mode": &"single_column" if settings_grid.columns == 1 else &"two_column",
			"columns": settings_grid.columns,
			"container_driven": true,
			"fixed_width_contract": false,
			"available_width": settings_scroll.size.x,
			"follow_focus": settings_scroll.follow_focus,
			"scroll_vertical": settings_scroll.scroll_vertical,
			"scroll_viewport_rect": scroll_rect,
			"content_minimum_size": settings_grid.get_combined_minimum_size(),
			"scroll_required": settings_grid.get_combined_minimum_size().y > settings_scroll.size.y,
			"critical_node_count": critical_controls.size(),
			"setting_label_count": _settings_labels().size(),
			"setting_control_count": 7,
			"inaccessible_controls": inaccessible,
			"focused_control": str(focus_owner.get_path()) if focus_owner != null else "",
			"focused_revealed": focused_pair_revealed,
			"focused_label": str(focused_label.get_path()) if focused_label != null else "",
			"label_control_pair_visible": focused_pair_revealed,
			"persistent_action_path_visible": action_path_visible,
			"title_rect": ($Root/Pages/SettingsPage/SafeArea/Layout/Title as Control).get_global_rect(),
			"action_row_rect": action_row.get_global_rect(),
			"pair_geometries": pair_geometries,
			"predecessor": _return_from_settings,
			"all_critical_reachable": inaccessible.is_empty(),
		}
		if not settings_scroll.follow_focus or not focused_pair_revealed or not action_path_visible or not inaccessible.is_empty():
			violations.append("settings_focus_reflow")
	return {
		"contract_id": LAYOUT_CONTRACT_ID,
		"applied_ui_scale": _applied_ui_scale,
		"viewport_size": viewport_size,
		"safe_margin": safe_margin,
		"safe_rect": safe_rect,
		"critical_control_count": 0 if app_state == STATE_GAMEPLAY else (pages.get_node(_page_name(app_state)) as Control).find_children("*", "Control", true, false).size(),
		"violation_count": violations.size(),
		"violations": violations,
		"within_safe_area": violations.is_empty(),
		"settings_reflow": settings_reflow,
		"blocking_shell_visible": root.visible and pages.visible,
		"route_plate_visible": $Root/Pages/LoadoutPage/RoutePlate.is_visible_in_tree(),
		"gameplay_surface_clear": app_state != STATE_GAMEPLAY or (not root.visible and not pages.visible),
	}


func _return_home() -> void:
	if not _commit_lifecycle_action(&"home"):
		return
	get_tree().paused = false
	roster.call(&"reset_transient_feedback")
	terminal.reset_presentation(true, true)
	if mission.call(&"reset_for_replay") != true:
		_last_lifecycle_action_receipt["accepted"] = false
		_last_lifecycle_action_receipt["failure_reason"] = &"replay_reset_rejected"
		_record_transition_rejection(&"home", &"replay_reset_rejected")
		return
	_observed_terminal_results.clear()
	_set_gameplay_enabled(false)
	_show_page(STATE_TITLE)


func _replay() -> void:
	if not _commit_lifecycle_action(&"replay"):
		return
	get_tree().paused = false
	roster.call(&"reset_transient_feedback")
	terminal.reset_presentation(true, true)
	if mission.call(&"reset_for_replay") != true:
		_last_lifecycle_action_receipt["accepted"] = false
		_last_lifecycle_action_receipt["failure_reason"] = &"replay_reset_rejected"
		_record_transition_rejection(&"replay", &"replay_reset_rejected")
		return
	_observed_terminal_results.clear()
	_set_gameplay_enabled(false)
	_show_page(STATE_LOADOUT)


func _on_mission_event_committed(event: Dictionary) -> void:
	if StringName(event.get("kind", &"")) != &"terminal_submitted":
		return
	var payload: Dictionary = event.get("payload", {})
	var result := StringName(payload.get("result", &"bomb_detonated"))
	_set_gameplay_enabled(false)
	_show_page(STATE_VICTORY if result == &"bomb_defused" else STATE_DETONATION, &"terminal_submitted", &"terminal")


func _on_terminal_presentation_completed(event_id: String, result: StringName) -> void:
	if _observed_terminal_results.has(event_id):
		return
	if (result == &"bomb_defused" and app_state != STATE_VICTORY) or (result == &"bomb_detonated" and app_state != STATE_DETONATION):
		_record_transition_rejection(&"terminal_completion", &"terminal_predecessor_mismatch")
		return
	_observed_terminal_results[event_id] = result
	var receipt := {
		"run_epoch": int(mission.get("run_epoch")),
		"terminal_event_id": event_id,
		"result": result,
		"presentation_completion_usec": Time.get_ticks_usec(),
		"presentation_completion_frame": Engine.get_process_frames(),
		"predecessor_state": app_state,
		"terminal_commit_count": int(mission.get("terminal_commit_count")),
		"duplicate_submit_count": int(mission.get("terminal_duplicate_submit_count")),
		"result_payload": mission.call(&"result_snapshot"),
	}
	_show_result(result)
	receipt["result_state"] = app_state
	receipt["transition_receipt"] = _last_transition_receipt.duplicate(true)
	receipt["actions"] = [&"replay", &"home"]
	_terminal_result_receipts.append(receipt)
	while _terminal_result_receipts.size() > TERMINAL_RESULT_RECEIPT_LIMIT:
		_terminal_result_receipts.pop_front()


func _show_result(result: StringName) -> void:
	_set_gameplay_enabled(false)
	roster.call(&"reset_transient_feedback")
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
	$Root/Pages/ResultPage/Menu/RestartButton.visible = not success and remaining > 0 and (not (mission.get("deployment_snapshot") as Dictionary).is_empty() or int(mission.get("checkpoint_version")) > 0)
	_show_page(STATE_SUCCESS_RESULT if success else STATE_FAILURE_RESULT, &"terminal_presentation_completed", &"terminal")


func _mcp_state() -> Dictionary:
	return {
		"run_epoch": int(mission.get("run_epoch")),
		"app_state": app_state,
		"pages_visible": pages.visible,
		"shell_root_visible": root.visible,
		"route_plate_visible": $Root/Pages/LoadoutPage/RoutePlate.is_visible_in_tree(),
		"gameplay_surface_clear": app_state != STATE_GAMEPLAY or (not root.visible and not pages.visible),
		"selected_weapon": _selected_weapon,
		"focused_control": str(get_viewport().gui_get_focus_owner().get_path()) if get_viewport().gui_get_focus_owner() != null else "",
		"applied_ui_scale": _applied_ui_scale,
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled"),
		"last_input_family": _last_input_family,
		"last_settings_focus_receipt": _last_settings_focus_receipt,
		"layout": _layout_snapshot(),
		"transition_serial": _transition_serial,
		"last_transition_receipt": _last_transition_receipt,
		"transition_history": _transition_history,
		"lifecycle_table_state_count": LIFECYCLE_TABLE.size(),
		"lifecycle_action_count": LIFECYCLE_ACTIONS.size(),
		"last_lifecycle_action_receipt": _last_lifecycle_action_receipt,
		"lifecycle_action_history": _lifecycle_action_history,
		"last_transition_rejection": _last_transition_rejection,
		"activation_serial": _activation_serial,
		"last_activation_receipt": _last_activation_receipt,
		"settings_focus_history": _settings_focus_history,
		"tester_setup_serial": _tester_setup_serial,
		"last_tester_setup_receipt": _last_tester_setup_receipt,
		"tester_setup_history": _tester_setup_history,
		"settings_component_binding": {
			"asset_id": SETTINGS_COMPONENT_ASSET_ID,
			"receipt_path": SETTINGS_COMPONENT_RECEIPT,
			"main_menu_source": SETTINGS_COMPONENT_MAIN_MENU,
			"main_menu_script": SETTINGS_COMPONENT_MAIN_SCRIPT,
			"inherited_base_scene": SETTINGS_COMPONENT_BASE_SCENE,
			"architecture": &"maaack_main_menu_inherited_packed_scene",
			"main_menu_bound": is_instance_valid(_curated_menu_instance),
			"packed_scene_instantiated": is_instance_valid(_curated_menu_instance),
			"runtime_path": str(_curated_menu_instance.get_path()) if is_instance_valid(_curated_menu_instance) else "",
			"instance_scene_file_path": _curated_menu_instance.scene_file_path if is_instance_valid(_curated_menu_instance) else "",
			"source_row_minimum_height": _settings_component_row_height,
			"adapted_surface": &"product_shell_main_settings",
			"lifecycle_active": is_instance_valid(_curated_menu_instance) and _curated_menu_instance.process_mode != Node.PROCESS_MODE_DISABLED,
			"visible_surface_active": is_instance_valid(_curated_menu_instance) and _curated_menu_instance.is_visible_in_tree(),
			"visible_start_control": "Root/MaaacksMainMenuRuntime/MenuContainer/MenuButtonsMargin/MenuButtonsContainer/MenuButtonsBoxContainer/NewGameButton",
			"visible_settings_control": "Root/MaaacksMainMenuRuntime/MenuContainer/MenuButtonsMargin/MenuButtonsContainer/MenuButtonsBoxContainer/OptionsButton",
			"visible_exit_control": "Root/MaaacksMainMenuRuntime/MenuContainer/MenuButtonsMargin/MenuButtonsContainer/MenuButtonsBoxContainer/ExitButton",
			"game_started_count": _curated_menu_start_count,
			"last_lifecycle_receipt": _last_curated_menu_lifecycle_receipt,
		},
		"briefing_elapsed": _briefing_elapsed,
		"briefing_caption_index": _briefing_caption_index,
		"briefing_caption_line_count": ($Root/Pages/BriefingPage/Copy as Label).text.count("\n") + 1,
		"briefing_complete": _briefing_complete,
		"briefing_skip_count": _briefing_skip_count,
		"opening_media_status": _opening_media_status,
		"opening_stream_bound": briefing_video.stream != null,
		"opening_video_playing": briefing_video.is_playing(),
		"opening_completion_source": _opening_completion_source,
		"opening_completion_count": _opening_completion_count,
		"opening_video_path": "res://assets/cinematics/fusepoint_opening.ogv",
		"opening_receipt_path": "res://art/source/cinematics/opening_fusepoint_daylight_i2v/generation_receipt.json",
		"deployment_requested": _deployment_requested,
		"death_lock_remaining": _death_lock_remaining,
		"active_recovery_epoch": _active_recovery_epoch,
		"recovery_source": (mission.get("last_checkpoint_restore_receipt") as Dictionary).get("recovery_source", &"none"),
		"applied_subtitle_size": _applied_subtitle_size,
		"reduced_camera_motion": _reduced_camera_motion,
		"screen_shake": _screen_shake,
		"mission_state": mission.get("mission_state"),
		"terminal_event_id": String(mission.get("terminal_event_id")),
		"result_entry_count": _observed_terminal_results.size(),
		"observed_terminal_results": _observed_terminal_results.duplicate(true),
		"terminal_result_receipts": _terminal_result_receipts.duplicate(true),
		"terminal_result_receipt_count": _terminal_result_receipts.size(),
		"terminal_presentation": terminal.snapshot(),
	}
