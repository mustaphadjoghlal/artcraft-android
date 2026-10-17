//! Builder-owned Android shell for PhotoCraft.
//! Platform file operations use Android's Storage Access Framework (SAF). Selected documents
//! are staged inside app-private storage, with a persistent URI mapping used to write saved bytes
//! back through ContentResolver. The upstream PhotoCraft crates remain unchanged.
//! ARTCRAFT_PHOTOCRAFT_SAF_JNI022_FIX_V1

use android_activity::AndroidApp;
use jni::{
    JavaVM, jni_sig, jni_str,
    objects::{JObject, JString, JValue},
};
use photocraft_codecs::{ChannelLayout, EncodeOptions, Image};
use photocraft_doc::Document;
use photocraft_engine::Session;
use photocraft_ui_egui::{
    FileDialogAnswer, FileDialogReply, FileDialogRequest, Inbox, PhotocraftApp, Services,
};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

// Shared with the generated launchers: brings the device's own system fonts into the egui fallback
// chain and makes them visible to the app's own font scanners (see templates/android/system_fonts.rs).
mod system_fonts;

// Shared with the generated launchers: turns Android's soft keyboard into egui IME events (see
// templates/android/ime_bridge.rs). The `mod ime_bridge;` marker also keeps the vendored
// android-activity, which forwards show/hide to this Activity's imeShow/imeHide, in step.
mod ime_bridge;

/// Emitted at startup so a device log (and the packaged `.so` strings) can confirm this shell —
/// including the Android modifier-key fix and immersive fullscreen — is the one that is running.
const ANDROID_SHELL_MARKER: &str = "ARTCRAFT_PHOTOCRAFT_ANDROID_SHELL_V2_MODIFIERS_FULLSCREEN";

/// Phone-screen UI scale. PhotoCraft's egui layout is designed for desktop windows (it needs
/// roughly a thousand points of width for its menu bar and dialogs), so at the device's native
/// density it is too large and its edges are clipped. The zoom factor is chosen from the real
/// screen width so the UI always gets about `PHONE_TARGET_WIDTH_PT` logical points of width,
/// and follows rotation. Raise the target for a smaller, roomier layout; lower it for bigger text.
const PHONE_TARGET_WIDTH_PT: f32 = 1000.0;
/// The UI is never zoomed out further than this, even on very narrow screens.
const PHONE_MIN_ZOOM: f32 = 0.3;

/// Pick the zoom factor that gives the UI `PHONE_TARGET_WIDTH_PT` points of width on this screen.
fn apply_phone_zoom(ctx: &egui::Context, raw: &egui::RawInput) {
    let Some(rect) = raw.screen_rect else { return };
    let ppp = ctx.pixels_per_point();
    let native = ctx
        .native_pixels_per_point()
        .unwrap_or(ppp / ctx.zoom_factor());
    let physical_width = rect.width() * ppp;
    if physical_width <= 0.0 || native <= 0.0 {
        return;
    }
    let zoom = (physical_width / (native * PHONE_TARGET_WIDTH_PT)).clamp(PHONE_MIN_ZOOM, 1.0);
    if (ctx.zoom_factor() - zoom).abs() > 0.01 {
        ctx.set_zoom_factor(zoom);
    }
}

struct AndroidFileBridge {
    app: AndroidApp,
    vm: Arc<JavaVM>,
}

impl AndroidFileBridge {
    fn new(app: AndroidApp) -> Result<Self, String> {
        // AndroidApp owns the live VM pointer for the lifetime of the activity.
        let vm = unsafe { JavaVM::from_raw(app.vm_as_ptr() as *mut _) };
        Ok(Self {
            app,
            vm: Arc::new(vm),
        })
    }

