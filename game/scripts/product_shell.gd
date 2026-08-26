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
const BRIEFING_TYPE_CHARACTERS_PER_SECOND := 42.0
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
const OPENING_VIDEO_PATH := "res://assets/cinematics/fusepoint_opening.ogv"
const OPENING_VIDEO_AUDIO_RECEIPT := "res://assets/cinematics/fusepoint_opening_video_only_receipt.json"
const OPENING_VIDEO_SHA256 := "e85d2381b9aa4ccb795d2fa1b614a8f97af7d16ec776be153ab1687042e2620f"
const RESULT_SEMIBOLD_FONT: FontFile = preload("res://ui/shell/fps_menu_skin/fonts/BarlowCondensed-SemiBold.ttf")
const RESULT_ICON_PATHS := {
	&"time": "res://ui/hud/combat/result_icons/time.svg",
	&"score": "res://ui/hud/combat/result_icons/score.svg",
	&"rank": "res://ui/hud/combat/result_icons/rank.svg",
	&"kills": "res://ui/hud/combat/result_icons/kills.svg",
	&"deaths": "res://ui/hud/combat/result_icons/deaths.svg",
	&"restart": "res://ui/hud/combat/result_icons/restart.svg",
	&"objective": "res://ui/hud/combat/result_icons/objective.svg",
	&"bomb": "res://ui/hud/combat/result_icons/bomb.svg",
	&"weapon": "res://ui/hud/combat/result_icons/weapon.svg",
	&"home": "res://ui/hud/combat/result_icons/home.svg",
}
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
	&"victory": {"predecessors":[&"gameplay",&"death_recovery",&"recovery_transition"], "authority":&"terminal", "blocking":true, "focus":""},
		&"detonation": {"predecessors":[&"gameplay",&"death_recovery",&"recovery_transition"], "authority":&"terminal", "blocking":true, "focus":""},
	&"success_result": {"predecessors":[&"victory"], "authority":&"terminal", "blocking":true, "focus":"Root/Pages/ResultPage/Menu/ReplayButton"},
	&"failure_result": {"predecessors":[&"detonation"], "authority":&"terminal", "blocking":true, "focus":"Root/Pages/ResultPage/Menu/ReplayButton"},
}
const LIFECYCLE_ACTIONS := {
	&"replay": {"legal_from":[&"success_result",&"failure_result"], "target":&"briefing"},
	&"checkpoint_restart": {"legal_from":[&"gameplay",&"pause",&"death_recovery",&"failure_result"], "target":&"recovery_transition"},
	&"home": {"legal_from":[&"pause",&"death_recovery",&"success_result",&"failure_result"], "target":&"title"},
}
const TESTER_CONTROL_ACTIONS: Array[StringName] = [
	&"tester_alpha_checkpoint",
	&"tester_encounter_alpha_prepare",
	&"tester_encounter_bravo_prepare",
	&"tester_encounter_charlie_prepare",
	&"tester_encounter_all_prepare",
	&"tester_enemy_search_state_prepare",
	&"tester_encounter_commit",
	&"tester_encounter_advance",
	&"tester_terminal_success_prepare",
	&"tester_terminal_success_advance",
	&"tester_terminal_failure_prepare",
	&"tester_terminal_failure_advance",
	&"tester_defusal_stage_prepare",
	&"tester_defusal_stage_advance",
	&"tester_ui_scale_200_prepare",
	&"tester_ui_scale_restore",
	&"tester_opening_fallback_prepare",
	&"tester_shell_death",
	&"tester_shell_failure_result",
	&"tester_shell_success_result",
	&"tester_shell_replay",
	&"tester_feedback_component_report_prepare",
	&"tester_feedback_adapter_report_prepare",
	&"tester_feedback_enemy_report_prepare",
	&"tester_feedback_miss_prepare",
	&"tester_feedback_concrete_prepare",
	&"tester_feedback_metal_prepare",
	&"tester_feedback_character_prepare",
	&"tester_feedback_capacity_prepare",
	&"tester_feedback_advance",
	&"tester_feedback_reset",
]

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
var _briefing_manual_advance_count := 0
var _briefing_cue_elapsed := 0.0
var _briefing_visible_characters := 0
var _briefing_cue_revealed := false
var _briefing_input_serial := 0
var _last_briefing_input_receipt: Dictionary = {}
var _briefing_input_history: Array[Dictionary] = []
var _activation_serial := 0
var _activation_frame := -1
var _last_activation_receipt: Dictionary = {}
var _deployment_input_serial := 0
var _last_deployment_input_receipt: Dictionary = {}
var _settings_focus_history: Array[Dictionary] = []
var _last_settings_focus_receipt: Dictionary = {}
var _curated_menu_instance: Control
var _settings_component_row_height := SETTINGS_COMPONENT_ROW_HEIGHT
var _curated_menu_start_count := 0
var _last_curated_menu_lifecycle_receipt: Dictionary = {}
var _result_icon_cache: Dictionary = {}
var _result_icon_status: Dictionary = {}
var _tester_setup_serial := 0
var _last_tester_setup_receipt: Dictionary = {}
var _tester_setup_history: Array[Dictionary] = []
var _death_recovery_cycle_serial := 0
var _death_recovery_cycle_history: Array[Dictionary] = []
var _queued_recovery_activation := false
var _recovery_queue_serial := 0
var _queued_recovery_activation_receipt: Dictionary = {}
var _tester_opening_fallback_active := false
var _tester_opening_fallback_generation := 0
var _tester_opening_original_stream: VideoStream
var _last_tester_opening_reset_receipt: Dictionary = {}
var _tester_action_dispatch_frames: Dictionary = {}
var _responsive_layout_active := false


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
	briefing_video.loop = false
	_build_result_page_clusters()
	_configure_result_action_buttons()
	_assert_curated_menu_binding()
	_set_gameplay_enabled(false)
	_load_settings_controls()
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
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/Fullscreen,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotion,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ScreenShake,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/HoldADS,
	]:
		toggle.toggled.connect(func(_pressed: bool) -> void: _sync_settings_value_copy())
	_configure_shell_navigation()
	_configure_settings_navigation()
	_configure_settings_layout_contract()


func _configure_shell_navigation() -> void:
	for group: Array in [
		[
			$Root/Pages/LoadoutPage/Content/Weapons/AKButton,
			$Root/Pages/LoadoutPage/Content/Weapons/SaigaButton,
			$Root/Pages/LoadoutPage/Content/Actions/ConfirmButton,
			$Root/Pages/LoadoutPage/Content/Actions/BackButton,
		],
		[
			$Root/Pages/BriefingPage/Actions/DeployButton,
			$Root/Pages/BriefingPage/Actions/PauseButton,
			$Root/Pages/BriefingPage/Actions/BackButton,
		],
		[
			$Root/Pages/PausePage/Menu/ResumeButton,
			$Root/Pages/PausePage/Menu/SettingsButton,
			$Root/Pages/PausePage/Menu/RestartButton,
			$Root/Pages/PausePage/Menu/HomeButton,
		],
		[
			$Root/Pages/DeathPage/Menu/RestartButton,
			$Root/Pages/DeathPage/Menu/HomeButton,
		],
		[
			$Root/Pages/ResultPage/Menu/ReplayButton,
			$Root/Pages/ResultPage/Menu/RestartButton,
			$Root/Pages/ResultPage/Menu/HomeButton,
		],
	]:
		_configure_linear_button_group(group)


func _configure_linear_button_group(group: Array) -> void:
	var controls: Array[Control] = []
	for control: Control in group:
		if control == null:
			continue
		control.focus_mode = Control.FOCUS_ALL
		controls.append(control)
	for index in controls.size():
		var control := controls[index]
		var previous := controls[(index - 1 + controls.size()) % controls.size()]
		var next := controls[(index + 1) % controls.size()]
		control.focus_neighbor_left = control.get_path_to(previous)
		control.focus_neighbor_top = control.get_path_to(previous)
		control.focus_neighbor_right = control.get_path_to(next)
		control.focus_neighbor_bottom = control.get_path_to(next)


func _settings_controls() -> Array[Control]:
	return [
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/Fullscreen,
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
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/DisplayLabel,
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
	return _settings_labels()[index] if index >= 0 and index < _settings_labels().size() else control


func _settings_critical_nodes() -> Array[Control]:
	var nodes: Array[Control] = [$Root/Pages/SettingsPage/SafeArea/Layout/Title]
	nodes.append_array(_settings_labels())
	nodes.append_array(_settings_controls())
	return nodes


func _configure_settings_navigation() -> void:
	var controls := _settings_controls()
	var setting_count := _settings_labels().size()
	for control: Control in controls:
		control.focus_mode = Control.FOCUS_ALL
		if not control.focus_entered.is_connected(_on_settings_focus_entered.bind(control)):
			control.focus_entered.connect(_on_settings_focus_entered.bind(control))
	var first := controls[0]
	var last_setting := controls[setting_count - 1]
	var apply_button := controls[setting_count]
	var cancel_button := controls[setting_count + 1]
	for index in setting_count:
		var control := controls[index]
		var above: Control = apply_button if index == 0 else controls[index - 1]
		var below: Control = apply_button if index == setting_count - 1 else controls[index + 1]
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
	for control: Control in _settings_controls().slice(0, _settings_labels().size()):
		control.custom_minimum_size.y = maxf(48.0 if control is BaseButton else 38.0, component_row_height)
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := $Root/Pages/SettingsPage/SafeArea/Layout/Title as Label
	title.custom_minimum_size.y = 70.0
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var actions := $Root/Pages/SettingsPage/SafeArea/Layout/Actions as HBoxContainer
	actions.custom_minimum_size.y = 64.0
	actions.size_flags_vertical = Control.SIZE_SHRINK_END
	settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL


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
	# Focus often arrives in the same frame as the 100/200% reflow. Wait for the
	# container's minimum-size propagation before asking ScrollContainer to reveal
	# the focused row and its associated label.
	await get_tree().process_frame
	await get_tree().process_frame
	if app_state != STATE_SETTINGS or not is_instance_valid(control):
		return
	var label := _setting_label_for(control)
	if settings_scroll.is_ancestor_of(label):
		settings_scroll.ensure_control_visible(label)
	settings_scroll.ensure_control_visible(control)
	await get_tree().process_frame
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
	var title_rect: Rect2 = ($Root/Pages/SettingsPage/SafeArea/Layout/Title as Control).get_global_rect()
	var safe_rect := Rect2(root.size * SAFE_AREA_RATIO, root.size - (root.size * SAFE_AREA_RATIO * 2.0))
	_last_settings_focus_receipt = {
		"run_epoch": int(mission.get("run_epoch")),
		"page": STATE_SETTINGS,
		"input_family": _last_input_family,
		"focused_control": control.get_path(),
		"focus_visible_in_scroll": pair_visible,
		"associated_label": label.get_path(),
		"associated_label_rect": label_rect,
		"label_control_pair_visible": pair_visible,
		"fixed_title_visible": safe_rect.encloses(title_rect),
		"persistent_action_path_visible": safe_rect.encloses(actions_rect),
		"header_footer_outside_scroll": not settings_scroll.is_ancestor_of($Root/Pages/SettingsPage/SafeArea/Layout/Title) and not settings_scroll.is_ancestor_of($Root/Pages/SettingsPage/SafeArea/Layout/Actions),
		"scroll_vertical": settings_scroll.scroll_vertical,
		"scroll_viewport_rect": scroll_rect,
		"control_rect": control_rect,
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled") == true,
		"ui_scale": _applied_ui_scale,
		"accepted": pair_visible and safe_rect.encloses(title_rect) and safe_rect.encloses(actions_rect),
	}
	_settings_focus_history.append(_last_settings_focus_receipt.duplicate(true))
	while _settings_focus_history.size() > TRANSITION_HISTORY_LIMIT:
		_settings_focus_history.pop_front()


func _input(event: InputEvent) -> void:
	_observe_input_family(event)
	if _dispatch_tester_action_event(event):
		get_viewport().set_input_as_handled()
		return
	if app_state == STATE_BRIEFING and _is_physical_briefing_skip(event):
		_physical_skip_briefing_and_deploy()
		get_viewport().set_input_as_handled()
		return
	if app_state == STATE_BRIEFING and _is_briefing_primary_input(event):
		_briefing_primary_action()
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


func _is_briefing_primary_input(event: InputEvent) -> bool:
	if event.is_action_pressed(&"menu_accept"):
		return true
	if event is InputEventKey:
		return event.pressed and not event.echo and (
			event.physical_keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]
			or event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]
		)
	return _is_briefing_cue_advance(event)


