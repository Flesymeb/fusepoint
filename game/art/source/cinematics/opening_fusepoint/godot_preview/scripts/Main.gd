extends Node2D

const FRAME_DIR := "res://assets/frames"
const FPS := 12

func _ready() -> void:
    var viewport_size := get_viewport_rect().size
    var bg := ColorRect.new()
    bg.color = Color(0.015, 0.017, 0.02, 1.0)
    bg.size = viewport_size
    add_child(bg)

    var title := Label.new()
    title.text = "fusepoint_opening"
    title.position = Vector2(24, 20)
    title.add_theme_font_size_override("font_size", 24)
    add_child(title)

    var sprite := AnimatedSprite2D.new()
    sprite.position = viewport_size * 0.5
    sprite.scale = Vector2(1.35, 1.35)
    var mat := CanvasItemMaterial.new()
    
    sprite.material = mat

    var sprite_frames := SpriteFrames.new()
    sprite_frames.add_animation("play")
    sprite_frames.set_animation_speed("play", FPS)
    sprite_frames.set_animation_loop("play", true)
    for file_name in _frame_files():
        var image := Image.new()
        var err := image.load(FRAME_DIR + "/" + file_name)
        if err == OK:
            var tex := ImageTexture.create_from_image(image)
            sprite_frames.add_frame("play", tex)
    sprite.sprite_frames = sprite_frames
    sprite.animation = "play"
    sprite.play()
    add_child(sprite)

func _frame_files() -> Array[String]:
    var result: Array[String] = []
    var files := DirAccess.get_files_at(FRAME_DIR)
    for file_name in files:
        if file_name.ends_with(".png"):
            result.append(file_name)
    result.sort()
    return result