    fn request_open(&self, id: u64, multiple: bool) -> Result<(), String> {
        self.vm
            .attach_current_thread(|env| -> jni::errors::Result<()> {
                // AndroidApp returns an unowned global ref. Do not delete it when this wrapper drops.
                let activity_raw = self.app.activity_as_ptr() as jni::sys::jobject;
                // SAFETY: AndroidApp retains this global Activity reference; as_cast_raw borrows it
                // without taking ownership or attempting to delete the reference.
                let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw)? };
                env.call_method(
                    &*activity,
                    jni_str!("pcRequestOpen"),
                    jni_sig!("(JZ)V"),
                    &[JValue::Long(id as i64), JValue::Bool(multiple)],
                )?;
                Ok(())
            })
            .map_err(|e| e.to_string())
    }

    fn request_save(&self, id: u64, name: &str) -> Result<(), String> {
        self.vm
            .attach_current_thread(|env| -> jni::errors::Result<()> {
                let activity_raw = self.app.activity_as_ptr() as jni::sys::jobject;
                // SAFETY: AndroidApp retains this global Activity reference; as_cast_raw borrows it
                // without taking ownership or attempting to delete the reference.
                let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw)? };
                let name = env.new_string(name)?;
                let name_obj = JObject::from(name);
                env.call_method(
                    &*activity,
                    jni_str!("pcRequestSave"),
                    jni_sig!("(JLjava/lang/String;)V"),
                    &[JValue::Long(id as i64), JValue::Object(&name_obj)],
                )?;
                Ok(())
            })
            .map_err(|e| e.to_string())
    }

    fn poll_result(&self) -> Result<Option<String>, String> {
        self.vm
            .attach_current_thread(|env| -> jni::errors::Result<Option<String>> {
                let activity_raw = self.app.activity_as_ptr() as jni::sys::jobject;
                // SAFETY: AndroidApp retains this global Activity reference; as_cast_raw borrows it
                // without taking ownership or attempting to delete the reference.
                let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw)? };
                let value = env
                    .call_method(
                        &*activity,
                        jni_str!("pcPollPickerResult"),
                        jni_sig!("()Ljava/lang/String;"),
                        &[],
                    )?
                    .l()?;
                if value.is_null() {
                    return Ok(None);
                }
                let value = JString::cast_local(env, value)?;
                let value: String = value.try_to_string(env)?;
                Ok(Some(value))
            })
            .map_err(|e| e.to_string())
    }

    /// Hand back the private path of one file the system asked this app to open (an
    /// `ACTION_VIEW`/`ACTION_SEND` it is registered for), or `None` when nothing is pending. Returns
    /// an error when the Activity has no intent host; the caller then stops asking.
    fn intent_poll(&self) -> Result<Option<String>, String> {
        self.vm
            .attach_current_thread(|env| -> jni::errors::Result<Option<String>> {
                let activity_raw = self.app.activity_as_ptr() as jni::sys::jobject;
                // SAFETY: AndroidApp retains this global Activity reference; as_cast_raw borrows it
                // without taking ownership or attempting to delete the reference.
                let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw)? };
                let value = match env.call_method(
                    &*activity,
                    jni_str!("intentPoll"),
                    jni_sig!("()Ljava/lang/String;"),
                    &[],
                ) {
                    Ok(value) => value.l()?,
                    Err(error) => {
                        // A missing `intentPoll` leaves a pending NoSuchMethodError on the shared
                        // JNI thread (the picker bridge uses it too); clear it before returning.
                        env.exception_clear();
                        return Err(error);
                    }
                };
                if value.is_null() {
                    return Ok(None);
                }
                let value = JString::cast_local(env, value)?;
                let value: String = value.try_to_string(env)?;
                Ok(Some(value))
            })
            .map_err(|e| e.to_string())
    }

    fn files_dir(&self) -> Result<PathBuf, String> {
        self.vm
            .attach_current_thread(|env| -> jni::errors::Result<PathBuf> {
                let activity_raw = self.app.activity_as_ptr() as jni::sys::jobject;
                // SAFETY: AndroidApp retains this global Activity reference; as_cast_raw borrows it
                // without taking ownership or attempting to delete the reference.
                let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw)? };
                let value = env
                    .call_method(
                        &*activity,
                        jni_str!("pcFilesDir"),
                        jni_sig!("()Ljava/lang/String;"),
                        &[],
                    )?
                    .l()?;
                let value = JString::cast_local(env, value)?;
                let value: String = value.try_to_string(env)?;
                Ok(PathBuf::from(value))
            })
            .map_err(|e| e.to_string())
    }

    /// Returns NONE for ordinary private paths, OK after committing a selected SAF destination,
    /// or ERROR:<message> if the Android provider refused the write.
    fn commit_if_mapped(&self, path: &str) -> Result<String, String> {
        self.vm
            .attach_current_thread(|env| -> jni::errors::Result<String> {
                let activity_raw = self.app.activity_as_ptr() as jni::sys::jobject;
                // SAFETY: AndroidApp retains this global Activity reference; as_cast_raw borrows it
                // without taking ownership or attempting to delete the reference.
                let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw)? };
                let path = env.new_string(path)?;
                let path_obj = JObject::from(path);
                let value = env
                    .call_method(
                        &*activity,
                        jni_str!("pcCommitIfMapped"),
                        jni_sig!("(Ljava/lang/String;)Ljava/lang/String;"),
                        &[JValue::Object(&path_obj)],
                    )?
                    .l()?;
                let value = JString::cast_local(env, value)?;
                let value: String = value.try_to_string(env)?;
                Ok(value)
            })
            .map_err(|e| e.to_string())
    }
}