func _tester_audio_stem_for_event(event: InputEvent) -> StringName:
	var actions := {
		&"tester_feedback_component_report_prepare": &"component_report",
		&"tester_feedback_adapter_report_prepare": &"product_adapter_report",
		&"tester_feedback_enemy_report_prepare": &"enemy_report",
		&"tester_feedback_miss_prepare": &"near_miss",
		&"tester_feedback_concrete_prepare": &"concrete_impact",
		&"tester_feedback_metal_prepare": &"metal_impact",
		&"tester_feedback_character_prepare": &"character_hit",
		&"tester_feedback_capacity_prepare": &"capacity_cleanup",
		&"tester_feedback_reset": &"reset",
	}
	for action: StringName in actions:
		if event.is_action_pressed(action):
			return StringName(actions[action])
	return &""


func _dispatch_tester_action_event(event: InputEvent) -> bool:
	for action: StringName in TESTER_CONTROL_ACTIONS:
		if event.is_action_pressed(action):
			return _dispatch_tester_action(action)
	return false


func _poll_tester_action_injection() -> void:
	if not OS.is_debug_build():
		return
	for action: StringName in TESTER_CONTROL_ACTIONS:
		if Input.is_action_just_pressed(action):
			_dispatch_tester_action(action)


func _dispatch_tester_action(action: StringName) -> bool:
	var frame := Engine.get_process_frames()
	if int(_tester_action_dispatch_frames.get(action, -1)) == frame:
		return true
	_tester_action_dispatch_frames[action] = frame
	match action:
		&"tester_alpha_checkpoint":
			_tester_prepare_alpha_checkpoint()
		&"tester_encounter_alpha_prepare":
			_tester_prepare_encounter(&"alpha")
		&"tester_encounter_bravo_prepare":
			_tester_prepare_encounter(&"bravo")
		&"tester_encounter_charlie_prepare":
			_tester_prepare_encounter(&"charlie")
		&"tester_encounter_all_prepare":
			_tester_prepare_encounter(&"all")
		&"tester_enemy_search_state_prepare":
			_tester_prepare_enemy_search_state()
		&"tester_encounter_commit":
			_tester_commit_prepared_encounter()
		&"tester_encounter_advance":
			_tester_advance_prepared_encounter()
		&"tester_terminal_success_prepare":
			_tester_prepare_terminal_branch(&"success")
		&"tester_terminal_success_advance":
			_tester_advance_terminal_branch(&"success")
		&"tester_terminal_failure_prepare":
			_tester_prepare_terminal_branch(&"failure")
		&"tester_terminal_failure_advance":
			_tester_advance_terminal_branch(&"failure")
		&"tester_defusal_stage_prepare":
			_tester_prepare_defusal_stage()
		&"tester_defusal_stage_advance":
			_tester_advance_defusal_stage()
		&"tester_ui_scale_200_prepare":
			_tester_apply_ui_scale(2.0, &"ui_scale_200_prepare")
		&"tester_ui_scale_restore":
			_tester_apply_ui_scale(1.0, &"ui_scale_restore")
		&"tester_opening_fallback_prepare":
			_tester_prepare_opening_fallback()
		&"tester_shell_death":
			_tester_prepare_shell_death()
		&"tester_shell_failure_result":
			_tester_prepare_failure_result()
		&"tester_shell_success_result":
			_tester_prepare_success_result()
		&"tester_shell_replay":
			_tester_prepare_replay()
		&"tester_feedback_advance":
			_tester_advance_audio_stem()
		&"tester_feedback_reset":
			_tester_prepare_audio_stem(&"reset")
		_:
			var stem := _tester_audio_stem_for_action(action)
			if stem.is_empty():
				return false
			_tester_prepare_audio_stem(stem)
	return true


func _tester_audio_stem_for_action(action: StringName) -> StringName:
	return {
		&"tester_feedback_component_report_prepare": &"component_report",
		&"tester_feedback_adapter_report_prepare": &"product_adapter_report",
		&"tester_feedback_enemy_report_prepare": &"enemy_report",
		&"tester_feedback_miss_prepare": &"near_miss",
		&"tester_feedback_concrete_prepare": &"concrete_impact",
		&"tester_feedback_metal_prepare": &"metal_impact",
		&"tester_feedback_character_prepare": &"character_hit",
		&"tester_feedback_capacity_prepare": &"capacity_cleanup",
	}.get(action, &"")


func _tester_prepare_audio_stem(stem_id: StringName) -> void:
	var receipt := _new_tester_setup_receipt(StringName("feedback_%s_prepare" % String(stem_id)))
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var prepared: Dictionary = weapon.call(&"tester_prepare_audio_stem", stem_id)
	receipt["feedback_setup"] = prepared
	receipt["resolved"] = prepared.get("resolved", false)
	receipt["accepted"] = prepared.get("accepted", false)
	receipt["branch_id"] = prepared.get("branch_id", StringName("audio_stem:%s" % String(stem_id)))
	receipt["setup_generation"] = prepared.get("setup_generation", 0)
	receipt["release_guard"] = prepared.get("release_guard", &"OS.is_debug_build")
	receipt["reset_isolation"] = prepared.get("reset_isolation", {})
	receipt["failure_reason"] = prepared.get("failure_reason", &"")
	_store_tester_setup_receipt(receipt)


func _tester_advance_audio_stem() -> void:
	var receipt := _new_tester_setup_receipt(&"feedback_advance")
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var prepared: Dictionary = weapon.get("_last_tester_audio_receipt")
	var stem_id := StringName(prepared.get("stem_id", &""))
	var expected_generation := int(prepared.get("setup_generation", -1))
	var advanced: Dictionary = weapon.call(&"tester_advance_audio_stem", stem_id, expected_generation)
	receipt["feedback_advance"] = advanced
	receipt["resolved"] = advanced.get("resolved", false)
	receipt["accepted"] = advanced.get("accepted", false)
	receipt["branch_id"] = advanced.get("branch_id", &"")
	receipt["setup_generation"] = advanced.get("setup_generation", expected_generation)
	receipt["release_guard"] = advanced.get("release_guard", &"OS.is_debug_build")
	receipt["reset_isolation"] = advanced.get("reset_isolation", {})
	receipt["failure_reason"] = advanced.get("failure_reason", &"")
	_store_tester_setup_receipt(receipt)


func _is_briefing_cue_advance(event: InputEvent) -> bool:
	if event is InputEventKey:
		return event.pressed and not event.echo and (
			event.physical_keycode in [KEY_ENTER, KEY_KP_ENTER]
			or event.keycode in [KEY_ENTER, KEY_KP_ENTER]
		)
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
			return false
		# Buttons retain their ordinary click semantics; clicking the cinematic or
		# caption field advances exactly one cue.
		return not ($Root/Pages/BriefingPage/Actions as Control).get_global_rect().has_point(mouse_event.position)
	return false


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


func _tester_prepare_encounter(region_id: StringName) -> void:
	var receipt := _new_tester_setup_receipt(StringName("%s_encounter_prepare" % region_id))
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var mission_setup: Dictionary = mission.call(&"tester_prepare_encounter", region_id)
	receipt["mission_setup"] = mission_setup
	receipt["resolved"] = mission_setup.get("resolved", false) == true
	receipt["accepted"] = mission_setup.get("accepted", false) == true
	receipt["prepared_region"] = mission_setup.get("prepared_region", &"")
	receipt["branch_id"] = mission_setup.get("branch_id", &"")
	receipt["setup_generation"] = mission_setup.get("setup_generation", 0)
	receipt["stable_actor_ids"] = mission_setup.get("stable_actor_ids", [])
	receipt["reset_isolation"] = mission_setup.get("reset_isolation", {})
	receipt["route_acceptance_claimed"] = false
	receipt["failure_reason"] = mission_setup.get("failure_reason", &"")
	_store_tester_setup_receipt(receipt)


func _tester_prepare_enemy_search_state() -> void:
	var receipt := _new_tester_setup_receipt(&"enemy_search_state_prepare")
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var mission_setup: Dictionary = mission.call(&"tester_prepare_enemy_search_state")
	receipt["mission_setup"] = mission_setup
	receipt["resolved"] = mission_setup.get("resolved", false) == true
	receipt["accepted"] = mission_setup.get("accepted", false) == true
	receipt["branch_id"] = mission_setup.get("branch_id", &"animation:search_root")
	receipt["setup_generation"] = mission_setup.get("setup_generation", 0)
	receipt["stable_actor_ids"] = mission_setup.get("stable_actor_ids", [])
	receipt["search_actor_id"] = mission_setup.get("search_actor_id", &"")
	receipt["root_state"] = mission_setup.get("root_state", {})
	receipt["reset_isolation"] = mission_setup.get("reset_isolation", {})
	receipt["route_acceptance_claimed"] = false
	receipt["failure_reason"] = mission_setup.get("failure_reason", &"")
	_store_tester_setup_receipt(receipt)


func _tester_commit_prepared_encounter() -> void:
	var receipt := _new_tester_setup_receipt(&"encounter_commit")
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var prepared: Dictionary = mission.get("last_tester_encounter_receipt")
	var mission_commit: Dictionary = mission.call(
		&"tester_commit_prepared_encounter",
		StringName(prepared.get("prepared_region", &"")),
		int(prepared.get("setup_generation", -1)),
	)
	receipt["mission_commit"] = mission_commit
	receipt["resolved"] = mission_commit.get("resolved", false) == true
	receipt["accepted"] = mission_commit.get("accepted", false) == true
	receipt["reset_isolation"] = {
		"timer_not_increased": mission_commit.get("timer_not_increased", false),
		"route_acceptance_claimed": false,
	}
	receipt["failure_reason"] = mission_commit.get("failure_reason", &"")
	_store_tester_setup_receipt(receipt)


func _tester_advance_prepared_encounter() -> void:
	var receipt := _new_tester_setup_receipt(&"encounter_advance")
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var prepared: Dictionary = mission.get("last_tester_encounter_receipt")
	var mission_advance: Dictionary = mission.call(
		&"tester_advance_prepared_encounter",
		StringName(prepared.get("prepared_region", &"")),
		int(prepared.get("setup_generation", -1)),
	)
	receipt["mission_advance"] = mission_advance
	receipt["branch_id"] = mission_advance.get("branch_id", &"")
	receipt["setup_generation"] = mission_advance.get("setup_generation", 0)
	receipt["resolved"] = mission_advance.get("resolved", false) == true
	receipt["accepted"] = mission_advance.get("accepted", false) == true
	receipt["active_stable_ids"] = mission_advance.get("active_stable_ids", [])
	receipt["region_count"] = mission_advance.get("region_count", 0)
	receipt["reset_isolation"] = mission_advance.get("reset_isolation", {})
	receipt["route_acceptance_claimed"] = false
	receipt["failure_reason"] = mission_advance.get("failure_reason", &"")
	_store_tester_setup_receipt(receipt)


func _tester_prepare_terminal_branch(branch_id: StringName) -> void:
	var receipt := _new_tester_setup_receipt(StringName("terminal_%s_prepare" % String(branch_id)))
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var mission_setup: Dictionary = mission.call(&"tester_prepare_terminal_branch", branch_id)
	receipt["mission_setup"] = mission_setup
	receipt["branch_id"] = mission_setup.get("branch_id", StringName("terminal:%s" % String(branch_id)))
	receipt["setup_generation"] = mission_setup.get("setup_generation", 0)
	receipt["resolved"] = mission_setup.get("resolved", false) == true
	receipt["accepted"] = mission_setup.get("accepted", false) == true and app_state == STATE_GAMEPLAY
	receipt["prepared_branch"] = mission_setup.get("prepared_branch", &"")
	receipt["reset_isolation"] = mission_setup.get("reset_isolation", {})
	receipt["route_acceptance_claimed"] = false
	receipt["failure_reason"] = mission_setup.get("failure_reason", &"")
	_store_tester_setup_receipt(receipt)


