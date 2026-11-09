import Foundation

// Every string Render Animation and the Render, Output and World tabs send,
// printed for a headless Blender (verify.py) to run.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }

// Render Animation as the Render panel sends it: the scene's own engine and
// settings, an MPEG-4 video while the Output is untouched.
emit("ANIM_VIDEO", RenderRequest(engine: .workbench, source: .sceneCamera, output: "@BASE@",
                                 progressReport: "@PROGRESS@",
                                 animation: RenderRequest.Animation(video: true, frames: "@FRAMES@",
                                                                    cancel: "@CANCEL@", result: "@RESULT@")).python)
// The scene's own Output (chosen), whatever it is.
emit("ANIM_SCENE", RenderRequest(engine: .workbench, source: .sceneCamera, output: "@BASE@",
                                 animation: RenderRequest.Animation(video: false, frames: "@FRAMES@",
                                                                    cancel: "@CANCEL@", result: "@RESULT@")).python)
emit("ANIM_EEVEE", RenderRequest(engine: .eevee, source: .sceneCamera, output: "@BASE@",
                                 animation: RenderRequest.Animation(video: true, frames: "@FRAMES@",
                                                                    cancel: "@CANCEL@", result: "@RESULT@")).python)
// Test All Features' own: three frames at 64 × 36, whatever the scene says.
emit("ANIM_FEATURE", RenderRequest(engine: .workbench, width: 64, height: 36, source: .sceneCamera,
                                   output: "@BASE@",
                                   animation: RenderRequest.Animation(video: true, frames: "@FRAMES@",
                                                                      result: "@RESULT@", range: 1...3)).python)
// The panel's still, from a video Output.
emit("STILL_SCENE", RenderRequest(engine: .workbench, source: .sceneCamera, output: "@OUT@").python)

emit("SETTINGS", RenderSettingsBpy.report)
emit("ENGINE_CYCLES", RenderSettingsBpy.engine("CYCLES"))
emit("ENGINE_EEVEE", RenderSettingsBpy.engine("BLENDER_EEVEE"))
emit("RATE_2398", RenderSettingsBpy.frameRate(FrameRatePreset.all[3]))
emit("FORMAT_VIDEO", RenderSettingsBpy.fileFormat("FFMPEG"))
emit("FORMAT_PNG", RenderSettingsBpy.fileFormat("PNG"))
emit("FORMAT_JPEG", RenderSettingsBpy.fileFormat("JPEG"))
emit("FORMAT_EXR", RenderSettingsBpy.fileFormat("OPEN_EXR"))
emit("QUALITY_DRAFT_EEVEE", RenderSettingsBpy.quality(.draft, engine: .eevee)!)
emit("QUALITY_BEST_CYCLES", RenderSettingsBpy.quality(.best, engine: .cycles)!)
emit("SET_RES_X", RenderSettingsBpy.set("render.resolution_x", int: 1280))
emit("SET_PERCENT", RenderSettingsBpy.set("render.resolution_percentage", int: 50))
emit("SET_STEP", RenderSettingsBpy.set("frame_step", int: 2))
emit("SET_FRAME_START", BpyAnimation.setFrameStart(5))
emit("SET_COLOR_MODE", RenderSettingsBpy.set("render.image_settings.color_mode", choice: "BW"))
emit("SET_CONTAINER", RenderSettingsBpy.set("render.ffmpeg.format", choice: "QUICKTIME"))
emit("SET_CODEC", RenderSettingsBpy.set("render.ffmpeg.codec", choice: "H265"))
emit("SET_CRF", RenderSettingsBpy.set("render.ffmpeg.constant_rate_factor", choice: "HIGH"))
emit("SET_DEVICE", RenderSettingsBpy.set("cycles.device", choice: "CPU"))
emit("SET_THRESHOLD", RenderSettingsBpy.set("cycles.adaptive_threshold", float: 0.05))
emit("SET_TIME_LIMIT", RenderSettingsBpy.set("cycles.time_limit", float: 2.5))
emit("SET_DENOISE", RenderSettingsBpy.set("cycles.use_denoising", bool: false))
emit("SET_BOUNCES", RenderSettingsBpy.set("cycles.max_bounces", int: 4))
emit("SET_TRANSPARENT", RenderSettingsBpy.set("render.film_transparent", bool: true))
emit("SET_RAYTRACING", RenderSettingsBpy.set("eevee.use_raytracing", bool: true))
emit("SET_SHADOW_RAYS", RenderSettingsBpy.set("eevee.shadow_ray_count", int: 3))
emit("SET_MOTION_BLUR", RenderSettingsBpy.set("render.use_motion_blur", bool: true))
emit("SET_LIGHT", RenderSettingsBpy.set("display.shading.light", choice: "FLAT"))
emit("SET_OBJECT_COLOR", RenderSettingsBpy.set("display.shading.color_type", choice: "SINGLE"))
emit("SET_RENDER_AA", RenderSettingsBpy.set("display.render_aa", choice: "16"))
emit("SET_VIEW", RenderSettingsBpy.set("view_settings.view_transform", choice: "Standard"))
emit("SET_LOOK", RenderSettingsBpy.set("view_settings.look", choice: "AgX - Punchy"))
emit("SET_EXPOSURE", RenderSettingsBpy.set("view_settings.exposure", float: 0.5))
emit("SET_GAMMA", RenderSettingsBpy.set("view_settings.gamma", float: 1.2))
emit("WORLD_NEW", RenderSettingsBpy.newWorld)
emit("WORLD_COLOR", RenderSettingsBpy.worldColor(SIMD3(0.2, 0.4, 0.8)))
emit("WORLD_STRENGTH", RenderSettingsBpy.worldStrength(2.5))

print(out.joined(separator: "\n#--\n"))