#[derive(Default)]
struct PickerState {
    next_id: AtomicU64,
    replies: Mutex<HashMap<u64, FileDialogReply>>,
}

impl PickerState {
    fn launch(
        &self,
        bridge: &AndroidFileBridge,
        request: FileDialogRequest,
        reply: FileDialogReply,
    ) {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        let launch_result = match request {
            FileDialogRequest::Open { multiple, .. } => {
                self.replies
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(id, reply);
                bridge.request_open(id, multiple)
            }
            FileDialogRequest::Save { suggested } => {
                let name = Path::new(&suggested)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| "Untitled.pcraft".to_string());
                self.replies
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(id, reply);
                bridge.request_save(id, &name)
            }
            FileDialogRequest::Folder { .. } => {
                reply.send(Some(FileDialogAnswer::Unavailable(
                    "Choosing folders is not supported by this Android file picker yet. Use Open or Save As for individual files.".into(),
                )));
                return;
            }
        };
        if let Err(error) = launch_result {
            if let Some(reply) = self
                .replies
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&id)
            {
                reply.send(Some(FileDialogAnswer::Unavailable(format!(
                    "Could not start Android file picker: {error}"
                ))));
            }
        }
    }

    fn poll(&self, bridge: &AndroidFileBridge, ctx: &egui::Context) {
        // Each result is one short JSON object queued by PhotoCraftActivity after picker I/O ends.
        for _ in 0..8 {
            let raw = match bridge.poll_result() {
                Ok(Some(raw)) => raw,
                Ok(None) => break,
                Err(error) => {
                    log::error!("Android file picker polling failed: {error}");
                    break;
                }
            };
            let value: serde_json::Value = match serde_json::from_str(&raw) {
                Ok(value) => value,
                Err(error) => {
                    log::error!("Invalid Android picker result: {error}: {raw}");
                    continue;
                }
            };
            let Some(id) = value.get("id").and_then(serde_json::Value::as_u64) else {
                log::error!("Android picker result has no request id: {raw}");
                continue;
            };
            let Some(reply) = self
                .replies
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&id)
            else {
                log::warn!("Ignoring stale Android picker reply {id}");
                continue;
            };
            let status = value
                .get("status")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("error");
            let kind = value
                .get("kind")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("");
            let answer = match status {
                "cancel" => None,
                "ok" if kind == "open" => {
                    let paths = value
                        .get("paths")
                        .and_then(serde_json::Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(serde_json::Value::as_str)
                        .map(str::to_owned)
                        .collect::<Vec<_>>();
                    (!paths.is_empty()).then_some(FileDialogAnswer::Paths(paths))
                }
                "ok" if kind == "save" => value
                    .get("path")
                    .and_then(serde_json::Value::as_str)
                    .map(|path| FileDialogAnswer::SaveTo(path.to_owned())),
                _ => Some(FileDialogAnswer::Unavailable(
                    value
                        .get("message")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("Android file operation failed")
                        .to_owned(),
                )),
            };
            reply.send(answer);
            ctx.request_repaint();
        }
    }
}