func _tester_advance_terminal_branch(branch_id: StringName) -> void:
	var receipt := _new_tester_setup_receipt(StringName("terminal_%s_advance" % String(branch_id)))
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var prepared: Dictionary = mission.get("last_tester_terminal_receipt")
	var expected_generation := int(prepared.get("setup_generation", -1))
	var mission_advance: Dictionary = mission.call(&"tester_advance_terminal_branch", branch_id, expected_generation)
	var expected_shell_state := STATE_VICTORY if branch_id == &"success" else STATE_DETONATION
	receipt["mission_advance"] = mission_advance
	receipt["branch_id"] = mission_advance.get("branch_id", StringName("terminal:%s" % String(branch_id)))
	receipt["setup_generation"] = mission_advance.get("setup_generation", expected_generation)
	receipt["resolved"] = mission_advance.get("resolved", false) == true
	receipt["accepted"] = mission_advance.get("accepted", false) == true and app_state == expected_shell_state
	receipt["result_state"] = app_state
	receipt["terminal_event_id"] = mission_advance.get("terminal_event_id", "")
	receipt["reset_isolation"] = mission_advance.get("reset_isolation", {})
	receipt["route_acceptance_claimed"] = false
	receipt["failure_reason"] = mission_advance.get("failure_reason", &"") if receipt["accepted"] else &"terminal_presentation_handoff_rejected"
	_store_tester_setup_receipt(receipt)


func _tester_prepare_defusal_stage() -> void:
	var receipt := _new_tester_setup_receipt(&"defusal_stage_prepare")
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var mission_setup: Dictionary = mission.call(&"tester_prepare_defusal_stage")
	receipt["mission_setup"] = mission_setup
	receipt["branch_id"] = mission_setup.get("branch_id", &"defusal")
	receipt["setup_generation"] = mission_setup.get("setup_generation", 0)
	receipt["resolved"] = mission_setup.get("resolved", false) == true
	receipt["accepted"] = mission_setup.get("accepted", false) == true
	receipt["stage_id"] = mission_setup.get("stage_id", &"")
	receipt["stage_index"] = mission_setup.get("stage_index", -1)
	receipt["reset_isolation"] = mission_setup.get("reset_isolation", {})
	receipt["route_acceptance_claimed"] = false
	receipt["failure_reason"] = mission_setup.get("failure_reason", &"")
	_store_tester_setup_receipt(receipt)


func _tester_advance_defusal_stage() -> void:
	var receipt := _new_tester_setup_receipt(&"defusal_stage_advance")
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	var prepared: Dictionary = mission.get("last_tester_defusal_receipt")
	var mission_advance: Dictionary = mission.call(&"tester_advance_defusal_stage", int(prepared.get("setup_generation", -1)))
	receipt["mission_advance"] = mission_advance
	receipt["branch_id"] = mission_advance.get("branch_id", &"defusal")
	receipt["setup_generation"] = mission_advance.get("setup_generation", 0)
	receipt["resolved"] = mission_advance.get("resolved", false) == true
	receipt["accepted"] = mission_advance.get("accepted", false) == true
	receipt["stage_id"] = mission_advance.get("stage_id", &"")
	receipt["completed_stage_count"] = mission_advance.get("completed_stage_count", 0)
	receipt["reset_isolation"] = mission_advance.get("reset_isolation", {})
	receipt["route_acceptance_claimed"] = false
	receipt["failure_reason"] = mission_advance.get("failure_reason", &"")
	_store_tester_setup_receipt(receipt)


func _tester_apply_ui_scale(scale: float, kind: StringName) -> void:
	var receipt := _new_tester_setup_receipt(kind)
	if not _tester_setup_available_for_shell([STATE_TITLE, STATE_LOADOUT, STATE_BRIEFING, STATE_GAMEPLAY, STATE_PAUSE, STATE_SETTINGS, STATE_DEATH, STATE_SUCCESS_RESULT, STATE_FAILURE_RESULT], receipt):
		_store_tester_setup_receipt(receipt)
		return
	var values := settings_store.snapshot()
	var persisted_scale := float(values.get("ui_scale", 1.0))
	var weapon_state: Dictionary = weapon.call(&"_mcp_state")
	values["ui_scale"] = clampf(scale, 1.0, 2.0)
	apply_accessibility_settings(values)
	var persist_restore := kind == &"ui_scale_restore" and is_equal_approx(float(values["ui_scale"]), 1.0)
	if persist_restore:
		settings_store.save_settings(values)
	receipt.merge({
		"resolved": true,
		"accepted": is_equal_approx(_applied_ui_scale, float(values["ui_scale"])),
		"requested_scale": float(values["ui_scale"]),
		"applied_scale": _applied_ui_scale,
		"persisted_scale_before": persisted_scale,
		"persisted_scale_after": float(settings_store.snapshot().get("ui_scale", 1.0)),
		"persisted_scale_unchanged": not persist_restore and is_equal_approx(float(settings_store.snapshot().get("ui_scale", 1.0)), persisted_scale),
		"persisted_restored_to_one": persist_restore and is_equal_approx(float(settings_store.snapshot().get("ui_scale", 1.0)), 1.0),
		"reset_isolation": {
			"authoritative_state_unchanged": app_state == StringName(receipt.get("source_state", &"")),
			"mission_state_unchanged": true,
			"weapon_identity_unchanged": StringName(weapon_state.get("equipped_id", &"")),
			"transient_only": not persist_restore,
			"restore_persisted": persist_restore,
		},
		"failure_reason": &"" if is_equal_approx(_applied_ui_scale, float(values["ui_scale"])) else &"responsive_scale_not_applied",
	}, true)
	_store_tester_setup_receipt(receipt)


func _tester_prepare_opening_fallback() -> void:
	var receipt := _new_tester_setup_receipt(&"opening_missing_stream_fallback")
	receipt["branch_id"] = &"opening_missing_stream_fallback"
	receipt["setup_generation"] = _tester_opening_fallback_generation + 1
	receipt["stream_bound_before"] = briefing_video.stream != null
	receipt["source_state"] = app_state
	receipt["mission_state_before"] = mission.get("mission_state")
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		_store_tester_setup_receipt(receipt)
		return
	if app_state in [STATE_GAMEPLAY, STATE_PAUSE, STATE_DEATH, STATE_RECOVERING, STATE_VICTORY, STATE_DETONATION, STATE_SUCCESS_RESULT, STATE_FAILURE_RESULT]:
		receipt["failure_reason"] = &"blocking_predeployment_state_required"
		_store_tester_setup_receipt(receipt)
		return
	if _tester_opening_fallback_active:
		_restore_tester_opening_stream(&"superseded_prepare")
	_tester_opening_fallback_generation += 1
	_tester_opening_original_stream = briefing_video.stream
	_tester_opening_fallback_active = true
	briefing_video.stop()
	briefing_video.stream = null
	briefing_video.visible = false
	var values := settings_store.snapshot()
	values["ui_scale"] = 1.0
	apply_accessibility_settings(values)
	var routed := true
	match app_state:
		STATE_TITLE:
			routed = _show_page(STATE_LOADOUT, &"tester_opening_fallback_route")
			routed = routed and _show_page(STATE_LOADING, &"tester_opening_fallback_route")
			routed = routed and _show_page(STATE_BRIEFING, &"tester_opening_fallback_route")
		STATE_LOADOUT:
			routed = _show_page(STATE_LOADING, &"tester_opening_fallback_route")
			routed = routed and _show_page(STATE_BRIEFING, &"tester_opening_fallback_route")
		STATE_LOADING:
			_loading_remaining = 0.0
			routed = _show_page(STATE_BRIEFING, &"tester_opening_fallback_route")
		STATE_BRIEFING:
			_start_briefing()
		_:
			routed = false
	receipt.merge({
		"resolved": routed and app_state == STATE_BRIEFING,
		"accepted": routed and app_state == STATE_BRIEFING and _opening_media_status == &"matched_still_fallback" and is_equal_approx(_applied_ui_scale, 1.0),
		"setup_generation": _tester_opening_fallback_generation,
		"fallback_status": _opening_media_status,
		"opening_stream_bound_after": briefing_video.stream != null,
		"copy_visible": not ($Root/Pages/BriefingPage/Copy as Label).text.is_empty(),
		"pause_disabled": ($Root/Pages/BriefingPage/Actions/PauseButton as Button).disabled,
		"ui_scale_after": _applied_ui_scale,
		"reset_isolation": {
			"mission_state_unchanged": mission.get("mission_state") == receipt["mission_state_before"],
			"stream_restorable": _tester_opening_original_stream != null,
			"release_exports_unbound": true,
			"ui_scale_restored_to_one": is_equal_approx(_applied_ui_scale, 1.0),
		},
		"failure_reason": &"" if routed and app_state == STATE_BRIEFING and _opening_media_status == &"matched_still_fallback" else &"fallback_route_failed",
	}, true)
	_store_tester_setup_receipt(receipt)


func _restore_tester_opening_stream(reason: StringName) -> Dictionary:
	if not _tester_opening_fallback_active:
		return _last_tester_opening_reset_receipt.duplicate(true)
	briefing_video.stream = _tester_opening_original_stream
	briefing_video.loop = false
	_tester_opening_fallback_active = false
	_last_tester_opening_reset_receipt = {
		"reset_id": "tester-opening-reset-%06d" % _tester_opening_fallback_generation,
		"reason": reason,
		"resolved": true,
		"accepted": briefing_video.stream == _tester_opening_original_stream and is_equal_approx(_applied_ui_scale, 1.0),
		"stream_restored": briefing_video.stream == _tester_opening_original_stream,
		"stream_bound_after": briefing_video.stream != null,
		"ui_scale_after": _applied_ui_scale,
		"release_exports_unbound": true,
	}
	if StringName(_last_tester_setup_receipt.get("kind", &"")) == &"opening_missing_stream_fallback":
		_last_tester_setup_receipt["reset_receipt"] = _last_tester_opening_reset_receipt.duplicate(true)
		if not _tester_setup_history.is_empty():
			_tester_setup_history[-1] = _last_tester_setup_receipt.duplicate(true)
	return _last_tester_opening_reset_receipt.duplicate(true)


func _tester_prepare_shell_death() -> void:
	var receipt := _new_tester_setup_receipt(&"ordinary_death")
	if not _tester_setup_available(STATE_GAMEPLAY, receipt):
		_store_tester_setup_receipt(receipt)
		return
	_death_recovery_cycle_serial += 1
	var run_epoch_before := int(mission.get("run_epoch"))
	var checkpoint_before := int(mission.get("checkpoint_version"))
	var timer_before := float(mission.get("remaining_time"))
	var damage_event_id := "%s:ordinary-death-cycle-%02d" % [receipt["setup_id"], _death_recovery_cycle_serial]
	var applied: bool = player.call(&"apply_authoritative_damage", float(player.get("max_health")) + 1.0, damage_event_id, {
		"damage_class": &"tester_authoritative_damage",
		"source_path": get_path(),
		"source_position": player.global_position,
	})
	receipt["resolved"] = true
	receipt["accepted"] = applied and app_state == STATE_DEATH and player.get("health") <= 0.0
	receipt["death_recovery_cycle"] = _death_recovery_cycle_serial
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
	# Legacy action is retained as a preparation alias only. It no longer fabricates
	# countdown, presentation completion, and result entry in one input edge.
	_tester_prepare_terminal_branch(&"failure")


func _tester_prepare_success_result() -> void:
	_tester_prepare_terminal_branch(&"success")


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
	var focused := get_viewport().gui_get_focus_owner()
	receipt["resolved"] = true
	receipt["accepted"] = (
		app_state == STATE_BRIEFING
		and _briefing_complete
		and focused == $Root/Pages/BriefingPage/Actions/DeployButton
		and int(mission.get("run_epoch")) == run_epoch_before + 1
	)
	receipt["reset_isolation"] = {
		"new_run_epoch": int(mission.get("run_epoch")),
		"previous_run_epoch": run_epoch_before,
		"mission_predeployment": StringName(mission.get("mission_state")) == &"predeployment",
		"gameplay_input_disabled": player.get("gameplay_input_enabled") == false,
		"terminal_cache_cleared": _observed_terminal_results.is_empty(),
		"briefing_complete": _briefing_complete,
		"focused_deploy_button": focused == $Root/Pages/BriefingPage/Actions/DeployButton,
		"route_acceptance_claimed": false,
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
		"release_guard": &"OS.is_debug_build",
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


func _tester_setup_available_for_shell(allowed_states: Array[StringName], receipt: Dictionary) -> bool:
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return false
	if app_state not in allowed_states:
		receipt["failure_reason"] = &"shell_state_unavailable"
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
	if app_state == STATE_DEATH:
		button = $Root/Pages/DeathPage/Menu/RestartButton as Button
		button.disabled = _death_lock_remaining > 0.0
		button.text = "RECOVERY READY IN %.1f" % _death_lock_remaining if button.disabled else _recovery_button_text()
	if not button.is_visible_in_tree():
		return false
	var frame := Engine.get_process_frames()
	if frame == _activation_frame:
		return true
	_activation_frame = frame
	_activation_serial += 1
	if app_state == STATE_DEATH and _death_lock_remaining > 0.0:
		var recovery_button := $Root/Pages/DeathPage/Menu/RestartButton as Button
		_queue_recovery_activation(&"menu_accept_countdown", recovery_button.get_path(), frame)
		_last_activation_receipt = {
			"activation_id": "shell-activation-%06d" % _activation_serial,
			"frame": frame,
			"state": app_state,
			"input_family": _last_input_family,
			"focused_control": recovery_button.get_path(),
			"enabled": false,
			"emission_count": 0,
			"death_countdown_remaining": _death_lock_remaining,
			"queued": true,
			"queue_receipt": _queued_recovery_activation_receipt.duplicate(true),
			"accepted": true,
			"failure_reason": &"",
		}
		return true
	_last_activation_receipt = {
		"activation_id": "shell-activation-%06d" % _activation_serial,
		"frame": frame,
		"state": app_state,
		"input_family": _last_input_family,
		"focused_control": button.get_path(),
		"enabled": not button.disabled,
		"emission_count": 0 if button.disabled else 1,
		"death_countdown_remaining": _death_lock_remaining if app_state == STATE_DEATH else 0.0,
		"accepted": not button.disabled,
		"failure_reason": &"control_disabled_countdown_visible" if button.disabled and app_state == STATE_DEATH else &"control_disabled" if button.disabled else &"",
	}
	if button.disabled:
		return true
	if button.toggle_mode:
		button.button_pressed = not button.button_pressed
	button.pressed.emit()
	return true


func _process(delta: float) -> void:
	_poll_tester_action_injection()
	_reconcile_terminal_completion()
	if app_state == STATE_LOADING and _loading_remaining > 0.0:
		_loading_remaining = maxf(_loading_remaining - delta, 0.0)
		$Root/Pages/LoadingPage/Progress.value = (1.0 - _loading_remaining / 1.35) * 100.0
		if _loading_remaining <= 0.0:
			_show_page(STATE_BRIEFING)
	elif app_state == STATE_BRIEFING and not _briefing_complete:
		_update_briefing(delta)
	elif app_state == STATE_DEATH and _death_lock_remaining > 0.0:
		var countdown_delta := minf(maxf(delta, 0.0), 1.0 / 60.0)
		_death_lock_remaining = maxf(0.0, _death_lock_remaining - countdown_delta)
		var recovery_button := $Root/Pages/DeathPage/Menu/RestartButton as Button
		recovery_button.disabled = _death_lock_remaining > 0.0
		recovery_button.text = "RECOVERY QUEUED  %.1f" % _death_lock_remaining if _queued_recovery_activation and recovery_button.disabled else "RECOVERY READY IN %.1f" % _death_lock_remaining if recovery_button.disabled else _recovery_button_text()
		if not recovery_button.disabled and _queued_recovery_activation:
			_commit_queued_recovery_activation()
		elif not recovery_button.disabled:
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
		_restore_tester_opening_stream(StringName("left_briefing:%s" % String(state)))
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
	if app_state == STATE_FAILURE_RESULT:
		var legal_retry := $Root/Pages/ResultPage/Menu/RestartButton as Button
		if legal_retry.visible and not legal_retry.disabled:
			legal_retry.grab_focus()
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
	_briefing_caption_index = 0
	_briefing_cue_elapsed = 0.0
	_briefing_visible_characters = 0
	_briefing_cue_revealed = false
	_briefing_complete = false
	_deployment_requested = false
	_opening_completion_source = &""
	_opening_completion_count = 0
	_briefing_manual_advance_count = 0
	$Root/Pages/BriefingPage/Error.text = ""
	var deploy_button := $Root/Pages/BriefingPage/Actions/DeployButton as Button
	var pause_button := $Root/Pages/BriefingPage/Actions/PauseButton as Button
	deploy_button.text = "ADVANCE BRIEFING  ▶"
	deploy_button.disabled = false
	pause_button.text = "Ⅱ  PAUSE"
	pause_button.disabled = briefing_video.stream == null
	briefing_video.loop = false
	if briefing_video.stream != null:
		_opening_media_status = &"playing"
		briefing_video.visible = true
		briefing_video.paused = false
		briefing_video.play()
	else:
		_opening_media_status = &"matched_still_fallback"
		briefing_video.visible = false
	$Root/Pages/BriefingPage/Copy.text = ""
	_update_briefing(0.0)


func _update_briefing(delta: float) -> void:
	if briefing_video.stream != null and briefing_video.paused:
		return
	_briefing_elapsed += maxf(delta, 0.0)
	if _briefing_complete or _briefing_cue_revealed or _briefing_caption_index < 0:
		return
	_briefing_cue_elapsed += maxf(delta, 0.0)
	var cue := BRIEFING_CAPTIONS[_briefing_caption_index]
	_briefing_visible_characters = mini(cue.length(), int(floor(_briefing_cue_elapsed * BRIEFING_TYPE_CHARACTERS_PER_SECOND)))
	$Root/Pages/BriefingPage/Copy.text = cue.left(_briefing_visible_characters)
	if _briefing_visible_characters >= cue.length():
		_briefing_cue_revealed = true


func _briefing_primary_action() -> void:
	if app_state != STATE_BRIEFING:
		return
	if not _briefing_complete:
		_advance_briefing_cue()
		return
	_deploy()


func _advance_briefing_cue() -> void:
	if app_state != STATE_BRIEFING or _briefing_complete:
		return
	var cue_before := _briefing_caption_index
	var revealed_before := _briefing_cue_revealed
	var action := &"advance_cue"
	_briefing_manual_advance_count += 1
	if not _briefing_cue_revealed:
		var cue := BRIEFING_CAPTIONS[_briefing_caption_index]
		_briefing_visible_characters = cue.length()
		_briefing_cue_revealed = true
		$Root/Pages/BriefingPage/Copy.text = cue
		action = &"complete_partial_reveal"
		_record_briefing_input(cue_before, revealed_before, action)
		return
	var next_index := _briefing_caption_index + 1
	if next_index >= BRIEFING_CAPTIONS.size():
		_complete_briefing(false, &"manual_cue_complete")
		_record_briefing_input(cue_before, revealed_before, &"complete_briefing")
		return
	_briefing_caption_index = next_index
	_briefing_cue_elapsed = 0.0
	_briefing_visible_characters = 0
	_briefing_cue_revealed = false
	$Root/Pages/BriefingPage/Copy.text = ""
	_record_briefing_input(cue_before, revealed_before, action)


func _record_briefing_input(cue_before: int, revealed_before: bool, action: StringName) -> void:
	_briefing_input_serial += 1
	_last_briefing_input_receipt = {
		"input_id": "briefing-input-%06d" % _briefing_input_serial,
		"source": _last_input_family,
		"handled": true,
		"action": action,
		"cue_before": cue_before,
		"cue_after": _briefing_caption_index,
		"revealed_before": revealed_before,
		"revealed_after": _briefing_cue_revealed,
		"manual_advance_count": _briefing_manual_advance_count,
		"committed_frame": Engine.get_process_frames(),
	}
	_briefing_input_history.append(_last_briefing_input_receipt.duplicate(true))
	while _briefing_input_history.size() > 12:
		_briefing_input_history.pop_front()


func _physical_skip_briefing_and_deploy() -> void:
	if app_state != STATE_BRIEFING:
		return
	var cue_before := _briefing_caption_index
	var revealed_before := _briefing_cue_revealed
	if not _briefing_complete:
		_complete_briefing(true, &"physical_g_skip_one_step_deploy")
	_record_briefing_input(cue_before, revealed_before, &"physical_g_skip_and_deploy")
	_deploy()
	_last_briefing_input_receipt.merge({
		"deploy_requested_same_activation": true,
		"deployment_input_receipt": _last_deployment_input_receipt.duplicate(true),
		"result_state": app_state,
		"mission_state_after": mission.get("mission_state"),
		"gameplay_input_after": player.get("gameplay_input_enabled"),
		"mouse_mode_after": Input.mouse_mode,
		"accepted": (
			app_state == STATE_GAMEPLAY
			and StringName(mission.get("mission_state")) == &"active_gameplay"
			and _last_deployment_input_receipt.get("accepted", false) == true
		),
	}, true)
	if not _briefing_input_history.is_empty():
		_briefing_input_history[-1] = _last_briefing_input_receipt.duplicate(true)


func _toggle_opening_pause() -> void:
	if app_state != STATE_BRIEFING or _briefing_complete or briefing_video.stream == null:
		return
	briefing_video.paused = not briefing_video.paused
	_opening_media_status = &"paused" if briefing_video.paused else &"playing"
	($Root/Pages/BriefingPage/Actions/PauseButton as Button).text = "▶  RESUME" if briefing_video.paused else "Ⅱ  PAUSE"


func _complete_briefing(skipped: bool, completion_source := &"") -> void:
	if _briefing_complete:
		return
	_briefing_complete = true
	_opening_completion_count += 1
	_opening_completion_source = completion_source if not completion_source.is_empty() else &"skip" if skipped else &"video_finished" if _opening_media_status == &"finished" else &"timed_caption_complete"
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


func _deploy() -> void:
	if app_state != STATE_BRIEFING or not _briefing_complete or _deployment_requested:
		return
	_deployment_requested = true
	_deployment_input_serial += 1
	var deployment_receipt := {
		"deployment_input_id": "deployment-input-%06d" % _deployment_input_serial,
		"requested": true,
		"resolved": false,
		"accepted": false,
		"source": _last_input_family,
		"source_state": app_state,
		"briefing_complete": _briefing_complete,
		"briefing_completion_source": _opening_completion_source,
		"activation_receipt": _last_activation_receipt.duplicate(true),
		"mission_state_before": mission.get("mission_state"),
		"hud_enabled_before": hud.get("_hud_enabled"),
		"gameplay_input_before": player.get("gameplay_input_enabled"),
		"mouse_mode_before": Input.mouse_mode,
		"committed_frame": Engine.get_process_frames(),
	}
	_restore_tester_opening_stream(&"deployment_authorized")
	if not weapon.call(&"equip_loadout", _selected_weapon):
		_deployment_requested = false
		deployment_receipt["failure_reason"] = &"loadout_unavailable"
		_last_deployment_input_receipt = deployment_receipt
		$Root/Pages/BriefingPage/Error.text = "LOADOUT UNAVAILABLE — RETURN AND SELECT A VALID WEAPON"
		return
	if not mission.call(&"begin_deployment"):
		_deployment_requested = false
		deployment_receipt["failure_reason"] = &"mission_begin_deployment_rejected"
		deployment_receipt["mission_state_after"] = mission.get("mission_state")
		_last_deployment_input_receipt = deployment_receipt
		$Root/Pages/BriefingPage/Error.text = "DEPLOYMENT ALREADY COMMITTED"
		return
	get_tree().paused = false
	if not _show_page(STATE_DEPLOYMENT, &"deployment_committed", &"mission"):
		_deployment_requested = false
		deployment_receipt["failure_reason"] = &"deployment_page_handoff_rejected"
		deployment_receipt["mission_state_after"] = mission.get("mission_state")
		_last_deployment_input_receipt = deployment_receipt
		return
	_set_gameplay_enabled(true)
	_show_page(STATE_GAMEPLAY, &"deployment_handoff", &"mission")
	deployment_receipt.merge({
		"resolved": true,
		"accepted": (
			app_state == STATE_GAMEPLAY
			and StringName(mission.get("mission_state")) == &"active_gameplay"
			and hud.get("_hud_enabled") == true
			and player.get("gameplay_input_enabled") == true
			and weapon.get("gameplay_input_enabled") == true
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			and not root.visible
			and not pages.visible
		),
		"result_state": app_state,
		"mission_state_after": mission.get("mission_state"),
		"hud_enabled_after": hud.get("_hud_enabled"),
		"gameplay_input_after": player.get("gameplay_input_enabled"),
		"weapon_input_after": weapon.get("gameplay_input_enabled"),
		"mouse_mode_after": Input.mouse_mode,
		"shell_hidden": not root.visible and not pages.visible,
		"mission_deployment_commit_count": mission.get("deployment_commit_count"),
		"run_epoch": int(mission.get("run_epoch")),
		"failure_reason": &"",
	}, true)
	if not deployment_receipt["accepted"]:
		deployment_receipt["failure_reason"] = &"deployment_handoff_incomplete"
	_last_deployment_input_receipt = deployment_receipt


func _set_gameplay_enabled(enabled: bool) -> void:
	player.call(&"set_gameplay_input_enabled", enabled)
	weapon.call(&"set_gameplay_input_enabled", enabled)
	roster.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
	hud.call(&"set_hud_enabled", enabled)
	if player.has_method(&"force_mouse_capture_reconcile"):
		player.call(
			&"force_mouse_capture_reconcile",
			&"product_shell_gameplay_handoff" if enabled else &"product_shell_page_handoff"
		)


func _reset_hud_lifecycle_feedback(reason: StringName) -> Dictionary:
	if hud != null and hud.has_method(&"reset_presentation_lifecycle"):
		var receipt: Variant = hud.call(&"reset_presentation_lifecycle", reason, int(mission.get("run_epoch")))
		return receipt if receipt is Dictionary else {}
	return {}


func _pause_gameplay() -> void:
	if app_state != STATE_GAMEPLAY:
		return
	$Root/Pages/PausePage/Menu/RestartButton.visible = not (mission.get("deployment_snapshot") as Dictionary).is_empty() or int(mission.get("checkpoint_version")) > 0
	player.call(&"set_gameplay_input_enabled", false)
	weapon.call(&"set_gameplay_input_enabled", false)
	roster.call(&"reset_transient_feedback")
	_reset_hud_lifecycle_feedback(&"pause")
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
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/Fullscreen.button_pressed = bool(values.get("fullscreen_enabled", false))
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
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleLabel.text = "SUBTITLE SIZE  •  OUTLINE   %d PX" % int(round(subtitle.value))
	var fullscreen := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/Fullscreen as BaseButton
	var reduced := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotion as BaseButton
	var shake := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ScreenShake as BaseButton
	var ads := $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/HoldADS as BaseButton
	fullscreen.text = "EXCLUSIVE FULLSCREEN  •  NATIVE" if fullscreen.button_pressed else "WINDOWED  •  1280 × 720"
	reduced.text = "ENABLED" if reduced.button_pressed else "DISABLED"
	shake.text = "ENABLED" if shake.button_pressed else "DISABLED"
	ads.text = "HOLD" if ads.button_pressed else "TOGGLE"


func _apply_settings() -> void:
	settings_store.save_settings({
		"master_volume": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume.value / 100.0,
		"fullscreen_enabled": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/Fullscreen.button_pressed,
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
	var focused := get_viewport().gui_get_focus_owner()
	if app_state == STATE_SETTINGS and focused != null:
		_reveal_settings_pair.call_deferred(focused)
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
	if _responsive_layout_active:
		return
	_responsive_layout_active = true
	var viewport := _visible_viewport_size()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.position = Vector2.ZERO
	root.size = viewport
	pages.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pages.position = Vector2.ZERO
	pages.size = viewport
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		_responsive_layout_active = false
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
	settings_scroll.clip_contents = true
	var settings_title := $Root/Pages/SettingsPage/SafeArea/Layout/Title as Label
	var settings_actions := $Root/Pages/SettingsPage/SafeArea/Layout/Actions as HBoxContainer
	settings_title.custom_minimum_size.y = 78.0 if expanded else 70.0
	settings_actions.custom_minimum_size.y = 72.0 if expanded else 64.0
	settings_scroll.custom_minimum_size.y = maxf(220.0, safe.size.y - settings_title.custom_minimum_size.y - settings_actions.custom_minimum_size.y - 36.0)
	for control: Control in _settings_controls().slice(0, _settings_labels().size()):
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
	var result_origin := safe.position + Vector2(16.0, 10.0)
	var result_width := minf(safe.size.x - 32.0, 1440.0)
	var metric_height := 132.0 if expanded else 92.0
	var breakdown_height := 116.0 if expanded else maxf(88.0, safe.size.y - 512.0)
	_set_rect(^"Root/Pages/ResultPage/Outcome", Rect2(result_origin, Vector2(result_width, 64.0)))
	_set_rect(^"Root/Pages/ResultPage/Reason", Rect2(result_origin + Vector2(0.0, 66.0), Vector2(result_width, 30.0)))
	_set_rect(^"Root/Pages/ResultPage/Primary", Rect2(result_origin + Vector2(0.0, 116.0), Vector2(result_width, 106.0)))
	_set_rect(^"Root/Pages/ResultPage/MissionMetrics", Rect2(result_origin + Vector2(0.0, 238.0), Vector2(result_width, metric_height)))
	_set_rect(^"Root/Pages/ResultPage/BreakdownTitle", Rect2(result_origin + Vector2(0.0, 252.0 + metric_height), Vector2(result_width, 26.0)))
	_set_rect(^"Root/Pages/ResultPage/Breakdown", Rect2(result_origin + Vector2(0.0, 282.0 + metric_height), Vector2(result_width, breakdown_height)))
	_set_rect(^"Root/Pages/ResultPage/Menu", Rect2(Vector2(safe.position.x + 16.0, safe.end.y - 94.0), Vector2(820.0, 70.0)))
	_responsive_layout_active = false


func _visible_viewport_size() -> Vector2:
	var viewport_size := get_viewport().get_visible_rect().size
	var window_size := Vector2(get_window().size)
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		viewport_size = window_size
	return viewport_size


func _cancel_settings() -> void:
	_show_page(_return_from_settings)


func _on_player_died(_event: Dictionary) -> void:
	if (
		StringName(_event.get("damage_class", &"")) == &"bomb_terminal_explosion"
		or String(_event.get("event_id", "")) == String(mission.get("terminal_event_id"))
		or StringName(mission.get("mission_state")) == &"bomb_detonated"
		or int(mission.get("terminal_commit_count")) > 0
	):
		_clear_death_recovery_latches(&"terminal_damage_ignored_by_ordinary_recovery")
		return
	if app_state != STATE_GAMEPLAY or StringName(mission.get("mission_state")) != &"active_gameplay":
		return
	get_tree().paused = true
	player.call(&"enter_combat_death_lock")
	player.call(&"set_gameplay_input_enabled", false)
	weapon.call(&"set_gameplay_input_enabled", false)
	roster.call(&"reset_transient_feedback")
	_reset_hud_lifecycle_feedback(&"ordinary_death")
	_death_lock_remaining = DEATH_LOCK_SECONDS
	_queued_recovery_activation = false
	_queued_recovery_activation_receipt.clear()
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
		_queue_recovery_activation(&"restart_requested_countdown", ^"Root/Pages/DeathPage/Menu/RestartButton", Engine.get_process_frames())
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
	if not _queued_recovery_activation_receipt.is_empty():
		_queued_recovery_activation_receipt["recovery_command_id"] = _last_lifecycle_action_receipt.get("action_id", "")
		_queued_recovery_activation_receipt["committed_state"] = app_state
		_queued_recovery_activation_receipt["committed"] = true


func _recovery_button_text() -> String:
	return "RECOVER DEPLOYMENT" if int(mission.get("checkpoint_version")) == 0 else "RESTART CHECKPOINT"


func _queue_recovery_activation(source: StringName, focused_path: NodePath, frame: int) -> void:
	if _queued_recovery_activation:
		_queued_recovery_activation_receipt["duplicate_request_count"] = int(_queued_recovery_activation_receipt.get("duplicate_request_count", 0)) + 1
		_queued_recovery_activation_receipt["latest_request_frame"] = frame
		return
	_recovery_queue_serial += 1
	_queued_recovery_activation = true
	_queued_recovery_activation_receipt = {
		"queue_id": "run-%06d:recovery-queue-%06d" % [int(mission.get("run_epoch")), _recovery_queue_serial],
		"source": source,
		"requested": true,
		"resolved": false,
		"committed": false,
		"request_frame": frame,
		"focused_control": focused_path,
		"source_state": app_state,
		"death_lock_remaining_at_request": _death_lock_remaining,
		"mission_state": mission.get("mission_state"),
		"input_focus_preserved": get_viewport().gui_get_focus_owner() != null,
		"visible_countdown_active": _death_lock_remaining > 0.0,
	}


func _commit_queued_recovery_activation() -> void:
	if not _queued_recovery_activation:
		return
	_queued_recovery_activation = false
	_queued_recovery_activation_receipt["resolved"] = true
	_queued_recovery_activation_receipt["resolved_frame"] = Engine.get_process_frames()
	_queued_recovery_activation_receipt["death_lock_remaining_at_commit"] = _death_lock_remaining
	_restart_checkpoint()


func _clear_death_recovery_latches(reason: StringName) -> Dictionary:
	var receipt := {
		"reason": reason,
		"source_state": app_state,
		"death_lock_remaining_before": _death_lock_remaining,
		"queued_recovery_before": _queued_recovery_activation,
		"active_recovery_epoch_before": _active_recovery_epoch,
		"tree_paused_before": get_tree().paused,
	}
	_death_lock_remaining = 0.0
	_queued_recovery_activation = false
	_queued_recovery_activation_receipt.clear()
	_active_recovery_epoch = 0
	get_tree().paused = false
	if String(reason).begins_with("terminal_") or String(reason).begins_with("authoritative_terminal"):
		if player != null and "combat_death_locked" in player and player.get("terminal_locked") == true:
			player.set("combat_death_locked", false)
	var recovery_button := $Root/Pages/DeathPage/Menu/RestartButton as Button
	recovery_button.disabled = false
	recovery_button.text = _recovery_button_text()
	receipt["resolved"] = true
	receipt["tree_paused_after"] = get_tree().paused
	return receipt


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
	if StringName(_last_tester_setup_receipt.get("kind", &"")) == &"ordinary_death":
		_last_tester_setup_receipt["handoff_resolved"] = true
		_last_tester_setup_receipt["handoff_epoch"] = epoch
		_last_tester_setup_receipt["result_state"] = app_state
		_last_tester_setup_receipt["health_after_recovery"] = float(player.get("health"))
		_last_tester_setup_receipt["gameplay_input_restored"] = player.get("gameplay_input_enabled") == true
		_last_tester_setup_receipt["paused_after_recovery"] = get_tree().paused
		_last_tester_setup_receipt["accepted"] = app_state == STATE_GAMEPLAY and player.get("gameplay_input_enabled") == true and float(player.get("health")) > 0.0
		_death_recovery_cycle_history.append(_last_tester_setup_receipt.duplicate(true))
		while _death_recovery_cycle_history.size() > 6:
			_death_recovery_cycle_history.pop_front()
		if not _tester_setup_history.is_empty():
			_tester_setup_history[-1] = _last_tester_setup_receipt.duplicate(true)
	if StringName(_last_tester_setup_receipt.get("kind", &"")) == &"alpha_checkpoint_entry":
		_last_tester_setup_receipt["handoff_resolved"] = true
		_last_tester_setup_receipt["handoff_epoch"] = epoch
		_last_tester_setup_receipt["result_state"] = app_state
		_last_tester_setup_receipt["accepted"] = app_state == STATE_GAMEPLAY and player.get("gameplay_input_enabled") == true
		var points: Dictionary = mission.get("capture_points")
		var alpha: Dictionary = points.get(&"alpha", {})
		_last_tester_setup_receipt["radio_presentation"] = hud.call(&"tester_prepare_authoritative_radio_cue", {
			"point_id": &"alpha",
			"point_state": alpha.get("state", &""),
			"event_id": "tester-radio:%s" % String((_last_tester_setup_receipt.get("mission_setup", {}) as Dictionary).get("setup_id", "alpha-checkpoint")),
			"run_epoch": int(mission.get("run_epoch")),
			"checkpoint_version": int(mission.get("checkpoint_version")),
		})
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
	var viewport_size := _visible_viewport_size()
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
		for index in _settings_labels().size():
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
			"setting_control_count": _settings_labels().size(),
			"inaccessible_controls": inaccessible,
			"focused_control": str(focus_owner.get_path()) if focus_owner != null else "",
			"focused_revealed": focused_pair_revealed,
			"focused_label": str(focused_label.get_path()) if focused_label != null else "",
			"label_control_pair_visible": focused_pair_revealed,
			"persistent_action_path_visible": action_path_visible,
			"fixed_title_visible": safe_rect.encloses(($Root/Pages/SettingsPage/SafeArea/Layout/Title as Control).get_global_rect()),
			"header_footer_outside_scroll": not settings_scroll.is_ancestor_of($Root/Pages/SettingsPage/SafeArea/Layout/Title) and not settings_scroll.is_ancestor_of($Root/Pages/SettingsPage/SafeArea/Layout/Actions),
			"title_rect": ($Root/Pages/SettingsPage/SafeArea/Layout/Title as Control).get_global_rect(),
			"action_row_rect": action_row.get_global_rect(),
			"pair_geometries": pair_geometries,
			"predecessor": _return_from_settings,
			"all_critical_reachable": inaccessible.is_empty(),
		}
		if not settings_scroll.follow_focus or not focused_pair_revealed or not action_path_visible or not bool(settings_reflow.get("fixed_title_visible", false)) or not inaccessible.is_empty():
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
	_clear_death_recovery_latches(&"home")
	roster.call(&"reset_transient_feedback")
	_reset_hud_lifecycle_feedback(&"home")
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
	_clear_death_recovery_latches(&"replay")
	roster.call(&"reset_transient_feedback")
	_reset_hud_lifecycle_feedback(&"replay")
	terminal.reset_presentation(true, true)
	if mission.call(&"reset_for_replay") != true:
		_last_lifecycle_action_receipt["accepted"] = false
		_last_lifecycle_action_receipt["failure_reason"] = &"replay_reset_rejected"
		_record_transition_rejection(&"replay", &"replay_reset_rejected")
		return
	_observed_terminal_results.clear()
	_set_gameplay_enabled(false)
	if not _route_to_deploy_ready_briefing(&"replay", &"replay_deploy_ready"):
		_last_lifecycle_action_receipt["accepted"] = false
		_last_lifecycle_action_receipt["failure_reason"] = &"replay_briefing_route_rejected"
		_record_transition_rejection(&"replay", &"replay_briefing_route_rejected")


func _route_to_deploy_ready_briefing(reason: StringName, completion_source: StringName) -> bool:
	if app_state != STATE_LOADOUT:
		if not _show_page(STATE_LOADOUT, reason):
			return false
	_loading_remaining = 0.0
	if not _show_page(STATE_LOADING, reason):
		return false
	if not _show_page(STATE_BRIEFING, reason):
		return false
	_complete_briefing(false, completion_source)
	var deploy_button := $Root/Pages/BriefingPage/Actions/DeployButton as Button
	deploy_button.disabled = false
	deploy_button.grab_focus()
	_finalize_transition_focus()
	return app_state == STATE_BRIEFING and _briefing_complete and get_viewport().gui_get_focus_owner() == deploy_button


func _on_mission_event_committed(event: Dictionary) -> void:
	if StringName(event.get("kind", &"")) != &"terminal_submitted":
		return
	var payload: Dictionary = event.get("payload", {})
	var result := StringName(payload.get("result", &"bomb_detonated"))
	_set_gameplay_enabled(false)
	_prime_terminal_result_page(result)
	var latch_receipt := _clear_death_recovery_latches(
		&"authoritative_terminal_success" if result == &"bomb_defused" else &"authoritative_terminal_failure"
	)
	var routed := _show_page(STATE_VICTORY if result == &"bomb_defused" else STATE_DETONATION, &"terminal_submitted", &"terminal")
	if not routed and result == &"bomb_defused" and StringName(mission.get("mission_state")) == &"bomb_defused":
		_record_transition_rejection(&"terminal_success_authority", &"authoritative_success_route_failed")
	elif not routed and result == &"bomb_detonated" and StringName(mission.get("mission_state")) == &"bomb_detonated":
		_record_transition_rejection(&"terminal_failure_authority", &"authoritative_failure_route_failed")
	_last_transition_receipt["terminal_latch_clear"] = latch_receipt
	_last_transition_receipt["terminal_route_accepted"] = routed


func _reconcile_terminal_completion() -> void:
	if app_state not in [STATE_VICTORY, STATE_DETONATION]:
		return
	var terminal_state: Dictionary = terminal.snapshot()
	if terminal_state.get("active", true) == true or StringName(terminal_state.get("phase", &"")) != &"completed":
		return
	var event_id := String(terminal_state.get("current_event_id", ""))
	if event_id.is_empty() or _observed_terminal_results.has(event_id):
		return
	var expected_result := &"bomb_defused" if app_state == STATE_VICTORY else &"bomb_detonated"
	if StringName(mission.get("mission_state")) != expected_result:
		return
	_on_terminal_presentation_completed(event_id, expected_result)


func _on_terminal_presentation_completed(event_id: String, result: StringName) -> void:
	if _observed_terminal_results.has(event_id):
		return
	if result == &"bomb_defused" and app_state != STATE_VICTORY and StringName(mission.get("mission_state")) == &"bomb_defused":
		_clear_death_recovery_latches(&"terminal_completion_success_recover")
		_show_page(STATE_VICTORY, &"terminal_completion_success_recover", &"terminal")
	if result == &"bomb_detonated" and app_state != STATE_DETONATION and StringName(mission.get("mission_state")) == &"bomb_detonated":
		_clear_death_recovery_latches(&"terminal_completion_failure_recover")
		_show_page(STATE_DETONATION, &"terminal_completion_failure_recover", &"terminal")
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
	var result_actions: Array[StringName] = [&"replay"]
	if $Root/Pages/ResultPage/Menu/RestartButton.visible:
		result_actions.append(&"restart_checkpoint")
	result_actions.append(&"home")
	receipt["actions"] = result_actions
	_terminal_result_receipts.append(receipt)
	while _terminal_result_receipts.size() > TERMINAL_RESULT_RECEIPT_LIMIT:
		_terminal_result_receipts.pop_front()


func _build_result_page_clusters() -> void:
	_clear_result_container(^"Root/Pages/ResultPage/Primary")
	_clear_result_container(^"Root/Pages/ResultPage/MissionMetrics")
	_clear_result_container(^"Root/Pages/ResultPage/Breakdown")
	($Root/Pages/ResultPage/Primary as HBoxContainer).add_theme_constant_override("h_separation", 38)
	($Root/Pages/ResultPage/MissionMetrics as GridContainer).columns = 4
	($Root/Pages/ResultPage/MissionMetrics as GridContainer).add_theme_constant_override("h_separation", 24)
	($Root/Pages/ResultPage/MissionMetrics as GridContainer).add_theme_constant_override("v_separation", 10)
	($Root/Pages/ResultPage/Breakdown as GridContainer).columns = 5
	($Root/Pages/ResultPage/Breakdown as GridContainer).add_theme_constant_override("h_separation", 20)
	($Root/Pages/ResultPage/Breakdown as GridContainer).add_theme_constant_override("v_separation", 8)
	var metric_color := Color(0.97, 0.98, 0.94, 1.0)
	var cool_color := Color(0.2, 0.92, 0.82, 1.0)
	var warn_color := Color(0.9, 0.75, 0.38, 1.0)
	var hot_color := Color(1.0, 0.27, 0.18, 1.0)
	_add_result_cluster(^"Root/Pages/ResultPage/Primary", "TimeGroup", &"time", "ELAPSED", "00:00", metric_color, 240.0, 46, 13, 38.0)
	_add_result_cluster(^"Root/Pages/ResultPage/Primary", "ScoreGroup", &"score", "SCORE", "0", warn_color, 240.0, 46, 13, 38.0)
	_add_result_cluster(^"Root/Pages/ResultPage/Primary", "RankGroup", &"rank", "RECENT RUN", "--", cool_color, 210.0, 46, 13, 38.0)
	_add_result_cluster(^"Root/Pages/ResultPage/MissionMetrics", "Remaining", &"time", "TIME", "00:00", warn_color, 244.0, 26, 13, 28.0)
	_add_result_cluster(^"Root/Pages/ResultPage/MissionMetrics", "Eliminations", &"kills", "KILLS", "0", metric_color, 184.0, 26, 13, 28.0)
	_add_result_cluster(^"Root/Pages/ResultPage/MissionMetrics", "Deaths", &"deaths", "DEATHS", "0", hot_color, 172.0, 26, 13, 28.0)
	_add_result_cluster(^"Root/Pages/ResultPage/MissionMetrics", "Restarts", &"restart", "RESTARTS", "0", metric_color, 184.0, 26, 13, 28.0)
	_add_result_cluster(^"Root/Pages/ResultPage/MissionMetrics", "Alpha", &"objective", "ALPHA", "A HOSTILE", cool_color, 210.0, 24, 13, 28.0)
	_add_result_cluster(^"Root/Pages/ResultPage/MissionMetrics", "Bravo", &"objective", "BRAVO", "B HOSTILE", cool_color, 210.0, 24, 13, 28.0)
	_add_result_cluster(^"Root/Pages/ResultPage/MissionMetrics", "Charlie", &"bomb", "CHARLIE", "C 0/3", warn_color, 190.0, 24, 13, 28.0)
	_add_result_cluster(^"Root/Pages/ResultPage/MissionMetrics", "Loadout", &"weapon", "LOADOUT", "AK74M", metric_color, 200.0, 24, 13, 30.0)
	for entry: Dictionary in [
		{"name": "Time", "caption": "TIME", "icon": &"time"},
		{"name": "Alpha", "caption": "A KEY", "icon": &"objective"},
		{"name": "Bravo", "caption": "B KEY", "icon": &"objective"},
		{"name": "Eliminations", "caption": "KILL", "icon": &"kills"},
		{"name": "Diagnosis", "caption": "DIAG", "icon": &"bomb"},
		{"name": "Isolation", "caption": "ISO", "icon": &"bomb"},
		{"name": "Detonator", "caption": "DET", "icon": &"bomb"},
		{"name": "Deaths", "caption": "DEATH", "icon": &"deaths"},
		{"name": "Restarts", "caption": "RESET", "icon": &"restart"},
		{"name": "Record", "caption": "BEST", "icon": &"rank"},
	]:
		_add_result_cluster(^"Root/Pages/ResultPage/Breakdown", String(entry["name"]), StringName(entry["icon"]), String(entry["caption"]), "0", metric_color, 154.0, 19, 11, 22.0)


func _clear_result_container(path: NodePath) -> void:
	var parent := get_node_or_null(path)
	if parent == null:
		return
	for child: Node in parent.get_children():
		parent.remove_child(child)
		child.free()


func _add_result_cluster(path: NodePath, group_name: String, icon_kind: StringName, caption: String, value: String, color: Color, min_width: float, value_size: int, caption_size: int, icon_size: float) -> void:
	var parent := get_node_or_null(path)
	if parent == null:
		return
	var group := HBoxContainer.new()
	group.name = group_name
	group.custom_minimum_size = Vector2(min_width, 0.0)
	group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	group.add_theme_constant_override("separation", 8)
	group.set_meta("result_metric_id", group_name)
	group.set_meta("icon_kind", String(icon_kind))
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.custom_minimum_size = Vector2(icon_size, icon_size)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture = _result_icon(icon_kind)
	icon.modulate = color
	group.add_child(icon)
	var stack := VBoxContainer.new()
	stack.name = "Stack"
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_theme_constant_override("separation", -1)
	var value_label := Label.new()
	value_label.name = "Value"
	value_label.text = value
	value_label.clip_text = false
	value_label.add_theme_font_override("font", RESULT_SEMIBOLD_FONT)
	value_label.add_theme_font_size_override("font_size", value_size)
	value_label.add_theme_color_override("font_color", color)
	value_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.82))
	value_label.add_theme_constant_override("outline_size", 3)
	var caption_label := Label.new()
	caption_label.name = "Caption"
	caption_label.text = caption
	caption_label.clip_text = false
	caption_label.add_theme_font_size_override("font_size", caption_size)
	caption_label.add_theme_color_override("font_color", Color(0.62, 0.7, 0.71, 1.0))
	stack.add_child(value_label)
	stack.add_child(caption_label)
	group.add_child(stack)
	parent.add_child(group)