fn write_mobile(bridge: &AndroidFileBridge, path: &str, bytes: &[u8]) -> Result<(), String> {
    let target = Path::new(path);
    if let Some(parent) = target.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Could not create {}: {e}", parent.display()))?;
    }
    let name = target
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("photocraft-output");
    let parent = target
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let temporary = parent.join(format!(".{name}.tmp-{}", std::process::id()));
    fs::write(&temporary, bytes)
        .map_err(|e| format!("Could not write {}: {e}", temporary.display()))?;
    if let Err(error) = fs::rename(&temporary, target) {
        let _ = fs::remove_file(&temporary);
        return Err(format!(
            "Could not finish writing {}: {error}",
            target.display()
        ));
    }
    match bridge.commit_if_mapped(path)? {
        state if state == "NONE" || state == "OK" => Ok(()),
        state if state.starts_with("ERROR:") => Err(state.trim_start_matches("ERROR:").to_owned()),
        state => Err(format!("Unexpected Android save result: {state}")),
    }
}

fn services(bridge: AndroidFileBridge, picker: Arc<PickerState>, prefs_path: PathBuf, inbox: Inbox) -> Services {
    let write_bridge = bridge.clone_for_services();
    let save_bridge = bridge.clone_for_services();
    let prefs_bridge = bridge.clone_for_services();
    let load_prefs_path = prefs_path.clone();
    Services {
        // Files the system asked us to open (ACTION_VIEW/ACTION_SEND) are queued here and drained
        // by the app's own per-frame inbox, exactly like a document chosen in the picker.
        inbox: Some(inbox),
        import: Some(Box::new(
            |name: &str, bytes: &[u8], max_svg_group_depth: usize| {
                photocraft_io::import_with_svg_group_depth(name, bytes, max_svg_group_depth)
                    .map(|r| (r.document, r.warnings))
                    .map_err(|e| e.to_string())
            },
        )),
        export: Some(Box::new(
            |doc: &Document, path: &str, settings: &photocraft_ui_egui::ExportSettings| {
                let mut opts = photocraft_io::ExportOptions::default();
                if let Some(q) = settings.jpeg_quality {
                    opts.encode.jpeg_quality = q;
                }
                opts.encode.webp_lossless = settings.webp_lossless;
                if let Some(q) = settings.webp_quality {
                    opts.encode.webp_quality = q;
                }
                opts.tiff_layers = settings.tiff_layers;
                opts.xmp = if settings.xmp_all {
                    photocraft_io::XmpEmbed::All
                } else {
                    photocraft_io::XmpEmbed::None
                };
                opts.tga_bits = settings.tga_bits;
                opts.image_previews = settings.image_previews;
                opts.psd_maximize_compatibility = settings.psd_maximize_compatibility;
                photocraft_io::export(doc, path, &opts)
                    .map(|r| (r.bytes, r.warnings))
                    .map_err(|e| e.to_string())
            },
        )),
        // Native .pcraft Save uses save_file rather than export. Route it through the same SAF-aware writer.
        save_file: Some(std::sync::Arc::new(
            move |doc: &Document,
                  path: &str,
                  settings: &photocraft_ui_egui::ExportSettings,
                  ctl: &photocraft_ui_egui::jobs_ui::SaveCtl| {
                ctl.progress(0.0, "Encoding");
                let mut opts = photocraft_io::ExportOptions::default();
                if let Some(q) = settings.jpeg_quality {
                    opts.encode.jpeg_quality = q;
                }
                opts.encode.webp_lossless = settings.webp_lossless;
                if let Some(q) = settings.webp_quality {
                    opts.encode.webp_quality = q;
                }
                opts.tiff_layers = settings.tiff_layers;
                opts.xmp = if settings.xmp_all {
                    photocraft_io::XmpEmbed::All
                } else {
                    photocraft_io::XmpEmbed::None
                };
                opts.tga_bits = settings.tga_bits;
                opts.image_previews = settings.image_previews;
                opts.psd_maximize_compatibility = settings.psd_maximize_compatibility;
                let result = photocraft_io::export(doc, path, &opts).map_err(|e| e.to_string())?;
                ctl.commit()?;
                ctl.progress(0.85, "Writing");
                write_mobile(&save_bridge, path, &result.bytes)?;
                ctl.progress(1.0, "");
                Ok(result.warnings)
            },
        )),
        file_dialog: Some(Box::new(move |request, _parent, reply| {
            picker.launch(&bridge, request, reply);
        })),
        write: Some(Box::new(move |path: &str, bytes: &[u8]| {
            write_mobile(&write_bridge, path, bytes)
        })),
        load_prefs: Some(Box::new(move || fs::read_to_string(&load_prefs_path).ok())),
        save_prefs: Some(Box::new(move |text: &str| {
            write_mobile(
                &prefs_bridge,
                &prefs_path.to_string_lossy(),
                text.as_bytes(),
            )
        })),
        encode_png: Some(Box::new(|w, h, rgba| {
            let img = Image::from_u8(w, h, ChannelLayout::Rgba, rgba.to_vec())
                .map_err(|e| e.to_string())?;
            photocraft_codecs::encode(
                &img,
                photocraft_codecs::Format::Png,
                &EncodeOptions::default(),
            )
            .map_err(|e| e.to_string())
        })),
        ..Services::default()
    }
}