func _result_icon(kind: StringName) -> Texture2D:
	_ensure_result_icon_cache()
	return _result_icon_cache.get(kind) as Texture2D


func _ensure_result_icon_cache() -> void:
	if not _result_icon_cache.is_empty():
		return
	for kind: StringName in RESULT_ICON_PATHS.keys():
		var texture := _make_result_icon_texture(kind)
		_result_icon_cache[kind] = texture
		_result_icon_status[kind] = {
			"kind": kind,
			"source": &"native_runtime_texture",
			"candidate_source_path": RESULT_ICON_PATHS[kind],
			"loadable": texture != null,
			"resource_loader_used": false,
		}


func _make_result_icon_texture(kind: StringName) -> Texture2D:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 1.0, 1.0, 0.0))
	var ink := Color(1.0, 1.0, 1.0, 1.0)
	match kind:
		&"time":
			_draw_icon_circle(image, Vector2i(32, 32), 23, ink, 4)
			_draw_icon_line(image, Vector2i(32, 32), Vector2i(32, 17), ink, 4)
			_draw_icon_line(image, Vector2i(32, 32), Vector2i(44, 39), ink, 4)
		&"score":
			_draw_icon_line(image, Vector2i(18, 50), Vector2i(46, 50), ink, 4)
			_draw_icon_line(image, Vector2i(22, 50), Vector2i(17, 20), ink, 4)
			_draw_icon_line(image, Vector2i(42, 50), Vector2i(47, 20), ink, 4)
			_draw_icon_line(image, Vector2i(18, 21), Vector2i(46, 21), ink, 4)
			_draw_icon_line(image, Vector2i(25, 27), Vector2i(32, 35), ink, 4)
			_draw_icon_line(image, Vector2i(32, 35), Vector2i(41, 27), ink, 4)
		&"rank":
			_draw_icon_line(image, Vector2i(20, 52), Vector2i(20, 18), ink, 4)
			_draw_icon_line(image, Vector2i(44, 52), Vector2i(44, 18), ink, 4)
			_draw_icon_line(image, Vector2i(16, 52), Vector2i(48, 52), ink, 4)
			_draw_icon_line(image, Vector2i(20, 18), Vector2i(32, 10), ink, 4)
			_draw_icon_line(image, Vector2i(44, 18), Vector2i(32, 10), ink, 4)
			_draw_icon_line(image, Vector2i(28, 28), Vector2i(36, 28), ink, 4)
		&"kills":
			_draw_icon_circle(image, Vector2i(32, 32), 22, ink, 3)
			_draw_icon_line(image, Vector2i(14, 32), Vector2i(50, 32), ink, 4)
			_draw_icon_line(image, Vector2i(32, 14), Vector2i(32, 50), ink, 4)
			_draw_icon_circle(image, Vector2i(32, 32), 5, ink, 3)
		&"deaths":
			_draw_icon_line(image, Vector2i(20, 18), Vector2i(44, 46), ink, 5)
			_draw_icon_line(image, Vector2i(44, 18), Vector2i(20, 46), ink, 5)
			_draw_icon_circle(image, Vector2i(32, 32), 21, ink, 3)
		&"restart":
			_draw_icon_arc(image, Vector2i(32, 33), 20, -220.0, 75.0, ink, 4)
			_draw_icon_line(image, Vector2i(31, 9), Vector2i(30, 22), ink, 4)
			_draw_icon_line(image, Vector2i(31, 9), Vector2i(43, 16), ink, 4)
		&"objective":
			_draw_icon_polyline(image, [Vector2i(32, 8), Vector2i(56, 32), Vector2i(32, 56), Vector2i(8, 32), Vector2i(32, 8)], ink, 4)
			_draw_icon_circle(image, Vector2i(32, 32), 8, ink, 4)
		&"bomb":
			_draw_icon_circle(image, Vector2i(31, 36), 17, ink, 4)
			_draw_icon_line(image, Vector2i(41, 22), Vector2i(50, 13), ink, 4)
			_draw_icon_line(image, Vector2i(48, 13), Vector2i(56, 9), ink, 3)
			_draw_icon_line(image, Vector2i(50, 13), Vector2i(56, 17), ink, 3)
		&"weapon":
			_draw_icon_polyline(image, [Vector2i(7, 34), Vector2i(42, 34), Vector2i(50, 27), Vector2i(59, 27), Vector2i(59, 35), Vector2i(53, 35), Vector2i(48, 42), Vector2i(35, 42), Vector2i(30, 50), Vector2i(22, 50), Vector2i(26, 42), Vector2i(7, 42), Vector2i(7, 34)], ink, 4)
			_draw_icon_line(image, Vector2i(39, 42), Vector2i(43, 54), ink, 4)
		&"home":
			_draw_icon_polyline(image, [Vector2i(12, 30), Vector2i(32, 13), Vector2i(52, 30)], ink, 4)
			_draw_icon_line(image, Vector2i(18, 29), Vector2i(18, 52), ink, 4)
			_draw_icon_line(image, Vector2i(46, 29), Vector2i(46, 52), ink, 4)
			_draw_icon_line(image, Vector2i(18, 52), Vector2i(46, 52), ink, 4)
			_draw_icon_line(image, Vector2i(29, 52), Vector2i(29, 39), ink, 4)
			_draw_icon_line(image, Vector2i(35, 52), Vector2i(35, 39), ink, 4)
		_:
			_draw_icon_circle(image, Vector2i(32, 32), 20, ink, 4)
	var texture := ImageTexture.create_from_image(image)
	return texture


func _draw_icon_polyline(image: Image, points: Array[Vector2i], color: Color, thickness := 3) -> void:
	for index in range(maxi(points.size() - 1, 0)):
		_draw_icon_line(image, points[index], points[index + 1], color, thickness)


func _draw_icon_arc(image: Image, center: Vector2i, radius: int, start_degrees: float, end_degrees: float, color: Color, thickness := 3) -> void:
	var last := Vector2i(
		center.x + int(round(cos(deg_to_rad(start_degrees)) * radius)),
		center.y + int(round(sin(deg_to_rad(start_degrees)) * radius))
	)
	for step in range(1, 38):
		var t := float(step) / 37.0
		var degrees := lerpf(start_degrees, end_degrees, t)
		var next := Vector2i(
			center.x + int(round(cos(deg_to_rad(degrees)) * radius)),
			center.y + int(round(sin(deg_to_rad(degrees)) * radius))
		)
		_draw_icon_line(image, last, next, color, thickness)
		last = next


func _draw_icon_circle(image: Image, center: Vector2i, radius: int, color: Color, thickness := 3) -> void:
	var last := Vector2i(center.x + radius, center.y)
	for step in range(1, 65):
		var angle := TAU * float(step) / 64.0
		var next := Vector2i(center.x + int(round(cos(angle) * radius)), center.y + int(round(sin(angle) * radius)))
		_draw_icon_line(image, last, next, color, thickness)
		last = next