// Keep the JavaVM and the AndroidApp cheap to clone into platform-service closures.
impl AndroidFileBridge {
    fn clone_for_services(&self) -> Self {
        Self {
            app: self.app.clone(),
            vm: self.vm.clone(),
        }
    }
}

/// Reconstruct egui's modifier state on Android.
///
/// winit's Android backend delivers `KeyboardInput` events but never emits `ModifiersChanged`
/// (it discards the `KeyEvent`'s meta state), so egui's modifier state stays empty and
/// `Ctrl`/`Alt` shortcuts are ignored while plain keys continue to work. Physical modifier keys
/// do arrive as `Event::Key` events (`Key::ControlLeft`, `Key::AltLeft`, ...), so we track them
/// and stamp the resulting state onto this frame's events. This mirrors `egui-winit`'s
/// `ModifiersChanged` handling and suppresses the text character that would otherwise be emitted
/// alongside a Ctrl/Command shortcut.
fn apply_android_modifiers(state: &mut egui::Modifiers, raw: &mut egui::RawInput) {
    let before = *state;
    let mut kept: Vec<egui::Event> = Vec::with_capacity(raw.events.len());
    for mut event in raw.events.drain(..) {
        match &mut event {
            egui::Event::Key {
                key,
                physical_key,
                pressed,
                modifiers,
                ..
            } => {
                let tracked = physical_key.unwrap_or(*key);
                match tracked {
                    egui::Key::ShiftLeft | egui::Key::ShiftRight => state.shift = *pressed,
                    egui::Key::ControlLeft | egui::Key::ControlRight => state.ctrl = *pressed,
                    egui::Key::AltLeft | egui::Key::AltRight => state.alt = *pressed,
                    _ => {}
                }
                state.mac_cmd = false;
                state.command = state.ctrl;
                *modifiers = *state;
                kept.push(event);
            }
            egui::Event::PointerButton { modifiers, .. } => {
                *modifiers = *state;
                kept.push(event);
            }
            egui::Event::MouseWheel { modifiers, .. } => {
                *modifiers = *state;
                kept.push(event);
            }
            egui::Event::Text(_) if state.ctrl || state.command || state.mac_cmd => {
                // Suppress text emitted with a modifier chord.
            }
            egui::Event::WindowFocused(false) => {
                *state = egui::Modifiers::default();
                kept.push(event);
            }
            _ => kept.push(event),
        }
    }
    raw.events = kept;
    if *state != before {
        // `RawInput` has no modifier field in this egui version: `InputState.modifiers` is driven
        // purely by this event (plus its own per-event copies), so it must be emitted on change.
        raw.events.push(egui::Event::ModifiersChanged(*state));
    }
}


struct PhotoCraftAndroidApp {
    inner: PhotocraftApp,
    bridge: AndroidFileBridge,
    picker: Arc<PickerState>,
    ime: ime_bridge::ime::ImeBridge,
    modifiers: egui::Modifiers,
    // Files the system asked us to open are staged by the Activity; this is the shared queue the
    // app's own inbox drains. `intent_warmup` skips the first couple of frames so the app has
    // finished its own start-up, and goes negative (stop polling) if the host has no intent bridge.
    intent_inbox: Inbox,
    intent_warmup: i64,
}