func _draw_icon_line(image: Image, start: Vector2i, finish: Vector2i, color: Color, thickness := 3) -> void:
	var delta := finish - start
	var steps := maxi(abs(delta.x), abs(delta.y))
	if steps <= 0:
		_stamp_icon_pixel(image, start.x, start.y, color, thickness)
		return
	for step in range(steps + 1):
		var t := float(step) / float(steps)
		var x := int(round(lerpf(float(start.x), float(finish.x), t)))
		var y := int(round(lerpf(float(start.y), float(finish.y), t)))
		_stamp_icon_pixel(image, x, y, color, thickness)


func _stamp_icon_pixel(image: Image, x: int, y: int, color: Color, thickness := 3) -> void:
	var radius := maxi(1, int(ceil(float(thickness) * 0.5)))
	for offset_y in range(-radius, radius + 1):
		for offset_x in range(-radius, radius + 1):
			if Vector2(offset_x, offset_y).length() > float(radius):
				continue
			var px := x + offset_x
			var py := y + offset_y
			if px >= 0 and py >= 0 and px < image.get_width() and py < image.get_height():
				image.set_pixel(px, py, color)


func _configure_result_action_buttons() -> void:
	var buttons := {
		^"Root/Pages/ResultPage/Menu/ReplayButton": &"restart",
		^"Root/Pages/ResultPage/Menu/RestartButton": &"restart",
		^"Root/Pages/ResultPage/Menu/HomeButton": &"home",
	}
	for path: NodePath in buttons.keys():
		var button := get_node_or_null(path) as Button
		if button == null:
			continue
		button.icon = _result_icon(buttons[path])
		button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.expand_icon = false


func _result_value(path: NodePath) -> Label:
	var node := get_node_or_null(path)
	if node is Label:
		return node as Label
	if node != null:
		return node.find_child("Value", true, false) as Label
	return null


func _set_result_value(path: NodePath, text: String, color := Color(-1.0, -1.0, -1.0, -1.0)) -> void:
	var label := _result_value(path)
	if label == null:
		return
	label.text = text
	if color.a >= 0.0:
		label.add_theme_color_override("font_color", color)


func _set_result_caption(path: NodePath, text: String) -> void:
	var node := get_node_or_null(path)
	var label := node.find_child("Caption", true, false) as Label if node != null else null
	if label != null:
		label.text = text


func _result_time(seconds: int) -> String:
	return "%02d:%02d" % [maxi(seconds, 0) / 60, maxi(seconds, 0) % 60]


func _result_cluster_snapshot(path: NodePath) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var parent := get_node_or_null(path)
	if parent == null:
		return output
	for child: Node in parent.get_children():
		var group := child as Control
		if group == null:
			continue
		var value := group.get_node_or_null("Value") as Label
		if value == null:
			value = group.find_child("Value", true, false) as Label
		var caption := group.get_node_or_null("Caption") as Label
		if caption == null:
			caption = group.find_child("Caption", true, false) as Label
		output.append({
			"path": str(group.get_path()),
			"type": group.get_class(),
			"result_metric_id": String(group.get_meta("result_metric_id", "")),
			"icon_kind": String(group.get_meta("icon_kind", "")),
			"value": value.text if value != null else "",
			"caption": caption.text if caption != null else "",
			"rect": group.get_global_rect(),
		})
	return output


func _show_result(result: StringName) -> void:
	_set_gameplay_enabled(false)
	roster.call(&"reset_transient_feedback")
	_reset_hud_lifecycle_feedback(StringName("terminal_%s" % String(result)))
	var success := result == &"bomb_defused"
	$Root/Pages/ResultPage/Outcome.text = "MISSION COMPLETE" if success else "MISSION FAILED"
	$Root/Pages/ResultPage/Outcome.modulate = Color(0.2, 0.92, 0.82) if success else Color(1.0, 0.27, 0.18)
	var snapshot: Dictionary = mission.call(&"result_snapshot")
	var components: Dictionary = snapshot.get("score_components", {})
	var remaining := int(snapshot.get("remaining_seconds", 0))
	var completion := int(snapshot.get("completion_seconds", 0))
	var rank := int(snapshot.get("leaderboard_rank", 0))
	var rank_text := "--" if rank <= 0 else "#%d" % rank
	var cyan := Color(0.2, 0.92, 0.82, 1.0)
	var amber := Color(0.9, 0.75, 0.38, 1.0)
	var red := Color(1.0, 0.27, 0.18, 1.0)
	$Root/Pages/ResultPage/Reason.text = "ROCKET BAY PRESERVED  •  DETONATOR REMOVED" if success else "DETONATION CONFIRMED  •  KESTREL RIDGE LOST"
	_set_result_value(^"Root/Pages/ResultPage/Primary/TimeGroup", _result_time(completion))
	_set_result_caption(^"Root/Pages/ResultPage/Primary/TimeGroup", "COMPLETION" if success else "ELAPSED")
	_set_result_value(^"Root/Pages/ResultPage/Primary/ScoreGroup", "%d" % int(snapshot.get("score", 0)))
	_set_result_value(^"Root/Pages/ResultPage/Primary/RankGroup", rank_text)
	_set_result_caption(^"Root/Pages/ResultPage/Primary/RankGroup", "LOCAL RECORD" if success else "RECENT RUN")
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Remaining", _result_time(remaining), amber)
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Eliminations", "%d" % int(snapshot.get("eliminations", 0)))
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Deaths", "%d" % int(snapshot.get("deaths", 0)), red)
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Restarts", "%d" % int(snapshot.get("restart_count", 0)))
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Alpha", "A %s" % ("SECURED" if snapshot.get("alpha_captured", false) else "HOSTILE"), cyan if snapshot.get("alpha_captured", false) else red)
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Bravo", "B %s" % ("SECURED" if snapshot.get("bravo_captured", false) else "HOSTILE"), cyan if snapshot.get("bravo_captured", false) else red)
	var completed_stages := 0
	for stage_key: String in ["diagnosis", "power_isolation", "detonator_removal"]:
		if int(components.get(stage_key, 0)) > 0:
			completed_stages += 1
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Charlie", "C %d/3" % completed_stages, cyan if completed_stages >= 3 else amber)
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Loadout", String(snapshot.get("selected_loadout", &"ak74m")).to_upper())
	_set_result_value(^"Root/Pages/ResultPage/Breakdown/Time", "%+d" % int(components.get("time", 0)))
	_set_result_value(^"Root/Pages/ResultPage/Breakdown/Alpha", "%+d" % int(components.get("alpha", 0)))
	_set_result_value(^"Root/Pages/ResultPage/Breakdown/Bravo", "%+d" % int(components.get("bravo", 0)))
	_set_result_value(^"Root/Pages/ResultPage/Breakdown/Eliminations", "%+d" % int(components.get("eliminations", 0)))
	_set_result_value(^"Root/Pages/ResultPage/Breakdown/Diagnosis", "%+d" % int(components.get("diagnosis", 0)))
	_set_result_value(^"Root/Pages/ResultPage/Breakdown/Isolation", "%+d" % int(components.get("power_isolation", 0)))
	_set_result_value(^"Root/Pages/ResultPage/Breakdown/Detonator", "%+d" % int(components.get("detonator_removal", 0)))
	_set_result_value(^"Root/Pages/ResultPage/Breakdown/Deaths", "%+d" % int(components.get("deaths", 0)), red)
	_set_result_value(^"Root/Pages/ResultPage/Breakdown/Restarts", "%+d" % int(components.get("checkpoint_restarts", 0)))
	_set_result_value(^"Root/Pages/ResultPage/Breakdown/Record", "%+.1fs" % float(snapshot.get("fastest_success_delta", 0.0)) if success and rank > 1 else "NEW BEST" if success else "--", cyan if success else amber)
	var retry_button := $Root/Pages/ResultPage/Menu/RestartButton as Button
	retry_button.visible = not success and remaining > 0 and (not (mission.get("deployment_snapshot") as Dictionary).is_empty() or int(mission.get("checkpoint_version")) > 0)
	_show_page(STATE_SUCCESS_RESULT if success else STATE_FAILURE_RESULT, &"terminal_presentation_completed", &"terminal")


func _prime_terminal_result_page(result: StringName) -> void:
	var success := result == &"bomb_defused"
	var snapshot: Dictionary = mission.call(&"result_snapshot")
	var components: Dictionary = snapshot.get("score_components", {})
	var remaining := int(snapshot.get("remaining_seconds", 0))
	var completion := int(snapshot.get("completion_seconds", 0))
	var cyan := Color(0.2, 0.92, 0.82, 1.0)
	var amber := Color(0.9, 0.75, 0.38, 1.0)
	var red := Color(1.0, 0.27, 0.18, 1.0)
	$Root/Pages/ResultPage/Outcome.text = "MISSION COMPLETE" if success else "MISSION FAILED"
	$Root/Pages/ResultPage/Outcome.modulate = Color(0.2, 0.92, 0.82) if success else Color(1.0, 0.27, 0.18)
	$Root/Pages/ResultPage/Reason.text = "ROCKET BAY PRESERVED  •  DETONATOR REMOVED" if success else "DETONATION CONFIRMED  •  KESTREL RIDGE LOST"
	_set_result_value(^"Root/Pages/ResultPage/Primary/TimeGroup", _result_time(completion))
	_set_result_caption(^"Root/Pages/ResultPage/Primary/TimeGroup", "COMPLETION" if success else "ELAPSED")
	_set_result_value(^"Root/Pages/ResultPage/Primary/ScoreGroup", "%d" % int(snapshot.get("score", 0)))
	_set_result_value(^"Root/Pages/ResultPage/Primary/RankGroup", "--" if int(snapshot.get("leaderboard_rank", 0)) <= 0 else "#%d" % int(snapshot.get("leaderboard_rank", 0)))
	_set_result_caption(^"Root/Pages/ResultPage/Primary/RankGroup", "LOCAL RECORD" if success else "RECENT RUN")
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Remaining", _result_time(remaining), amber)
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Eliminations", "%d" % int(snapshot.get("eliminations", 0)))
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Deaths", "%d" % int(snapshot.get("deaths", 0)), red)
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Restarts", "%d" % int(snapshot.get("restart_count", 0)))
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Alpha", "A %s" % ("SECURED" if snapshot.get("alpha_captured", false) else "HOSTILE"), cyan if snapshot.get("alpha_captured", false) else red)
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Bravo", "B %s" % ("SECURED" if snapshot.get("bravo_captured", false) else "HOSTILE"), cyan if snapshot.get("bravo_captured", false) else red)
	var completed_stages := 0
	for stage_key: String in ["diagnosis", "power_isolation", "detonator_removal"]:
		if int(components.get(stage_key, 0)) > 0:
			completed_stages += 1
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Charlie", "C %d/3" % completed_stages, cyan if completed_stages >= 3 else amber)
	_set_result_value(^"Root/Pages/ResultPage/MissionMetrics/Loadout", String(snapshot.get("selected_loadout", &"ak74m")).to_upper())


func _mcp_state() -> Dictionary:
	var window := get_window()
	var focused := get_viewport().gui_get_focus_owner()
	return {
		"run_epoch": int(mission.get("run_epoch")),
		"app_state": app_state,
		"pages_visible": pages.visible,
		"shell_root_visible": root.visible,
		"route_plate_visible": $Root/Pages/LoadoutPage/RoutePlate.is_visible_in_tree(),
		"gameplay_surface_clear": app_state != STATE_GAMEPLAY or (not root.visible and not pages.visible),
		"selected_weapon": _selected_weapon,
		"focused_control": str(focused.get_path()) if focused != null else "",
		"applied_ui_scale": _applied_ui_scale,
		"shell_lifecycle_summary": {
			"opening_media_status": _opening_media_status,
			"opening_stream_bound": briefing_video.stream != null,
			"opening_video_loop": briefing_video.loop,
			"opening_audio_owner": _opening_audio_owner_receipt(),
			"briefing_complete": _briefing_complete,
			"briefing_caption_index": _briefing_caption_index,
			"briefing_visible_characters": _briefing_visible_characters,
			"briefing_manual_advance_count": _briefing_manual_advance_count,
			"opening_completion_count": _opening_completion_count,
			"deployment_requested": _deployment_requested,
			"last_deployment_input_receipt": _last_deployment_input_receipt,
			"last_tester_setup_receipt": _last_tester_setup_receipt,
			"tester_opening_fallback_active": _tester_opening_fallback_active,
			"tester_opening_fallback_generation": _tester_opening_fallback_generation,
			"last_tester_opening_reset_receipt": _last_tester_opening_reset_receipt,
			"death_lock_remaining": _death_lock_remaining,
			"queued_recovery_activation": _queued_recovery_activation,
			"queued_recovery_activation_receipt": _queued_recovery_activation_receipt,
			"last_activation_receipt": _last_activation_receipt,
			"last_lifecycle_action_receipt": _last_lifecycle_action_receipt,
			"death_recovery_cycle_count": _death_recovery_cycle_history.size(),
		},
		"display": {
			"persisted_fullscreen": bool(settings_store.snapshot().get("fullscreen_enabled", false)),
			"window_mode": window.mode,
			"window_size": window.size,
			"viewport_size": window.get_visible_rect().size,
			"content_scale_size": window.content_scale_size,
			"content_scale_factor": window.content_scale_factor,
			"render_scale_3d": window.scaling_3d_scale,
		},
		"result_page": {
			"visible": app_state in [STATE_SUCCESS_RESULT, STATE_FAILURE_RESULT],
			"outcome": $Root/Pages/ResultPage/Outcome.text,
			"reason": $Root/Pages/ResultPage/Reason.text,
			"time": (_result_value(^"Root/Pages/ResultPage/Primary/TimeGroup") as Label).text,
			"score": (_result_value(^"Root/Pages/ResultPage/Primary/ScoreGroup") as Label).text,
			"rank": (_result_value(^"Root/Pages/ResultPage/Primary/RankGroup") as Label).text,
			"authoritative_snapshot": mission.call(&"result_snapshot"),
			"icon_registry": _result_icon_registry_snapshot(),
			"hierarchy": {
				"primary_container_type": ($Root/Pages/ResultPage/Primary as Control).get_class(),
				"mission_metrics_container_type": ($Root/Pages/ResultPage/MissionMetrics as Control).get_class(),
				"breakdown_container_type": ($Root/Pages/ResultPage/Breakdown as Control).get_class(),
				"mission_metric_groups": _result_cluster_snapshot(^"Root/Pages/ResultPage/MissionMetrics"),
				"score_component_groups": _result_cluster_snapshot(^"Root/Pages/ResultPage/Breakdown"),
				"authority": &"mission.result_snapshot",
				"table_layout_removed": true,
			},
			"retry_visible": $Root/Pages/ResultPage/Menu/RestartButton.visible,
			"focused_primary_action": str(focused.get_path()) if focused != null and $Root/Pages/ResultPage/Menu.is_ancestor_of(focused) else "",
		},
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled"),
		"last_input_family": _last_input_family,
		"gamepad_focus_contract": {
			"title": "Root/MaaacksMainMenuRuntime/MenuContainer/MenuButtonsMargin/MenuButtonsContainer/MenuButtonsBoxContainer/NewGameButton",
			"loadout": "Root/Pages/LoadoutPage/Content/Weapons/AKButton",
			"briefing": "Root/Pages/BriefingPage/Actions/DeployButton",
			"pause": "Root/Pages/PausePage/Menu/ResumeButton",
			"settings": "Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume",
			"death_recovery": "Root/Pages/DeathPage/Menu/RestartButton",
			"success_result": "Root/Pages/ResultPage/Menu/ReplayButton",
			"failure_result": "Root/Pages/ResultPage/Menu/ReplayButton",
			"menu_accept_bound_to_gamepad": InputMap.has_action(&"menu_accept"),
			"menu_back_bound_to_gamepad": InputMap.has_action(&"menu_back"),
			"linear_neighbors_authored": true,
		},
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
		"death_recovery_cycle_serial": _death_recovery_cycle_serial,
		"death_recovery_cycle_history": _death_recovery_cycle_history,
		"death_recovery_cycle_count": _death_recovery_cycle_history.size(),
		"queued_recovery_activation": _queued_recovery_activation,
		"queued_recovery_activation_receipt": _queued_recovery_activation_receipt,
		"tester_opening_fallback_active": _tester_opening_fallback_active,
		"tester_opening_fallback_generation": _tester_opening_fallback_generation,
		"last_tester_opening_reset_receipt": _last_tester_opening_reset_receipt,
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
		"briefing_manual_advance_count": _briefing_manual_advance_count,
		"briefing_cue_elapsed": _briefing_cue_elapsed,
		"briefing_visible_characters": _briefing_visible_characters,
		"briefing_total_characters": BRIEFING_CAPTIONS[_briefing_caption_index].length() if _briefing_caption_index >= 0 and _briefing_caption_index < BRIEFING_CAPTIONS.size() else 0,
		"briefing_cue_revealed": _briefing_cue_revealed,
		"briefing_indefinite_dwell": _briefing_cue_revealed and not _briefing_complete,
		"last_briefing_input_receipt": _last_briefing_input_receipt,
		"briefing_input_history": _briefing_input_history,
		"opening_media_status": _opening_media_status,
		"opening_stream_bound": briefing_video.stream != null,
		"opening_video_playing": briefing_video.is_playing(),
		"opening_video_paused": briefing_video.paused,
		"opening_video_loop": briefing_video.loop,
		"opening_video_stream_position": briefing_video.stream_position,
		"opening_video_stream_length": briefing_video.get_stream_length() if briefing_video.stream != null else 0.0,
		"opening_completion_source": _opening_completion_source,
		"opening_completion_count": _opening_completion_count,
		"opening_video_path": OPENING_VIDEO_PATH,
		"opening_receipt_path": "res://art/source/cinematics/opening_fusepoint_daylight_i2v/generation_receipt.json",
		"opening_audio_owner": _opening_audio_owner_receipt(),
		"deployment_requested": _deployment_requested,
		"last_deployment_input_receipt": _last_deployment_input_receipt,
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


func _result_icon_registry_snapshot() -> Dictionary:
	_ensure_result_icon_cache()
	return {
		"contract": &"native_runtime_texture_registry",
		"resource_loader_used": false,
		"source_svg_paths_retained_for_authoring_only": RESULT_ICON_PATHS.duplicate(true),
		"icons": _result_icon_status.duplicate(true),
	}


func _opening_audio_owner_receipt() -> Dictionary:
	return {
		"receipt_path": OPENING_VIDEO_AUDIO_RECEIPT,
		"opening_video_path": OPENING_VIDEO_PATH,
		"runtime_video_sha256": OPENING_VIDEO_SHA256,
		"container_audio_stream_present": false,
		"authorized_dialogue_owner": false,
		"opening_video_can_emit_embedded_audio": false,
		"transcode": &"video_only_copy_stream",
		"video_duration_seconds": 10.0,
		"audio_owner_status": &"removed_from_runtime_container",
	}