/// Read the files the system asked this app to open (an `ACTION_VIEW`/`ACTION_SEND` it is registered
/// for) into the app's import inbox, exactly like a document chosen in the picker. Each staged path
/// is read once; a launcher without the intent host stops the poll after one error.
fn drain_incoming(bridge: &AndroidFileBridge, inbox: &Inbox, warmup: &mut i64) {
    if *warmup > 0 {
        *warmup -= 1;
        return;
    }
    if *warmup < 0 {
        return;
    }
    for _ in 0..16 {
        match bridge.intent_poll() {
            Ok(Some(path)) => match fs::read(&path) {
                Ok(bytes) => {
                    let name = Path::new(&path)
                        .file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .unwrap_or_else(|| "imported-file".to_string());
                    log::info!("Opening the file the system handed the app: {path}");
                    inbox.lock().unwrap_or_else(|e| e.into_inner()).push((name, bytes));
                }
                Err(error) => log::error!("Could not read the incoming file {path}: {error}"),
            },
            Ok(None) => break,
            Err(error) => {
                log::info!("Launcher does not report incoming files: {error}");
                *warmup = -1;
                break;
            }
        }
    }
}

impl eframe::App for PhotoCraftAndroidApp {
    fn logic(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        self.picker.poll(&self.bridge, ctx);
        // Deliver any file the system asked us to open through the app's own inbox.
        drain_incoming(&self.bridge, &self.intent_inbox, &mut self.intent_warmup);
        self.inner.logic(ctx, frame);
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        system_fonts::install_system_fonts(ui.ctx());
        self.inner.ui(ui, _frame);
    }

    fn raw_input_hook(&mut self, ctx: &egui::Context, raw: &mut egui::RawInput) {
        self.ime.poll(raw);
        apply_android_modifiers(&mut self.modifiers, raw);
        apply_phone_zoom(ctx, raw);
        self.inner.raw_input_hook(ctx, raw);
    }
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
fn android_main(android_app: AndroidApp) {
    log::info!("{ANDROID_SHELL_MARKER} ready; {}", ime_bridge::ime::IME_MARKER);
    system_fonts::install_font_env(&android_app);
    let bridge = match AndroidFileBridge::new(android_app.clone()) {
        Ok(bridge) => bridge,
        Err(error) => {
            log::error!("PhotoCraft Android startup failed: {error}");
            return;
        }
    };
    let files_dir = match bridge.files_dir() {
        Ok(path) => path,
        Err(error) => {
            log::error!("Could not locate PhotoCraft app-private storage: {error}");
            return;
        }
    };
    let prefs_path = files_dir.join("PhotoCraft").join("preferences.json");
    if let Some(parent) = prefs_path.parent() {
        if let Err(error) = fs::create_dir_all(parent) {
            log::error!("Could not create preferences directory: {error}");
        }
    }
    let picker = Arc::new(PickerState::default());
    let intent_inbox: Inbox = Arc::new(Mutex::new(Vec::new()));
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("PhotoCraft")
            .with_drag_and_drop(true),
        android_app: Some(android_app),
        ..Default::default()
    };
    let app_bridge = bridge.clone_for_services();
    let app_picker = picker.clone();
    let app_intent_inbox = intent_inbox.clone();
    let result = eframe::run_native(
        "PhotoCraft",
        options,
        Box::new(move |cc| {
            PhotocraftApp::setup_context(&cc.egui_ctx, photocraft_ui_egui::theme::ThemeKind::Pro);
            cc.egui_ctx.set_zoom_factor(0.4);
            let app = PhotocraftApp::new(
                Session::new(),
                services(
                    app_bridge.clone_for_services(),
                    app_picker.clone(),
                    prefs_path.clone(),
                    app_intent_inbox.clone(),
                ),
            );
            Ok(Box::new(PhotoCraftAndroidApp {
                inner: app,
                bridge: app_bridge.clone_for_services(),
                picker: app_picker.clone(),
                ime: ime_bridge::ime::ImeBridge::new(&app_bridge.app),
                modifiers: egui::Modifiers::default(),
                intent_inbox: app_intent_inbox.clone(),
                intent_warmup: 2,
            }))
        }),
    );
    if let Err(error) = result {
        log::error!("PhotoCraft Android exited with an error: {error}");
    }
}
