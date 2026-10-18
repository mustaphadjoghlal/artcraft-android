#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-}"
shift || true
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
    cat <<'USAGE'
Usage:
  bash build.sh -pdfcraft [options]
  bash build-debug.sh -photocraft [options]

Required:
  -<app>              App to build (leading hyphen)

Options:
  -appname=<name>     Override the display name (default: app's built-in title)
  -packagename=<pkg>  Override the Android package (default: com.artcraft.<app>)
  -appicon=<path>     Use a custom launcher icon PNG (default: app's own icon)
  -h, --help          Show this help

App names:
  photocraft vectorcraft filmcraft lightcraft pdfcraft effectcraft
  designcraft figcraft wordcraft soundcraft deckcraft cadcraft gridcraft

Examples:
  bash build.sh -photocraft
  bash build.sh -photocraft -appname=notPhotoshop
  bash build.sh -photocraft -packagename=com.adobe.photoshow
  bash build.sh -photocraft -appicon=/path/to/icon.png
  bash build.sh -photocraft -appname=MyApp -packagename=com.example.myapp -appicon=icon.png

Files created by the builder stay under this directory:
  source/<app>/     checked-out source plus generated Android launcher
  build/<app>/      Cargo build output
  output/           final APKs
  logs/             build logs
  keys/             persistent local signing key (keep it safe)
USAGE
}

if [[ "$MODE" != "release" && "$MODE" != "debug" ]]; then
    echo "Internal error: build mode must be release or debug." >&2
    exit 2
fi

# Parse optional arguments
APPNAME=""
PACKAGENAME=""
APPICON=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -appname=*)
            APPNAME="${1#-appname=}"
            shift
            ;;
        -packagename=*)
            PACKAGENAME="${1#-packagename=}"
            shift
            ;;
        -appicon=*)
            APPICON="${1#-appicon=}"
            shift
            ;;
        -*)
            RAW_APP="$1"
            shift
            ;;
        *)
            echo "Unexpected argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -z "$RAW_APP" ]]; then
    echo "Missing required app argument." >&2
    usage
    exit 2
fi
[[ "$RAW_APP" == -* ]] || { echo "Use a leading hyphen, for example: bash build.sh -pdfcraft" >&2; usage; exit 2; }
APP="${RAW_APP#-}"
[[ "$APP" != -* && "$APP" =~ ^[a-z]+$ ]] || { echo "Invalid app name: $RAW_APP" >&2; usage; exit 2; }

case "$APP" in
    photocraft) TITLE="PhotoCraft" ;;
    vectorcraft) TITLE="VectorCraft" ;;
    filmcraft) TITLE="FilmCraft" ;;
    lightcraft) TITLE="LightCraft" ;;
    pdfcraft) TITLE="PdfCraft" ;;
    effectcraft) TITLE="EffectCraft" ;;
    designcraft) TITLE="DesignCraft" ;;
    figcraft) TITLE="FigCraft" ;;
    wordcraft) TITLE="WordCraft" ;;
    soundcraft) TITLE="SoundCraft" ;;
    deckcraft) TITLE="DeckCraft" ;;
    cadcraft) TITLE="CADCraft" ;;
    gridcraft) TITLE="GridCraft" ;;
    *) echo "Unsupported app: $APP" >&2; usage; exit 2 ;;
esac
if [[ -n "$APPNAME" ]]; then TITLE="$APPNAME"; fi

SRC="source/$APP"
REPO="https://github.com/storytold/$APP.git"
ANDROID_DIR="$SRC/apps/$APP-android"
mkdir -p source build output logs keys adapters

say() { printf '\n[%s] %s\n' "$1" "$2"; }

fail() {
    echo >&2
    echo "ERROR: $*" >&2
    echo "No source checkout or existing project files were deleted." >&2
    exit 1
}

# Only one build may run at a time, and the runs are not independent. `prepare.sh` replaces the
# launcher crate under source/<app>/apps/<app>-android, and this script later runs cargo-apk2 from
# that very directory (`cd "$ANDROID_DIR"`), which is where javac inherits its working directory. A
# second build that wipes it mid-compile kills the first one with "Error occurred during
# initialization of VM ... Could not determine current working directory", which points nowhere near
# the real cause. Refuse up front instead, naming the process that holds the lock.
BUILD_LOCK="$ROOT/.artcraft-build.lock"
if command -v flock >/dev/null 2>&1; then
    exec {BUILD_LOCK_FD}>>"$BUILD_LOCK"
    if ! flock -n "$BUILD_LOCK_FD"; then
        BUILD_LOCK_HOLDER="$(cat "$BUILD_LOCK" 2>/dev/null || true)"
        fail "another build is already running${BUILD_LOCK_HOLDER:+ (pid $BUILD_LOCK_HOLDER)}. Run builds one after another: two at once replace each other's launcher crate and both can fail. If that process is gone, just run this again. ($BUILD_LOCK)"
    fi
    : >"$BUILD_LOCK"
    printf '%s\n' "$$" >&"$BUILD_LOCK_FD"
fi

say 1 "Checking build tools..."
command -v git >/dev/null 2>&1 || fail "git is required."
command -v cargo >/dev/null 2>&1 || fail "Rust/Cargo is required."
command -v python3 >/dev/null 2>&1 || fail "Python 3.11+ is required (tomllib is used to inspect manifests)."
python3 -c 'import tomllib' >/dev/null 2>&1 || fail "Python 3.11+ with tomllib is required."

# Apps whose launcher (adapter or builder-generated) ships a Java Storage Access Framework Activity.
# Kept here in addition to the manifest check below so cargo-apk2 is selected even on the very first
# build, before the launcher has been generated. Keep in sync with SAF_RECIPES in this file.
SAF_APPS=" designcraft deckcraft gridcraft wordcraft lightcraft effectcraft filmcraft cadcraft soundcraft pdfcraft figcraft "
needs_saf() {
    [[ " $SAF_APPS " == *" $1 "* ]]
}

# An adapter (or generated launcher) that ships Java sources (the Storage Access Framework file
# pickers) needs cargo-apk2: cargo-apk ignores `java_sources` and cannot compile the Activity that
# answers open/save for the Rust UI. Any app that declares `java_sources` is built with cargo-apk2.
needs_apk2() {
    needs_saf "$1" && return 0
    local manifest="$ROOT/adapters/$1/Cargo.toml"
    [[ -f "$manifest" ]] && grep -q '^[[:space:]]*java_sources' "$manifest"
}

if needs_apk2 "$APP"; then
    if ! cargo apk2 --help >/dev/null 2>&1; then
        echo "$TITLE's Android file picker needs cargo-apk2 (Java Activity support). Installing it..."
        cargo install cargo-apk2 --locked || fail "Could not install cargo-apk2. Install it manually with: cargo install cargo-apk2 --locked"
    fi
    cargo apk2 build --help >/dev/null 2>&1 || fail "cargo-apk2 is required for $TITLE's Android file picker. Install it with: cargo install cargo-apk2 --locked"
else
    cargo apk build --help >/dev/null 2>&1 || fail "cargo-apk is missing. Install it with: cargo install cargo-apk --locked"
fi

# Prove the packaged APK really carries the Android file bridge the adapter declares. This matters
# because cargo-apk2 silently builds an APK with NO launcher activity (and so one that cannot be
# started from the home screen) when the adapter's activity omits its MAIN/LAUNCHER intent-filter;
# a green Rust build alone would not catch that.
verify_android_bridge() {
    local app="$1" apk="$2"
    needs_apk2 "$app" || return 0
    local manifest="$ROOT/adapters/$app/Cargo.toml"
    [[ -f "$manifest" ]] || manifest="$ROOT/source/$app/apps/$app-android/Cargo.toml"
    [[ -f "$manifest" ]] || { echo "WARNING: no manifest found for '$app'; skipping file-bridge verification." >&2; return 0; }
    local pkg activity launcher
    read -r pkg activity launcher < <(python3 - "$manifest" <<'PY'
import sys, tomllib
from pathlib import Path
data = tomllib.loads(Path(sys.argv[1]).read_text())
android = data["package"]["metadata"]["android"]
acts = android.get("application", {}).get("activity", [])
if isinstance(acts, dict):
    acts = [acts]
name, launches = "", False
for a in acts:
    name = a.get("name") or "android.app.NativeActivity"
    for f in a.get("intent_filter", []):
        if "android.intent.action.MAIN" in f.get("actions", []):
            launches = True
    if name:
        break
print(android["package"], name.lstrip("."), "1" if launches else "0")
PY
)
    [[ -n "$pkg" && -n "$activity" ]] || { echo "WARNING: could not read the manifest for '$app'; skipping file-bridge verification." >&2; return 0; }
    if [[ "$launcher" != "1" ]]; then
        fail "$manifest declares activity '$activity' without a MAIN intent-filter, so the built APK would have no launcher icon. Add [[package.metadata.android.application.activity.intent_filter]]."
    fi
    if command -v aapt2 >/dev/null 2>&1; then
        local badging
        badging="$(aapt2 dump badging "$apk" 2>/dev/null || true)"
        if ! grep -q "launchable-activity: name='$pkg.$activity'" <<<"$badging"; then
            fail "The built APK has no launcher activity '$pkg.$activity' (its manifest is missing the MAIN/LAUNCHER intent-filter), so it could not be started from the home screen."
        fi
    fi
    if ! python3 - "$apk" "$activity" <<'PY'
import sys, zipfile
apk, activity = sys.argv[1], sys.argv[2]
needle = activity.encode()
with zipfile.ZipFile(apk) as z:
    names = z.namelist()
    in_dex = any(n.endswith(".dex") and needle in z.read(n) for n in names)
    libs = [n for n in names if n.startswith("lib/") and n.endswith(".so")]
sys.exit(0 if (in_dex and libs) else 1)
PY
    then
        fail "The built APK is missing the compiled Activity '$activity' or its native library, so the Java SAF file picker is not in the APK."
    fi
    echo "Verified the Android file bridge: $pkg.$activity launches the app and is compiled into the APK."
}

say 2 "Finding Android SDK and NDK (read-only; project files stay under $ROOT)..."
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
[[ -d "$SDK/platforms" ]] || fail "Android SDK platform directory not found: $SDK/platforms. Set ANDROID_HOME to your SDK."
TARGET_SDK="${ARTCRAFT_TARGET_SDK:-35}"
[[ -d "$SDK/platforms/android-$TARGET_SDK" ]] || fail "Android SDK platform android-$TARGET_SDK not found under $SDK/platforms. Install it with sdkmanager or set ARTCRAFT_TARGET_SDK to an installed platform."
[[ -d "$SDK/build-tools" ]] || fail "Android build-tools directory missing under $SDK."
BUILD_TOOLS="${ARTCRAFT_BUILD_TOOLS_VERSION:-$(find "$SDK/build-tools" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1)}"
[[ -n "$BUILD_TOOLS" && -d "$SDK/build-tools/$BUILD_TOOLS" ]] || fail "No usable Android Build Tools installation found."
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${NDK_HOME:-}}}"
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
    NDK="$(find "$SDK/ndk" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -V | tail -n 1 || true)"
fi
[[ -n "$NDK" && -d "$NDK" ]] || fail "No Android NDK found. Install one using Android SDK Manager."
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
export ANDROID_NDK_HOME="$NDK" ANDROID_NDK_ROOT="$NDK" NDK_HOME="$NDK"
NDK_TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[[ -d "$NDK_TOOLCHAIN" ]] || NDK_TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="$NDK_TOOLCHAIN:$SDK/platform-tools:$SDK/build-tools/$BUILD_TOOLS:$PATH"
echo "SDK: $SDK"
echo "Platform: android-$TARGET_SDK"
echo "Build Tools: $BUILD_TOOLS"
echo "NDK: $NDK"
if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx 'aarch64-linux-android'; then
    fail "Rust target is missing. Install it once with: rustup target add aarch64-linux-android"
fi

say 3 "Fetching official source for $TITLE..."
if [[ -e "$SRC" ]]; then
    [[ -d "$SRC/.git" ]] || fail "$SRC exists but is not a Git checkout. Move it aside manually before retrying."
    ORIGIN="$(git -C "$SRC" remote get-url origin 2>/dev/null || true)"
    case "${ORIGIN%.git}" in
        "https://github.com/storytold/$APP") ;;
        *) fail "$SRC has unexpected origin '$ORIGIN'; refusing to reuse or overwrite it." ;;
    esac
    echo "Reusing existing source checkout (including your Android port changes)."
    echo "Commit: $(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "Source is not automatically reset or updated."
else
    git clone --depth 1 "$REPO" "$SRC"
fi

# Upstream `main` is normally green, but a regression can sit there for a while (the upstream
# preset-loader fix landed broken on 2026-10-17 and took its CI red). Each fix-up below is
# guarded: it edits the checkout only while the broken text is still present, and is a silent
# no-op once upstream repairs it, so nothing is frozen or permanently forked. Keep this list tiny
# and delete entries once upstream has shipped the fix.
python3 - "$SRC" "$APP" "$TITLE" <<'PY'
from pathlib import Path
import sys

src, app, title = Path(sys.argv[1]), sys.argv[2], sys.argv[3]


def fix(rel: str, old: str, new: str) -> bool:
    """Replace the single `old` in `rel` with `new`, unless it is already gone or already fixed."""
    path = src / rel
    try:
        text = path.read_text()
    except OSError:
        return False
    if old not in text or new in text or text.count(old) != 1:
        return False
    path.write_text(text.replace(old, new, 1))
    return True


fixed = []
if app == "photocraft":
    # "load each persisted preset set independently" added `export_presets` to the serialised
    # `Persisted` set and to its write path, but not to the read initialiser, so the crate no
    # longer compiles. Fill in the missing field; the code below it already reads it back.
    if fix(
        "crates/engine/src/presets/mod.rs",
        '            recent_documents: take(&mut m, "recent_documents"),\n',
        '            recent_documents: take(&mut m, "recent_documents"),\n'
        '            export_presets: take(&mut m, "export_presets"),\n',
    ):
        fixed.append("crates/engine/src/presets/mod.rs")

if fixed:
    print(f"  Repaired upstream compile errors still present in {title}: {', '.join(fixed)}")
PY

# Phone-layout patches for the app's own source live in patches/<app>/*.patch. Each one is applied
# only when it still applies cleanly; one that is already applied, or that no longer matches a newer
# upstream, is skipped with a notice and never stops the build.
if [[ -d "$ROOT/patches/$APP" ]]; then
    for patch in "$ROOT/patches/$APP"/*.patch; do
        [[ -f "$patch" ]] || continue
        name="$(basename "$patch")"
        if git -C "$SRC" apply --check "$patch" >/dev/null 2>&1; then
            git -C "$SRC" apply "$patch" && echo "Applied patch: $name"
        elif git -C "$SRC" apply --reverse --check "$patch" >/dev/null 2>&1; then
            echo "Patch already applied: $name"
        else
            echo "WARNING: patch $name does not apply to this source; skipped." >&2
        fi
    done
fi

say 4 "Preparing the NativeActivity launcher..."
if [[ -x "adapters/$APP/prepare.sh" ]]; then
    echo "Using app-specific adapter: adapters/$APP/prepare.sh"
    bash "adapters/$APP/prepare.sh" "$APP" "$TITLE" "$SRC" "$MODE"
else
    python3 - "$ROOT" "$SRC" "$APP" "$TITLE" "$TARGET_SDK" "$APPNAME" "$PACKAGENAME" "$APPICON" <<'PY'
from pathlib import Path
import re, shutil, sys, tomllib

root, src_s, app, title, target_sdk, appname, packagename, appicon = sys.argv[1:]
root, src = Path(root), Path(src_s)
# Shared file-association table (Android open/share intent filters), also used by the adapter
# prepare scripts so every launcher advertises the same associations.
sys.path.insert(0, str(root / "lib"))
import file_associations
android_dir = src / "apps" / f"{app}-android"
marker = android_dir / ".artcraft-android-builder-generated"

# Bump this whenever the generated launcher template changes so stale wrappers (which live in the
# source checkout and would otherwise be preserved forever) are regenerated automatically instead
# of failing against a newer app API.
GENERATOR_VERSION = "23"

# A complete adapter supplied by the user wins over auto-detection. This folder is maintained
# inside the builder, while its contents are copied into this source checkout.
custom = root / "adapters" / app
if (custom / "Cargo.toml").is_file() and (custom / "src" / "lib.rs").is_file():
    if android_dir.exists() and not marker.exists():
        raise SystemExit(f"Refusing to overwrite non-builder directory: {android_dir}")
    if android_dir.exists():
        shutil.rmtree(android_dir)
    shutil.copytree(custom, android_dir, ignore=shutil.ignore_patterns("README.md", ".git"))
    # Ship the shared Android system-font module alongside the adapter so its launcher can pull the
    # device's own fonts in (see templates/android/system_fonts.rs). Kept here rather than inside
    # each adapter so the one copy stays in step with the generator.
    shutil.copy2(root / "templates" / "android" / "system_fonts.rs", android_dir / "src" / "system_fonts.rs")
    # The shared Android soft-keyboard bridge, referenced by `mod ime_bridge;` in the adapter.
    shutil.copy2(root / "templates" / "android" / "ime_bridge.rs", android_dir / "src" / "ime_bridge.rs")
    # Advertise the app's file associations (Android open/share intent filters) in the copied
    # manifest, from the same table the generated launchers use.
    file_associations.patch_cargo_toml(android_dir / "Cargo.toml", app)
    marker.write_text(f"{GENERATOR_VERSION}\nGenerated/copied by artcraft-android-builder; custom adapter.\n")
    print(f"Installed custom adapter from {custom}")
    raise SystemExit(0)

if android_dir.exists():
    if marker.is_file():
        if marker.read_text(errors="replace").splitlines()[:1] == [GENERATOR_VERSION]:
            print("Android launcher already generated; preserving it.")
            raise SystemExit(0)
        print("Regenerating the Android launcher for this builder version.")
        shutil.rmtree(android_dir)
    else:
        raise SystemExit(f"Refusing to overwrite {android_dir}: it exists but is not marked as builder-generated. If this is your own adapter, place a complete adapter in adapters/{app}/ and move the directory manually first.")

root_manifest = src / "Cargo.toml"
if not root_manifest.is_file():
    raise SystemExit(f"No workspace Cargo.toml found in {src}")
try:
    ws = tomllib.loads(root_manifest.read_text())
except Exception as e:
    raise SystemExit(f"Cannot parse workspace Cargo.toml: {e}")
if "workspace" not in ws:
    raise SystemExit("Source root is not a Cargo workspace; a custom adapter is required.")
members = ws["workspace"].get("members", [])
if not any("apps/*" in m or m in (f"apps/{app}-android", f"apps/{app}-android/") for m in members):
    raise SystemExit("Workspace does not include apps/*; auto-add is unsafe. Create a custom adapter or update the workspace members explicitly.")

engine_manifest = src / "crates" / "engine" / "Cargo.toml"
ui_manifest = src / "crates" / "ui-egui" / "Cargo.toml"
ui_src = src / "crates" / "ui-egui" / "src"
for p in (engine_manifest, ui_manifest, ui_src / "lib.rs"):
    if not p.exists():
        raise SystemExit(f"Expected shared engine/UI layout is missing: {p.relative_to(src)}. This app needs an app-specific adapter under adapters/{app}/.")

def pkg_name(path: Path) -> str:
    data = tomllib.loads(path.read_text())
    try:
        return data["package"]["name"]
    except KeyError as e:
        raise SystemExit(f"Manifest has no package.name: {path}") from e

engine_pkg = pkg_name(engine_manifest)
ui_pkg = pkg_name(ui_manifest)
ui_root = (ui_src / "lib.rs").read_text(errors="replace")
ui_text = "\n".join(p.read_text(errors="replace") for p in ui_src.rglob("*.rs"))
candidates = set()
for p in ui_src.rglob("*.rs"):
    if p.name.endswith(".rs"):
        text = p.read_text(errors="replace")
        candidates.update(re.findall(r"\bpub\s+(?:struct|enum)\s+([A-Za-z_][A-Za-z0-9]*App)\b", text))

# Most apps expose the conventional shape: a public `<Stem>App` built with
# `<App>::new(Session::new(), Services::default())` that implements `eframe::App` directly. A few
# differ in the constructor, in which crate defines the pieces, or in whether the type is the
# eframe app at all (their desktop `main.rs` wraps an inner type exposing `logic`/`ui`). Record those
# differences here so one launcher template still launches every app in the suite.
SPECIAL = {
    "filmcraft": {"app_type": "FilmcraftApp", "construct": "{app}::new(Session::default())"},
    "pdfcraft": {"construct": "{app}::new()"},
    "effectcraft": {"app_type": "EffectcraftApp", "construct": "{app}::new(Session::new())"},
    "lightcraft": {"app_type": "LightcraftApp", "construct": "{app}::new(Session::new().with_fs(), Services::default())"},
    "figcraft": {"app_type": "FigApp", "construct": "{app}::new(Session::new(), Box::new(NoServices))"},
    "wordcraft": {
        "app_type": "WordApp",
        "construct": "{app}::new(Session::new({engine}::sample::sample_document()), Services::default())",
    },
    "soundcraft": {"app_type": "SoundApp", "construct": "{app}::new({engine}::Engine::default(), None, Services::default())"},
    "cadcraft": {"app_type": "CadApp", "construct": "{app}::new(Session::empty(), Services::default())"},
}
spec = SPECIAL.get(app, {})

# Apps that can use the Android Storage Access Framework (SAF) through the builder-generated
# NativeActivity subclass + JNI bridge (see templates/android/). Each entry supplies the app's
# picker glue. Apps written for asynchronous pickers drive them from `saf_poll`; apps whose file
# API is synchronous use the blocking helpers below, which is safe because `android_main` runs on
# its own Rust thread, not the Java UI thread that shows the system picker. Apps with a full custom
# adapter (adapters/<app>/) take a different path and never reach here. The upstream app crates are
# never modified.
SYNC_SAF_IMPORTS = "use std::sync::atomic::{AtomicU64, Ordering};\nuse std::sync::Arc;"
SYNC_SAF_STATE = '''
pub type SafInbox = ();

#[derive(Default)]
pub struct SafState {
    next_id: AtomicU64,
    mirror: saf::SaveMirror,
}

pub fn saf_new_state() -> Arc<SafState> {
    Arc::new(SafState::default())
}

fn saf_next_id(state: &SafState) -> u64 {
    state.next_id.fetch_add(1, Ordering::Relaxed).wrapping_add(1)
}

/// Open the Android picker and block until the user answers. The picker runs on the Java UI thread
/// while `android_main` runs on its own thread, so waiting here does not freeze the UI. Empty on
/// cancel or error; `pick_blocking` has its own timeout so a stuck picker cannot hang the app.
fn saf_open_paths(bridge: &saf::Bridge, state: &SafState) -> Vec<String> {
    let id = saf_next_id(state);
    match bridge.pick_blocking(id, None, saf::PICK_TIMEOUT) {
        Ok(saf::PickAnswer::Paths(paths)) => paths,
        Ok(saf::PickAnswer::Cancelled) => Vec::new(),
        Err(error) => {
            log::error!("Android open picker: {error}");
            Vec::new()
        }
    }
}

/// Save dialog: the staged app-private destination, watched so the app's own write is mirrored to
/// the chosen SAF document on the next frames.
fn saf_save_path(bridge: &saf::Bridge, state: &SafState, name: &str) -> Option<String> {
    let id = saf_next_id(state);
    match bridge.pick_blocking(id, Some(name), saf::PICK_TIMEOUT) {
        Ok(saf::PickAnswer::Paths(paths)) => {
            let path = paths.into_iter().next();
            if let Some(path) = &path {
                state.mirror.track(id, path);
            }
            path
        }
        Ok(saf::PickAnswer::Cancelled) => None,
        Err(error) => {
            log::error!("Android save picker: {error}");
            None
        }
    }
}

/// Folder dialog: a real directory path on the device's main storage (SAF folders elsewhere cannot
/// be mapped to one), or `None` when cancelled.
fn saf_folder_path(bridge: &saf::Bridge, state: &SafState) -> Option<String> {
    let id = saf_next_id(state);
    match bridge.pick_folder_blocking(id, saf::PICK_TIMEOUT) {
        Ok(saf::PickAnswer::Paths(paths)) => paths.into_iter().next(),
        Ok(saf::PickAnswer::Cancelled) => None,
        Err(error) => {
            log::error!("Android folder picker: {error}");
            None
        }
    }
}
'''
SYNC_SAF_POLL = '''
fn saf_poll(bridge: &saf::Bridge, state: &SafState, _inbox: &SafInbox) {
    state.mirror.sync(bridge);
}
'''
SAF_RECIPES = {
    "designcraft": {
        "activity": "DesignCraftActivity",
        "imports": "use designcraft_ui_egui::{ImportRequest, ImportedFile};\nuse std::collections::HashMap;\nuse std::sync::atomic::{AtomicU64, Ordering};\nuse std::sync::{Arc, Mutex};",
        "state": '''
pub type SafInbox = designcraft_ui_egui::Inbox;

#[derive(Default)]
pub struct SafState {
    next_id: AtomicU64,
    requests: Mutex<HashMap<u64, ImportRequest>>,
    saves: Mutex<HashMap<u64, Vec<u8>>>,
}

pub fn saf_new_state() -> Arc<SafState> {
    Arc::new(SafState::default())
}

fn saf_next_id(state: &SafState) -> u64 {
    state.next_id.fetch_add(1, Ordering::Relaxed).wrapping_add(1)
}

/// Write to the staged private path, then push it through SAF when it was a chosen save
/// destination (a plain private path is a no-op commit).
fn saf_write_and_commit(bridge: &saf::Bridge, path: &str, bytes: &[u8]) -> Result<(), String> {
    let target = std::path::Path::new(path);
    if let Some(parent) = target.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent).map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    }
    std::fs::write(target, bytes).map_err(|error| format!("Could not write {}: {error}", target.display()))?;
    match bridge.commit(path)? {
        status if status == "NONE" || status == "OK" => Ok(()),
        status if status.starts_with("ERROR:") => Err(status.trim_start_matches("ERROR:").trim().to_owned()),
        status => Err(format!("Unexpected Android save result: {status}")),
    }
}
''',
        "services": '''
fn saf_services(bridge: saf::Bridge, state: Arc<SafState>, inbox: SafInbox) -> Services {
    let open_bridge = bridge.clone_ref();
    let save_bridge = bridge.clone_ref();
    let write_bridge = bridge.clone_ref();
    let open_state = Arc::clone(&state);
    let save_state = Arc::clone(&state);
    Services {
        read: Some(Box::new(|path: &str| std::fs::read(path).map_err(|error| format!("Could not read {path}: {error}")))),
        write: Some(Box::new(move |path: &str, bytes: &[u8]| saf_write_and_commit(&write_bridge, path, bytes))),
        open_async: Some(Box::new(move |request: ImportRequest| {
            let id = saf_next_id(&open_state);
            open_state.requests.lock().unwrap_or_else(|error| error.into_inner()).insert(id, request);
            if let Err(error) = open_bridge.request_open(id, false) {
                log::error!("Could not start the Android open picker: {error}");
                open_state.requests.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
        })),
        // DesignCraft's `DownloadFn` returns a `Result`, so report a picker that will not start
        // instead of dropping the error (older sources returned `()` and only logged it).
        download: Some(Box::new(move |name: &str, bytes: &[u8]| {
            let id = saf_next_id(&save_state);
            save_state.saves.lock().unwrap_or_else(|error| error.into_inner()).insert(id, bytes.to_vec());
            if let Err(error) = save_bridge.request_save(id, name) {
                log::error!("Could not start the Android save picker: {error}");
                save_state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
                return Err(error);
            }
            Ok(())
        })),
        inbox: Some(inbox),
        ..Services::default()
    }
}
''',
        "poll": '''
fn saf_poll(bridge: &saf::Bridge, state: &SafState, inbox: &SafInbox) {
    for _ in 0..16 {
        let raw = match bridge.poll() {
            Ok(Some(raw)) => raw,
            Ok(None) => break,
            Err(error) => {
                log::error!("Could not poll the Android file picker: {error}");
                break;
            }
        };
        let value: serde_json::Value = match serde_json::from_str(&raw) {
            Ok(value) => value,
            Err(error) => {
                log::error!("Ignoring a malformed Android picker result ({error}): {raw}");
                continue;
            }
        };
        let Some(id) = value.get("id").and_then(serde_json::Value::as_u64) else { continue };
        let kind = value.get("kind").and_then(serde_json::Value::as_str).unwrap_or_default();
        let status = value.get("status").and_then(serde_json::Value::as_str).unwrap_or("error");
        match (kind, status) {
            ("open", "ok") => {
                let Some(request) = state.requests.lock().unwrap_or_else(|error| error.into_inner()).remove(&id) else { continue };
                let paths: Vec<String> = value
                    .get("paths")
                    .and_then(serde_json::Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|entry| entry.as_str().map(str::to_owned))
                    .collect();
                for path in paths {
                    match std::fs::read(&path) {
                        Ok(bytes) => {
                            let name = std::path::Path::new(&path)
                                .file_name()
                                .map(|name| name.to_string_lossy().into_owned())
                                .unwrap_or_else(|| "imported-file".to_owned());
                            inbox.lock().unwrap_or_else(|error| error.into_inner()).push(ImportedFile { request: request.clone(), name, bytes });
                        }
                        Err(error) => log::error!("Could not read the picked file {path}: {error}"),
                    }
                }
            }
            ("save", "ok") => {
                let bytes = state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
                if let Some(bytes) = bytes {
                    match value.get("path").and_then(serde_json::Value::as_str) {
                        Some(path) => {
                            if let Err(error) = saf_write_and_commit(bridge, path, &bytes) {
                                log::error!("Could not write the saved file: {error}");
                            }
                        }
                        None => log::error!("Android save picker returned no destination path"),
                    }
                }
            }
            ("open", "cancel") | ("save", "cancel") => {
                state.requests.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
                state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
            _ => {
                if let Some(message) = value.get("message").and_then(serde_json::Value::as_str) {
                    log::error!("Android file picker error: {message}");
                }
                state.requests.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
                state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
        }
    }
}
''',
    },
    "deckcraft": {
        "activity": "DeckCraftActivity",
        "imports": "mod audio;\nuse deckcraft_ui_egui::{InboxEvent, InboxFile};\nuse std::collections::HashMap;\nuse std::sync::atomic::{AtomicU64, Ordering};\nuse std::sync::{Arc, Mutex};",
        "state": '''
pub type SafInbox = deckcraft_ui_egui::Inbox;

#[derive(Default)]
pub struct SafState {
    next_id: AtomicU64,
    saves: Mutex<HashMap<u64, Vec<u8>>>,
}

pub fn saf_new_state() -> Arc<SafState> {
    Arc::new(SafState::default())
}

fn saf_next_id(state: &SafState) -> u64 {
    state.next_id.fetch_add(1, Ordering::Relaxed).wrapping_add(1)
}

/// Write to the staged private path, then push it through SAF when it was a chosen save
/// destination (a plain private path is a no-op commit).
fn saf_write_and_commit(bridge: &saf::Bridge, path: &str, bytes: &[u8]) -> Result<(), String> {
    let target = std::path::Path::new(path);
    if let Some(parent) = target.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent).map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    }
    std::fs::write(target, bytes).map_err(|error| format!("Could not write {}: {error}", target.display()))?;
    match bridge.commit(path)? {
        status if status == "NONE" || status == "OK" => Ok(()),
        status if status.starts_with("ERROR:") => Err(status.trim_start_matches("ERROR:").trim().to_owned()),
        status => Err(format!("Unexpected Android save result: {status}")),
    }
}
''',
        "services": '''
fn saf_services(bridge: saf::Bridge, state: Arc<SafState>, inbox: SafInbox) -> Services {
    let open_bridge = bridge.clone_ref();
    let save_bridge = bridge.clone_ref();
    let write_bridge = bridge.clone_ref();
    let open_inbox = inbox.clone();
    let save_state = Arc::clone(&state);
    Services {
        read: Some(Box::new(|path: &str| std::fs::read(path).map_err(|error| format!("Could not read {path}: {error}")))),
        write: Some(Box::new(move |path: &str, bytes: &[u8]| saf_write_and_commit(&write_bridge, path, bytes))),
        open_async: Some(Box::new(move |_purpose: &str, id: u64| {
            // DeckCraft hands us the request id it already tracks; echo it back on completion.
            if let Err(error) = open_bridge.request_open(id, false) {
                log::error!("Could not start the Android open picker: {error}");
                open_inbox.lock().unwrap_or_else(|error| error.into_inner()).push(InboxEvent::Cancelled { id });
            }
        })),
        download: Some(Box::new(move |name: &str, bytes: &[u8]| {
            let id = saf_next_id(&save_state);
            save_state.saves.lock().unwrap_or_else(|error| error.into_inner()).insert(id, bytes.to_vec());
            if let Err(error) = save_bridge.request_save(id, name) {
                log::error!("Could not start the Android save picker: {error}");
                save_state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
        })),
        inbox: Some(inbox),
        // Media playback is clocked by the cpal output device (apps/deckcraft/src/audio.rs), exactly
        // as on the desktop; a backend that fails to initialise degrades to silent playback.
        audio_out: std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            Box::new(audio::CpalOut::default()) as Box<dyn deckcraft_media::AudioOut>
        })).ok(),
        ..Services::default()
    }
}
''',
        "poll": '''
fn saf_poll(bridge: &saf::Bridge, state: &SafState, inbox: &SafInbox) {
    for _ in 0..16 {
        let raw = match bridge.poll() {
            Ok(Some(raw)) => raw,
            Ok(None) => break,
            Err(error) => {
                log::error!("Could not poll the Android file picker: {error}");
                break;
            }
        };
        let value: serde_json::Value = match serde_json::from_str(&raw) {
            Ok(value) => value,
            Err(error) => {
                log::error!("Ignoring a malformed Android picker result ({error}): {raw}");
                continue;
            }
        };
        let Some(id) = value.get("id").and_then(serde_json::Value::as_u64) else { continue };
        let kind = value.get("kind").and_then(serde_json::Value::as_str).unwrap_or_default();
        let status = value.get("status").and_then(serde_json::Value::as_str).unwrap_or("error");
        match (kind, status) {
            ("open", "ok") => {
                let paths: Vec<String> = value
                    .get("paths")
                    .and_then(serde_json::Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|entry| entry.as_str().map(str::to_owned))
                    .collect();
                for path in paths {
                    match std::fs::read(&path) {
                        Ok(bytes) => {
                            let name = std::path::Path::new(&path)
                                .file_name()
                                .map(|name| name.to_string_lossy().into_owned())
                                .unwrap_or_else(|| "imported-file".to_owned());
                            inbox.lock().unwrap_or_else(|error| error.into_inner()).push(InboxEvent::File(InboxFile { id, name, bytes }));
                        }
                        Err(error) => log::error!("Could not read the picked file {path}: {error}"),
                    }
                }
            }
            ("open", "cancel") => {
                inbox.lock().unwrap_or_else(|error| error.into_inner()).push(InboxEvent::Cancelled { id });
            }
            ("save", "ok") => {
                let bytes = state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
                if let Some(bytes) = bytes {
                    match value.get("path").and_then(serde_json::Value::as_str) {
                        Some(path) => {
                            if let Err(error) = saf_write_and_commit(bridge, path, &bytes) {
                                log::error!("Could not write the saved file: {error}");
                            }
                        }
                        None => log::error!("Android save picker returned no destination path"),
                    }
                }
            }
            ("save", "cancel") => {
                state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
            _ => {
                if kind == "open" {
                    inbox.lock().unwrap_or_else(|error| error.into_inner()).push(InboxEvent::Cancelled { id });
                }
                if let Some(message) = value.get("message").and_then(serde_json::Value::as_str) {
                    log::error!("Android file picker error: {message}");
                }
                state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
        }
    }
}
''',
    },
    "gridcraft": {
        "activity": "GridCraftActivity",
        "imports": "use std::collections::HashMap;\nuse std::sync::atomic::{AtomicU64, Ordering};\nuse std::sync::{Arc, Mutex};",
        "state": '''
pub type SafInbox = gridcraft_ui_egui::Inbox;

#[derive(Default)]
pub struct SafState {
    next_id: AtomicU64,
    /// Which inbox each open request should deliver to: the app's shared inbox for File › Open,
    /// or a dialog's private inbox for its picture picker.
    opens: Mutex<HashMap<u64, SafInbox>>,
    saves: Mutex<HashMap<u64, Vec<u8>>>,
}

pub fn saf_new_state() -> Arc<SafState> {
    Arc::new(SafState::default())
}

fn saf_next_id(state: &SafState) -> u64 {
    state.next_id.fetch_add(1, Ordering::Relaxed).wrapping_add(1)
}

/// Write to the staged private path, then push it through SAF when it was a chosen save
/// destination (a plain private path is a no-op commit).
fn saf_write_and_commit(bridge: &saf::Bridge, path: &str, bytes: &[u8]) -> Result<(), String> {
    let target = std::path::Path::new(path);
    if let Some(parent) = target.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent).map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    }
    std::fs::write(target, bytes).map_err(|error| format!("Could not write {}: {error}", target.display()))?;
    match bridge.commit(path)? {
        status if status == "NONE" || status == "OK" => Ok(()),
        status if status.starts_with("ERROR:") => Err(status.trim_start_matches("ERROR:").trim().to_owned()),
        status => Err(format!("Unexpected Android save result: {status}")),
    }
}
''',
        "services": '''
fn saf_services(bridge: saf::Bridge, state: Arc<SafState>, inbox: SafInbox) -> Services {
    let open_bridge = bridge.clone_ref();
    let picture_bridge = bridge.clone_ref();
    let save_bridge = bridge.clone_ref();
    let open_state = Arc::clone(&state);
    let picture_state = Arc::clone(&state);
    let save_state = Arc::clone(&state);
    let open_inbox = inbox.clone();
    Services {
        open_async: Some(Box::new(move || {
            let id = saf_next_id(&open_state);
            open_state.opens.lock().unwrap_or_else(|error| error.into_inner()).insert(id, open_inbox.clone());
            if let Err(error) = open_bridge.request_open(id, false) {
                log::error!("Could not start the Android open picker: {error}");
                open_state.opens.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
        })),
        pick_picture_async: Some(Box::new(move |target: SafInbox| {
            let id = saf_next_id(&picture_state);
            picture_state.opens.lock().unwrap_or_else(|error| error.into_inner()).insert(id, target);
            if let Err(error) = picture_bridge.request_open(id, false) {
                log::error!("Could not start the Android picture picker: {error}");
                picture_state.opens.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
        })),
        download: Some(Box::new(move |name: &str, bytes: &[u8]| {
            let id = saf_next_id(&save_state);
            save_state.saves.lock().unwrap_or_else(|error| error.into_inner()).insert(id, bytes.to_vec());
            if let Err(error) = save_bridge.request_save(id, name) {
                log::error!("Could not start the Android save picker: {error}");
                save_state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
        })),
        inbox: Some(inbox),
        ..Services::default()
    }
}
''',
        "poll": '''
fn saf_poll(bridge: &saf::Bridge, state: &SafState, _inbox: &SafInbox) {
    for _ in 0..16 {
        let raw = match bridge.poll() {
            Ok(Some(raw)) => raw,
            Ok(None) => break,
            Err(error) => {
                log::error!("Could not poll the Android file picker: {error}");
                break;
            }
        };
        let value: serde_json::Value = match serde_json::from_str(&raw) {
            Ok(value) => value,
            Err(error) => {
                log::error!("Ignoring a malformed Android picker result ({error}): {raw}");
                continue;
            }
        };
        let Some(id) = value.get("id").and_then(serde_json::Value::as_u64) else { continue };
        let kind = value.get("kind").and_then(serde_json::Value::as_str).unwrap_or_default();
        let status = value.get("status").and_then(serde_json::Value::as_str).unwrap_or("error");
        match (kind, status) {
            ("open", "ok") => {
                let target = state.opens.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
                let paths: Vec<String> = value
                    .get("paths")
                    .and_then(serde_json::Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|entry| entry.as_str().map(str::to_owned))
                    .collect();
                if let Some(target) = target {
                    for path in paths {
                        match std::fs::read(&path) {
                            Ok(bytes) => {
                                let name = std::path::Path::new(&path)
                                    .file_name()
                                    .map(|name| name.to_string_lossy().into_owned())
                                    .unwrap_or_else(|| "imported-file".to_owned());
                                target.lock().unwrap_or_else(|error| error.into_inner()).push((name, bytes));
                            }
                            Err(error) => log::error!("Could not read the picked file {path}: {error}"),
                        }
                    }
                }
            }
            ("open", "cancel") => {
                state.opens.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
            ("save", "ok") => {
                let bytes = state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
                if let Some(bytes) = bytes {
                    match value.get("path").and_then(serde_json::Value::as_str) {
                        Some(path) => {
                            if let Err(error) = saf_write_and_commit(bridge, path, &bytes) {
                                log::error!("Could not write the saved file: {error}");
                            }
                        }
                        None => log::error!("Android save picker returned no destination path"),
                    }
                }
            }
            ("save", "cancel") => {
                state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
            _ => {
                if kind == "open" {
                    state.opens.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
                }
                if let Some(message) = value.get("message").and_then(serde_json::Value::as_str) {
                    log::error!("Android file picker error: {message}");
                }
                state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
        }
    }
}
''',
    },
    "wordcraft": {
        "activity": "WordCraftActivity",
        "imports": "use std::collections::HashMap;\nuse std::sync::atomic::{AtomicU64, Ordering};\nuse std::sync::{Arc, Mutex};",
        "state": '''
pub type SafInbox = wordcraft_ui_egui::Inbox;

#[derive(Default)]
pub struct SafState {
    next_id: AtomicU64,
    saves: Mutex<HashMap<u64, Vec<u8>>>,
}

pub fn saf_new_state() -> Arc<SafState> {
    Arc::new(SafState::default())
}

fn saf_next_id(state: &SafState) -> u64 {
    state.next_id.fetch_add(1, Ordering::Relaxed).wrapping_add(1)
}

/// Write to the staged private path, then push it through SAF when it was a chosen save
/// destination (a plain private path is a no-op commit).
fn saf_write_and_commit(bridge: &saf::Bridge, path: &str, bytes: &[u8]) -> Result<(), String> {
    let target = std::path::Path::new(path);
    if let Some(parent) = target.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent).map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    }
    std::fs::write(target, bytes).map_err(|error| format!("Could not write {}: {error}", target.display()))?;
    match bridge.commit(path)? {
        status if status == "NONE" || status == "OK" => Ok(()),
        status if status.starts_with("ERROR:") => Err(status.trim_start_matches("ERROR:").trim().to_owned()),
        status => Err(format!("Unexpected Android save result: {status}")),
    }
}
''',
        "services": '''
fn saf_services(bridge: saf::Bridge, state: Arc<SafState>, inbox: SafInbox) -> Services {
    let open_bridge = bridge.clone_ref();
    let save_bridge = bridge.clone_ref();
    let open_state = Arc::clone(&state);
    let save_state = Arc::clone(&state);
    Services {
        open_async: Some(Box::new(move |_purpose: &str| {
            let id = saf_next_id(&open_state);
            if let Err(error) = open_bridge.request_open(id, false) {
                log::error!("Could not start the Android open picker: {error}");
            }
        })),
        download: Some(Box::new(move |name: &str, bytes: &[u8]| {
            let id = saf_next_id(&save_state);
            save_state.saves.lock().unwrap_or_else(|error| error.into_inner()).insert(id, bytes.to_vec());
            if let Err(error) = save_bridge.request_save(id, name) {
                log::error!("Could not start the Android save picker: {error}");
                save_state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
                return Err(error);
            }
            Ok(())
        })),
        inbox: Some(inbox),
        ..Services::default()
    }
}
''',
        "poll": '''
fn saf_poll(bridge: &saf::Bridge, state: &SafState, inbox: &SafInbox) {
    for _ in 0..16 {
        let raw = match bridge.poll() {
            Ok(Some(raw)) => raw,
            Ok(None) => break,
            Err(error) => {
                log::error!("Could not poll the Android file picker: {error}");
                break;
            }
        };
        let value: serde_json::Value = match serde_json::from_str(&raw) {
            Ok(value) => value,
            Err(error) => {
                log::error!("Ignoring a malformed Android picker result ({error}): {raw}");
                continue;
            }
        };
        let Some(id) = value.get("id").and_then(serde_json::Value::as_u64) else { continue };
        let kind = value.get("kind").and_then(serde_json::Value::as_str).unwrap_or_default();
        let status = value.get("status").and_then(serde_json::Value::as_str).unwrap_or("error");
        match (kind, status) {
            ("open", "ok") => {
                let paths: Vec<String> = value
                    .get("paths")
                    .and_then(serde_json::Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|entry| entry.as_str().map(str::to_owned))
                    .collect();
                for path in paths {
                    match std::fs::read(&path) {
                        Ok(bytes) => {
                            let name = std::path::Path::new(&path)
                                .file_name()
                                .map(|name| name.to_string_lossy().into_owned())
                                .unwrap_or_else(|| "imported-file".to_owned());
                            inbox.lock().unwrap_or_else(|error| error.into_inner()).push((name, bytes));
                        }
                        Err(error) => log::error!("Could not read the picked file {path}: {error}"),
                    }
                }
            }
            ("open", "cancel") => {}
            ("save", "ok") => {
                let bytes = state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
                if let Some(bytes) = bytes {
                    match value.get("path").and_then(serde_json::Value::as_str) {
                        Some(path) => {
                            if let Err(error) = saf_write_and_commit(bridge, path, &bytes) {
                                log::error!("Could not write the saved file: {error}");
                            }
                        }
                        None => log::error!("Android save picker returned no destination path"),
                    }
                }
            }
            ("save", "cancel") => {
                state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
            _ => {
                if let Some(message) = value.get("message").and_then(serde_json::Value::as_str) {
                    log::error!("Android file picker error: {message}");
                }
                state.saves.lock().unwrap_or_else(|error| error.into_inner()).remove(&id);
            }
        }
    }
}
''',
    },
    # ---- Synchronous file-dialog apps: the app asks for a path and continues at once. ----
    "effectcraft": {
        "activity": "EffectCraftActivity",
        "imports": "use effectcraft_ui_egui::Hooks;\nmod audio_out;\n" + SYNC_SAF_IMPORTS,
        "state": SYNC_SAF_STATE + '''
/// Open the picker allowing several files at once (imports take a list); empty on cancel or error.
fn saf_open_paths_many(bridge: &saf::Bridge, state: &SafState) -> Vec<String> {
    let id = saf_next_id(state);
    match bridge.pick_open_blocking(id, true, saf::PICK_TIMEOUT) {
        Ok(saf::PickAnswer::Paths(paths)) => paths,
        Ok(saf::PickAnswer::Cancelled) => Vec::new(),
        Err(error) => {
            log::error!("Android open picker: {error}");
            Vec::new()
        }
    }
}
''',
        "services": '''
/// Show a native file dialog without blocking the frame loop: the dialog runs on a worker thread
/// and answers through `done`, which the app may call from any thread. Blocking on the frame thread
/// instead stalls `AndroidApp::poll_events`, which Android's lifecycle callbacks wait on, so the
/// picker's `onPause` never returns and the system kills the app with an input-dispatch ANR;
/// `Hooks::file_dialog_async` exists for exactly this (#511).
fn saf_dialog_async(bridge: saf::Bridge, state: Arc<SafState>, dialog: effectcraft_ui_egui::FileDialog, done: effectcraft_ui_egui::DialogDone) {
    std::thread::spawn(move || {
        use effectcraft_ui_egui::FileDialog;
        let paths = match dialog {
            FileDialog::Open { many: true, .. } => saf_open_paths_many(&bridge, &state),
            FileDialog::Open { .. } | FileDialog::OpenProject => {
                saf_open_paths(&bridge, &state).into_iter().take(1).collect()
            }
            FileDialog::Folder => saf_folder_path(&bridge, &state).into_iter().collect(),
            FileDialog::Save { default, .. } => saf_save_path(&bridge, &state, &default).into_iter().collect(),
        };
        done(paths);
    });
}

fn saf_hooks(bridge: saf::Bridge, state: Arc<SafState>, _inbox: SafInbox) -> Hooks {
    let dialog_bridge = bridge.clone_ref();
    let dialog_state = Arc::clone(&state);
    let files_bridge = bridge.clone_ref();
    let files_state = Arc::clone(&state);
    let folder_bridge = bridge.clone_ref();
    let folder_state = Arc::clone(&state);
    let project_bridge = bridge.clone_ref();
    let project_state = Arc::clone(&state);
    let save_bridge = bridge.clone_ref();
    let save_state = Arc::clone(&state);
    let save_file_bridge = bridge.clone_ref();
    let save_file_state = Arc::clone(&state);
    Hooks {
        file_dialog_async: Some(Box::new(move |dialog: effectcraft_ui_egui::FileDialog, done: effectcraft_ui_egui::DialogDone| saf_dialog_async(dialog_bridge.clone_ref(), Arc::clone(&dialog_state), dialog, done))),
        pick_files: Some(Box::new(move |_exts: &[&str]| saf_open_paths(&files_bridge, &files_state))),
        pick_folder: Some(Box::new(move || saf_folder_path(&folder_bridge, &folder_state))),
        pick_open_project: Some(Box::new(move || saf_open_paths(&project_bridge, &project_state).into_iter().next())),
        pick_save: Some(Box::new(move |name: &str| saf_save_path(&save_bridge, &save_state, name))),
        pick_save_file: Some(Box::new(move |default: &str, _ext: &str| saf_save_path(&save_file_bridge, &save_file_state, default))),
        ..Hooks::default()
    }
}
''',
        "poll": SYNC_SAF_POLL,
        "construct_expr": "EffectcraftApp::new(Session::new())",
        "post_construct": "    inner.hooks = saf_hooks(saf_bridge.clone_ref(), std::sync::Arc::clone(&saf_state), saf_inbox.clone());\n    inner.hooks.audio_device = Some(Box::new(|out: &effectcraft_ui_egui::audio::AudioOutput| std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| audio_out::open(out))).ok().flatten()));\n    inner.hooks.audio_devices = Some(Box::new(|| std::panic::catch_unwind(std::panic::AssertUnwindSafe(audio_out::devices)).unwrap_or_default()));\n",
    },
    "filmcraft": {
        "activity": "FilmCraftActivity",
        "imports": "use filmcraft_ui_egui::HostHooks;\nmod audio;\n" + SYNC_SAF_IMPORTS,
        "state": SYNC_SAF_STATE,
        "services": '''
/// Show a native file dialog without blocking the frame loop: the app gets the receiver, keeps
/// running its frames and runs the continuation once this worker thread answers. Blocking on the
/// frame thread instead stalls `AndroidApp::poll_events`, which Android's lifecycle callbacks wait
/// on, so the picker's `onPause` never returns and the system kills the app with an input-dispatch
/// ANR (native_dialogs.rs exists for exactly this; see its module docs).
fn saf_dialog_async(bridge: saf::Bridge, state: Arc<SafState>, dialog: filmcraft_ui_egui::native_dialogs::FileDialog) -> std::sync::mpsc::Receiver<Vec<String>> {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        use filmcraft_ui_egui::native_dialogs::FileDialog;
        let paths = match dialog {
            FileDialog::OpenFiles { .. } => saf_open_paths(&bridge, &state),
            FileDialog::OpenFile { .. } | FileDialog::OpenProject | FileDialog::Relink { .. } => {
                saf_open_paths(&bridge, &state).into_iter().take(1).collect()
            }
            FileDialog::SaveProject { name } => saf_save_path(&bridge, &state, &name).into_iter().collect(),
            FileDialog::SaveAs { name, .. } => saf_save_path(&bridge, &state, &name).into_iter().collect(),
            FileDialog::Folder { .. } => saf_folder_path(&bridge, &state).into_iter().collect(),
        };
        // Sending fails only when the app dropped the dialog meanwhile, so the answer is moot.
        let _ = sender.send(paths);
    });
    receiver
}

fn saf_hooks(bridge: saf::Bridge, state: Arc<SafState>, _inbox: SafInbox) -> HostHooks {
    let dialog_bridge = bridge.clone_ref();
    let dialog_state = Arc::clone(&state);
    let files_bridge = bridge.clone_ref();
    let files_state = Arc::clone(&state);
    let folder_bridge = bridge.clone_ref();
    let folder_state = Arc::clone(&state);
    let folder_at_bridge = bridge.clone_ref();
    let folder_at_state = Arc::clone(&state);
    let project_bridge = bridge.clone_ref();
    let project_state = Arc::clone(&state);
    let save_bridge = bridge.clone_ref();
    let save_state = Arc::clone(&state);
    let save_as_bridge = bridge.clone_ref();
    let save_as_state = Arc::clone(&state);
    let open_file_bridge = bridge.clone_ref();
    let open_file_state = Arc::clone(&state);
    HostHooks {
        run_dialog: Some(Box::new(move |dialog: filmcraft_ui_egui::native_dialogs::FileDialog| saf_dialog_async(dialog_bridge.clone_ref(), Arc::clone(&dialog_state), dialog))),
        pick_files: Some(Box::new(move |_exts: &[&str]| saf_open_paths(&files_bridge, &files_state))),
        pick_folder: Some(Box::new(move || saf_folder_path(&folder_bridge, &folder_state))),
        pick_folder_at: Some(Box::new(move |_start: &str| saf_folder_path(&folder_at_bridge, &folder_at_state))),
        pick_open_project: Some(Box::new(move || saf_open_paths(&project_bridge, &project_state).into_iter().next())),
        pick_save: Some(Box::new(move |name: &str| saf_save_path(&save_bridge, &save_state, name))),
        pick_save_as: Some(Box::new(move |_filter: &str, _exts: &[&str], name: &str| saf_save_path(&save_as_bridge, &save_as_state, name))),
        pick_open_file: Some(Box::new(move |_filter: &str, _exts: &[&str]| saf_open_paths(&open_file_bridge, &open_file_state).into_iter().next())),
        ..HostHooks::default()
    }
}
''',
        "poll": SYNC_SAF_POLL,
        "construct_expr": "FilmcraftApp::new(Session::default())",
        "post_construct": "    inner.hooks = saf_hooks(saf_bridge.clone_ref(), std::sync::Arc::clone(&saf_state), saf_inbox.clone());\n    inner.audio = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| Box::new(audio::CpalOut::new()) as Box<dyn filmcraft_ui_egui::AudioOut>)).ok();\n",
    },
    "lightcraft": {
        "activity": "LightCraftActivity",
        "imports": SYNC_SAF_IMPORTS,
        "state": SYNC_SAF_STATE + '''
/// Write to the staged private path, then push it through SAF when it was a chosen destination
/// (an ordinary private path commits nothing). LightCraft writes exports through `Services::write`.
fn saf_write_and_commit(bridge: &saf::Bridge, path: &str, bytes: &[u8]) -> Result<(), String> {
    let target = std::path::Path::new(path);
    if let Some(parent) = target.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent).map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    }
    std::fs::write(target, bytes).map_err(|error| format!("Could not write {}: {error}", target.display()))?;
    match bridge.commit(path)? {
        status if status == "NONE" || status == "OK" => Ok(()),
        status if status.starts_with("ERROR:") => Err(status.trim_start_matches("ERROR:").trim().to_owned()),
        status => Err(format!("Unexpected Android save result: {status}")),
    }
}

/// Open the picker allowing several files at once (imports take a list); empty on cancel or error.
fn saf_open_paths_many(bridge: &saf::Bridge, state: &SafState) -> Vec<String> {
    let id = saf_next_id(state);
    match bridge.pick_open_blocking(id, true, saf::PICK_TIMEOUT) {
        Ok(saf::PickAnswer::Paths(paths)) => paths,
        Ok(saf::PickAnswer::Cancelled) => Vec::new(),
        Err(error) => {
            log::error!("Android open picker: {error}");
            Vec::new()
        }
    }
}
''',
        "services": '''
/// Start the picker for a command's dialog off the UI thread and answer through a channel, which
/// the app polls (`lightcraft_ui_egui::pick` was written for exactly this, #191). Blocking the
/// frame thread instead stalls `AndroidApp::poll_events`, which Android's lifecycle callbacks wait
/// on, so the picker's `onPause` never returns and the system kills the app with an input-dispatch
/// ANR.
fn saf_services(bridge: saf::Bridge, state: Arc<SafState>, _inbox: SafInbox) -> Services {
    let picker_bridge = bridge.clone_ref();
    let picker_state = Arc::clone(&state);
    let write_bridge = bridge.clone_ref();
    let files_bridge = bridge.clone_ref();
    let files_state = Arc::clone(&state);
    let denoise_bridge = bridge.clone_ref();
    let denoise_state = Arc::clone(&state);
    let model_bridge = bridge.clone_ref();
    let model_state = Arc::clone(&state);
    let presets_bridge = bridge.clone_ref();
    let presets_state = Arc::clone(&state);
    let tracklog_bridge = bridge.clone_ref();
    let tracklog_state = Arc::clone(&state);
    let display_bridge = bridge.clone_ref();
    let display_state = Arc::clone(&state);
    let keywords_bridge = bridge.clone_ref();
    let keywords_state = Arc::clone(&state);
    let curves_bridge = bridge.clone_ref();
    let curves_state = Arc::clone(&state);
    let catalog_bridge = bridge.clone_ref();
    let catalog_state = Arc::clone(&state);
    let folder_bridge = bridge.clone_ref();
    let folder_state = Arc::clone(&state);
    let save_preset_bridge = bridge.clone_ref();
    let save_preset_state = Arc::clone(&state);
    let save_keywords_bridge = bridge.clone_ref();
    let save_keywords_state = Arc::clone(&state);
    let save_curves_bridge = bridge.clone_ref();
    let save_curves_state = Arc::clone(&state);
    Services {
        picker: Some(Box::new(move |request: lightcraft_ui_egui::pick::PickRequest| {
            let bridge = picker_bridge.clone_ref();
            let state = Arc::clone(&picker_state);
            let (sender, receiver) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                use lightcraft_ui_egui::pick::PickKind;
                let paths = match request.kind {
                    PickKind::Files => saf_open_paths_many(&bridge, &state),
                    PickKind::File => saf_open_paths(&bridge, &state).into_iter().take(1).collect(),
                    PickKind::Folder => saf_folder_path(&bridge, &state).into_iter().collect(),
                    PickKind::Save => {
                        let name = request.file_name.clone().unwrap_or_default();
                        saf_save_path(&bridge, &state, &name).into_iter().collect()
                    }
                };
                let _ = sender.send(paths);
            });
            Ok(receiver)
        })),
        pick_files: Some(Box::new(move || saf_open_paths(&files_bridge, &files_state))),
        pick_denoise_model: Some(Box::new(move || saf_open_paths(&denoise_bridge, &denoise_state))),
        pick_model_file: Some(Box::new(move || saf_open_paths(&model_bridge, &model_state))),
        pick_preset_files: Some(Box::new(move || saf_open_paths(&presets_bridge, &presets_state))),
        pick_tracklog: Some(Box::new(move || saf_open_paths(&tracklog_bridge, &tracklog_state))),
        pick_display_profile: Some(Box::new(move || saf_open_paths(&display_bridge, &display_state))),
        pick_keyword_list: Some(Box::new(move || saf_open_paths(&keywords_bridge, &keywords_state))),
        pick_curve_preset_files: Some(Box::new(move || saf_open_paths(&curves_bridge, &curves_state))),
        pick_lightroom_catalog: Some(Box::new(move || saf_folder_path(&catalog_bridge, &catalog_state))),
        pick_folder: Some(Box::new(move || saf_folder_path(&folder_bridge, &folder_state))),
        save_preset_file: Some(Box::new(move |name: &str| saf_save_path(&save_preset_bridge, &save_preset_state, name))),
        save_keyword_list: Some(Box::new(move |name: &str| saf_save_path(&save_keywords_bridge, &save_keywords_state, name))),
        save_curve_preset_file: Some(Box::new(move |name: &str| saf_save_path(&save_curves_bridge, &save_curves_state, name))),
        write: Some(Box::new(move |path: &str, bytes: &[u8]| saf_write_and_commit(&write_bridge, path, bytes))),
        ..Services::default()
    }
}
''',
        "poll": SYNC_SAF_POLL,
    },
    "cadcraft": {
        "activity": "CadCraftActivity",
        "imports": SYNC_SAF_IMPORTS,
        "state": SYNC_SAF_STATE,
        "services": '''
fn saf_services(bridge: saf::Bridge, state: Arc<SafState>, _inbox: SafInbox) -> Services {
    let open_bridge = bridge.clone_ref();
    let open_state = Arc::clone(&state);
    let save_bridge = bridge.clone_ref();
    let save_state = Arc::clone(&state);
    Services {
        pick_open: Some(Box::new(move || saf_open_paths(&open_bridge, &open_state).into_iter().next())),
        pick_save: Some(Box::new(move |name: &str| saf_save_path(&save_bridge, &save_state, name))),
    }
}
''',
        "poll": SYNC_SAF_POLL,
    },
    "soundcraft": {
        "activity": "SoundCraftActivity",
        "imports": SYNC_SAF_IMPORTS,
        "state": SYNC_SAF_STATE,
        "services": '''
fn saf_services(bridge: saf::Bridge, state: Arc<SafState>, _inbox: SafInbox) -> Services {
    let open_bridge = bridge.clone_ref();
    let open_state = Arc::clone(&state);
    let save_bridge = bridge.clone_ref();
    let save_state = Arc::clone(&state);
    let folder_bridge = bridge.clone_ref();
    let folder_state = Arc::clone(&state);
    Services {
        pick_open: Some(Box::new(move |_title: &str, _exts: &[&str]| saf_open_paths(&open_bridge, &open_state).into_iter().next())),
        pick_save: Some(Box::new(move |_title: &str, name: &str| saf_save_path(&save_bridge, &save_state, name))),
        pick_folder: Some(Box::new(move |_title: &str| saf_folder_path(&folder_bridge, &folder_state))),
    }
}
''',
        "poll": SYNC_SAF_POLL,
    },
    # ---- rfd-driven app: pdfcraft calls rfd::AsyncFileDialog directly (no Services to inject). ----
    # The vendored rfd's Android backend routes its async pickers through rfd::artcraft_saf, which
    # the launcher below drives: a worker thread blocks on the rfd future while the launcher's
    # per-frame poll delivers the system picker's answer.
    "pdfcraft": {
        "activity": "PdfCraftActivity",
        "imports": SYNC_SAF_IMPORTS,
        "state": SYNC_SAF_STATE,
        "services": "",
        "poll": '''
fn saf_poll(bridge: &saf::Bridge, state: &SafState, _inbox: &SafInbox) {
    for _ in 0..16 {
        let raw = match bridge.poll() {
            Ok(Some(raw)) => raw,
            Ok(None) => break,
            Err(error) => {
                log::error!("Could not poll the Android file picker: {error}");
                break;
            }
        };
        let value: serde_json::Value = match serde_json::from_str(&raw) {
            Ok(value) => value,
            Err(error) => {
                log::error!("Ignoring a malformed Android picker result ({error}): {raw}");
                continue;
            }
        };
        let Some(id) = value.get("id").and_then(serde_json::Value::as_u64) else { continue };
        let kind = value.get("kind").and_then(serde_json::Value::as_str).unwrap_or_default();
        let status = value.get("status").and_then(serde_json::Value::as_str).unwrap_or("error");
        let paths: Option<Vec<std::path::PathBuf>> = if status == "ok" {
            Some(saf::picker_paths(&value).into_iter().map(std::path::PathBuf::from).collect())
        } else {
            None
        };
        // A save's staged destination is written by the app itself; watch it so the write is
        // mirrored to the chosen SAF document.
        if kind == "save" {
            if let Some(ref paths) = paths {
                if let Some(path) = paths.first() {
                    state.mirror.track(id, &path.to_string_lossy());
                }
            }
        }
        rfd::artcraft_saf::deliver(id, paths);
    }
    state.mirror.sync(bridge);
}
''',
        "setup": '''
    let launcher_bridge = saf_bridge.clone_ref();
    rfd::artcraft_saf::install(std::sync::Arc::new(move |id, kind| {
        match kind {
            rfd::artcraft_saf::Kind::Open => { launcher_bridge.request_open(id, false).ok(); }
            rfd::artcraft_saf::Kind::Save(ref name) => { launcher_bridge.request_save(id, name).ok(); }
            rfd::artcraft_saf::Kind::Folder => { launcher_bridge.request_folder(id).ok(); }
        }
    }));
''',
        "construct_expr": "PdfCraftApp::new()",
    },
    # ---- figcraft: a Services trait (not a struct) injected as Box<dyn Services>. ----
    "figcraft": {
        "activity": "FigCraftActivity",
        "imports": "use figcraft_ui_egui::Services;\n" + SYNC_SAF_IMPORTS,
        "state": SYNC_SAF_STATE,
        "services": '''
struct SafServices {
    bridge: saf::Bridge,
    state: Arc<SafState>,
}

impl SafServices {
    fn new(bridge: saf::Bridge, state: Arc<SafState>, _inbox: SafInbox) -> Self {
        Self { bridge, state }
    }
}

impl Services for SafServices {
    fn pick_open(&mut self, _title: &str, _exts: &[&str]) -> Option<std::path::PathBuf> {
        saf_open_paths(&self.bridge, &self.state).into_iter().next().map(std::path::PathBuf::from)
    }
    fn pick_save(&mut self, _title: &str, name: &str, _exts: &[&str]) -> Option<std::path::PathBuf> {
        saf_save_path(&self.bridge, &self.state, name).map(std::path::PathBuf::from)
    }
    fn pick_folder(&mut self, _title: &str) -> Option<std::path::PathBuf> {
        saf_folder_path(&self.bridge, &self.state).map(std::path::PathBuf::from)
    }
}
''',
        "poll": SYNC_SAF_POLL,
        "construct_expr": "FigApp::new(Session::new(), Box::new(SafServices::new(saf_bridge.clone_ref(), std::sync::Arc::clone(&saf_state), saf_inbox.clone())))",
    },
}

# How the launcher opens a document the system handed it (an ACTION_VIEW/ACTION_SEND intent it is
# registered for), once per staged file. Each entry is the body of the shell's `open_incoming`, so it
# can use `self.inner`, `self.saf_inbox` and the `saf` bridge helpers. Apps with an import inbox
# receive name+bytes exactly like a file chosen in the picker; the others are asked to open the
# staged path through their own document API. Apps absent here simply ignore incoming files.
INTENT_OPEN = {
    "designcraft": '''        if let Err(error) = self.inner.open_dropped(path) {
            log::error!("Could not open the incoming file {path}: {error}");
        }
''',
    "deckcraft": '''        if let Err(error) = self.inner.open_path(path) {
            log::error!("Could not open the incoming file {path}: {error}");
        }
''',
    "gridcraft": '''        match std::fs::read(path) {
            Ok(bytes) => self.saf_inbox.lock().unwrap().push((saf::picker_name(path), bytes)),
            Err(error) => log::error!("Could not read the incoming file {path}: {error}"),
        }
''',
    "wordcraft": '''        match std::fs::read(path) {
            Ok(bytes) => self.saf_inbox.lock().unwrap().push((saf::picker_name(path), bytes)),
            Err(error) => log::error!("Could not read the incoming file {path}: {error}"),
        }
''',
    "cadcraft": '''        self.inner.open_path(path);
''',
    "pdfcraft": '''        self.inner.open_path(path);
''',
    "lightcraft": '''        if let Err(error) = lightcraft_ui_egui::import::open(&mut self.inner, vec![path.to_owned()]) {
            log::error!("Could not open the incoming file {path}: {error}");
        }
''',
    "soundcraft": '''        if let Err(error) = soundcraft_ui_egui::dialogs::run_or_ask(&mut self.inner, "session.open", serde_json::json!({ "path": path })) {
            log::error!("Could not open the incoming file {path}: {error}");
        }
''',
    "effectcraft": '''        if let Err(error) = self.inner.session.execute("file.open", serde_json::json!({ "path": path })) {
            log::error!("Could not open the incoming file {path}: {error}");
        }
''',
    "filmcraft": '''        if let Err(error) = self.inner.file_dialog("file.open", &serde_json::json!({ "path": path })) {
            log::error!("Could not open the incoming file {path}: {error}");
        }
''',
    "figcraft": '''        let _ = self.inner.run("file.open", serde_json::json!({ "path": path }));
''',
}
saf = SAF_RECIPES.get(app)

stem = app[:-len("craft")] if app.endswith("craft") else app
expected = stem[:1].upper() + stem[1:] + "App"
app_type = spec.get("app_type") or next((x for x in candidates if x.lower() == expected.lower()), None)
if app_type is None:
    matching = sorted(x for x in candidates if x.lower().startswith(stem.lower()))
    if len(matching) == 1:
        app_type = matching[0]
    elif len(candidates) == 1:
        app_type = next(iter(candidates))
    else:
        raise SystemExit(
            f"Cannot uniquely discover the public UI app type for {app}. Candidates: {sorted(candidates)}. "
            f"Create adapters/{app}/Cargo.toml and adapters/{app}/src/lib.rs; see adapters/README.md."
        )
if app_type not in ui_root and not re.search(r"pub\s+use[\s\S]{0,500}" + re.escape(app_type), ui_root):
    raise SystemExit(
        f"Found {app_type}, but it is not visibly re-exported from crates/ui-egui/src/lib.rs. "
        f"A custom adapter is required; see adapters/README.md."
    )

engine_ident = engine_pkg.replace("-", "_")
ui_ident = ui_pkg.replace("-", "_")
construct = spec.get("construct", "{app}::new(Session::new(), Services::default())").format(
    app=app_type, engine=engine_ident, ui=ui_ident
)

# ---- Saving on Android: settings, preferences and the recent-files list ----------------------
# The desktop apps load and save these in `apps/<app>/src/main.rs` (a per-user config folder via
# `HOME`/`XDG_CONFIG_HOME`), and the web apps keep them in the browser. Neither is compiled into
# the generated NativeActivity launcher, so on Android nothing was written and every launch started
# from the defaults — settings, preferences and "recent files" were forgotten (only PhotoCraft, a
# custom adapter, had wired this up). The launcher now reproduces each app's own load/save calls,
# pointed at the app's private files directory (`AndroidApp::internal_data_path()`), which survives
# restarts and updates.
#
# `@UI@`/`@ENGINE@` become the app's crate idents. `inner` is the app and `dir` its config folder;
# `persist_read`/`persist_write` are the shared helpers below.
PERSIST_RECIPES = {
    "wordcraft": {
        "load": '''if let Some(bytes) = persist_read(dir, "ui.json") {
        if let Some(ui) = @UI@::UiState::from_json(&bytes) {
            inner.apply_prefs(ui);
        }
    }''',
        "save": '''match serde_json::to_vec_pretty(&inner.prefs()) {
        Ok(bytes) => persist_write(dir, "ui.json", &bytes),
        Err(error) => log::warn!("saving settings: {error}"),
    }''',
    },
    "designcraft": {
        "load": '''if let Some(bytes) = persist_read(dir, "ui.json") {
        if let Ok(ui) = @UI@::UiState::from_preferences_json(&bytes) {
            inner.ui = ui;
        }
    }
    if let Some(bytes) = persist_read(dir, "prefs.json") {
        if let Ok(prefs) = serde_json::from_slice::<@ENGINE@::Prefs>(&bytes) {
            inner.session.prefs = prefs;
        }
    }''',
        "save": '''if let Ok(bytes) = serde_json::to_vec_pretty(&inner.ui) {
        persist_write(dir, "ui.json", &bytes);
    }
    if let Ok(bytes) = serde_json::to_vec_pretty(&inner.session.prefs) {
        persist_write(dir, "prefs.json", &bytes);
    }''',
    },
    "lightcraft": {
        "load": '''if let Some(bytes) = persist_read(dir, "ui.json") {
        match serde_json::from_slice::<@UI@::UiState>(&bytes) {
            Ok(ui) => inner.ui = ui.sanitized(),
            Err(error) => log::warn!("settings: {error}"),
        }
    }''',
        "save": '''if let Ok(bytes) = serde_json::to_vec_pretty(&inner.ui) {
        persist_write(dir, "ui.json", &bytes);
    }''',
    },
    "gridcraft": {
        "load": '''if let Some(bytes) = persist_read(dir, "ui.json") {
        if let Ok(ui) = serde_json::from_slice::<@UI@::UiState>(&bytes) {
            inner.ui = ui;
        }
    }
    if let Some(bytes) = persist_read(dir, "prefs.json") {
        if let Ok(prefs) = serde_json::from_slice(&bytes) {
            inner.session.prefs = prefs;
        }
    }''',
        "save": '''if let Ok(bytes) = serde_json::to_vec_pretty(&inner.ui) {
        persist_write(dir, "ui.json", &bytes);
    }
    if let Ok(bytes) = serde_json::to_vec_pretty(&inner.session.prefs) {
        persist_write(dir, "prefs.json", &bytes);
    }''',
    },
    "deckcraft": {
        "load": '''let (ui, prefs) = @UI@::settings::load(dir);
    if let Some(ui) = ui {
        inner.ui = ui;
    }
    if let Some(prefs) = prefs {
        inner.session.prefs = prefs;
    }''',
        "save": '''@UI@::settings::save(dir, &inner.ui, &inner.session.prefs);''',
    },
    "soundcraft": {
        "load": '''if let Some(bytes) = persist_read(dir, "ui.json") {
        if let Ok(ui) = serde_json::from_slice::<@UI@::UiState>(&bytes) {
            inner.ui = ui;
        }
    }''',
        "save": '''if let Ok(bytes) = serde_json::to_vec_pretty(&inner.ui) {
        persist_write(dir, "ui.json", &bytes);
    }''',
    },
    "cadcraft": {
        "load": '''if let Some(bytes) = persist_read(dir, "prefs.json") {
        if let Ok(json) = std::str::from_utf8(&bytes) {
            inner.load_prefs(json);
        }
    }
    if let Some(bytes) = persist_read(dir, "profile.json") {
        if let Ok(json) = std::str::from_utf8(&bytes) {
            inner.load_profile(json);
        }
    }
    if let Some(bytes) = persist_read(dir, "autosave.json") {
        if let Ok(json) = std::str::from_utf8(&bytes) {
            @UI@::autosave::load_prefs(json);
        }
    }
    inner.enable_autosave(&dir.join("autosave"));
    inner.session.set_lisp_support_dir(Some(dir.join("support")));''',
        "save": '''persist_write(dir, "prefs.json", inner.prefs_json().as_bytes());
    persist_write(dir, "profile.json", inner.profile_json().as_bytes());
    persist_write(dir, "autosave.json", @UI@::autosave::prefs_json().as_bytes());''',
    },
    "effectcraft": {
        "load": '''inner.session.config = Some(std::sync::Arc::new(@ENGINE@::config::DirConfig::new(dir)));
    inner.session.load_settings();''',
        "save": '''inner.session.save_prefs();''',
    },
    "filmcraft": {
        "load": '''let cfg = @ENGINE@::autosave::AutosaveConfig::new(dir.to_path_buf());
    if let Err(error) = inner.session.start_autosave(cfg) {
        log::warn!("auto-save and crash recovery unavailable: {error}");
    }''',
        "save": '''let prefs = inner.session.prefs.clone();
    if let Err(error) = inner.session.set_prefs(prefs) {
        log::warn!("saving preferences: {error}");
    }''',
    },
    "pdfcraft": {
        "load": '''if let Some(bytes) = persist_read(dir, "ui.json") {
        if let Ok(json) = std::str::from_utf8(&bytes) {
            inner.restore(json);
        }
    }
    if let Some(recovery) = @UI@::RecoveryStore::default_dir() {
        inner.enable_recovery(@UI@::RecoveryStore::new(recovery));
    }''',
        "save": '''persist_write(dir, "ui.json", inner.persist().as_bytes());''',
    },
    "figcraft": {
        "load": '''if let Some(bytes) = persist_read(dir, "state.json") {
        if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) {
            if let Some(prefs) = value.get("prefs").and_then(|p| serde_json::from_value::<@ENGINE@::Prefs>(p.clone()).ok()) {
                inner.session.prefs = prefs;
            }
        }
    }''',
        "save": '''match serde_json::to_string(&serde_json::json!({ "prefs": inner.session.prefs })) {
        Ok(json) => persist_write(dir, "state.json", json.as_bytes()),
        Err(error) => log::warn!("saving preferences: {error}"),
    }''',
    },
}

# Shared Rust helpers the recipes above call (single braces: not interpolated as format fields).
PERSIST_SUPPORT = r'''
/// The app's private storage directory. Android exposes two: the internal one
/// (`/data/user/0/<pkg>/files`), which a file manager or a computer never sees, and the app-specific
/// external one (`/storage/emulated/0/Android/data/<pkg>/files`), which the user can reach over USB
/// or MTP without root. The external directory is preferred so the settings, autosaves and exported
/// documents are actually findable; the internal directory is the fallback for the rare device where
/// external storage is unmounted or unavailable. Both survive restarts and app updates.
fn app_data_dir(app: &AndroidApp) -> Option<std::path::PathBuf> {
    app.external_data_path().or_else(|| app.internal_data_path())
}

/// The app's private files directory plus a `config` subfolder, where the settings, preferences and
/// recent-files list are kept. The folder survives restarts and app updates, which is what the
/// desktop versions get from their per-user config folder.
fn persist_dir(app: &AndroidApp) -> Option<std::path::PathBuf> {
    app_data_dir(app).map(|base| base.join("config"))
}

/// Point the platform path helpers at app-private storage before the app reads them, so anything
/// the app writes itself (autosave, recovery copies, caches) also lands there.
#[allow(unused_unsafe)]
fn install_persist_env(app: &AndroidApp) {
    let Some(base) = app_data_dir(app) else { return };
    let config = base.join("config");
    let cache = base.join("cache");
    let home = base.join("home");
    let _ = std::fs::create_dir_all(config.join(".config"));
    let _ = std::fs::create_dir_all(&cache);
    let _ = std::fs::create_dir_all(&home);
    // SAFETY: `android_main` runs before the app starts any worker thread, so no other thread is
    // reading the environment here.
    unsafe {
        std::env::set_var("XDG_CONFIG_HOME", &config);
        std::env::set_var("XDG_DATA_HOME", &base);
        std::env::set_var("XDG_CACHE_HOME", &cache);
        std::env::set_var("HOME", &home);
    }
    log::info!("settings directory: {}", config.display());
}

#[allow(dead_code)]
fn persist_read(dir: &std::path::Path, name: &str) -> Option<Vec<u8>> {
    std::fs::read(dir.join(name)).ok()
}

/// Write `bytes` to `dir/name` through a temporary file renamed over the old one, so a crash leaves
/// the old file or the new one whole, never a truncated one.
#[allow(dead_code)]
fn persist_write(dir: &std::path::Path, name: &str, bytes: &[u8]) {
    if let Err(error) = std::fs::create_dir_all(dir) {
        log::warn!("settings: {}: {error}", dir.display());
        return;
    }
    let path = dir.join(name);
    let temporary = path.with_extension("tmp");
    let written = std::fs::write(&temporary, bytes).and_then(|()| std::fs::rename(&temporary, &path));
    if let Err(error) = written {
        log::warn!("settings: {}: {error}", path.display());
    }
}
'''

PERSIST_METHODS = r'''
    /// Save settings, preferences and the recent-files list, at most every two seconds. Android
    /// can kill a backgrounded app without a clean exit, so waiting for `on_exit` alone would lose
    /// whatever changed since the last write.
    fn persist_tick(&mut self) {
        let Some(dir) = self.persist.clone() else { return };
        let now = std::time::Instant::now();
        if self.persist_last.is_some_and(|last| now.duration_since(last) < std::time::Duration::from_secs(2)) {
            return;
        }
        self.persist_last = Some(now);
        persist_save(&mut self.inner, &dir);
    }

    /// Save now: the window lost focus (the app is being backgrounded) or it is exiting.
    fn persist_now(&mut self) {
        if let Some(dir) = self.persist.clone() {
            persist_save(&mut self.inner, &dir);
        }
    }
'''

PERSIST_HOOK = '''        if raw.events.iter().any(|event| matches!(event, egui::Event::WindowFocused(false))) {
            self.persist_now();
        }
'''

PERSIST_ON_EXIT = '''
    fn on_exit(&mut self) {
        self.persist_now();
    }
'''

_persist = PERSIST_RECIPES.get(app)
if _persist:
    _load = _persist["load"].replace("@UI@", ui_ident).replace("@ENGINE@", engine_ident)
    _save = _persist["save"].replace("@UI@", ui_ident).replace("@ENGINE@", engine_ident)
    persist_support = PERSIST_SUPPORT + f'''
fn persist_load(inner: &mut {app_type}, dir: &std::path::Path) {{
{_load}
}}

fn persist_save(inner: &mut {app_type}, dir: &std::path::Path) {{
{_save}
}}
'''
    persist_fields = "\n    persist: Option<std::path::PathBuf>,\n    persist_last: Option<std::time::Instant>,"
    persist_new_body = "let persist = persist_dir(&app);\n        if let Some(dir) = &persist {\n            persist_load(&mut inner, dir);\n        }\n        "
    persist_new_init = ", persist, persist_last: None"
    persist_methods = PERSIST_METHODS
    persist_logic = "        self.persist_tick();\n"
    persist_hook = PERSIST_HOOK
    persist_on_exit = PERSIST_ON_EXIT
    persist_env_call = "    install_persist_env(&android_app);\n"
else:
    persist_support = ""
    persist_fields = ""
    persist_new_body = ""
    persist_new_init = ""
    persist_methods = ""
    persist_logic = ""
    persist_hook = ""
    persist_on_exit = ""
    persist_env_call = ""
# A type that does not implement `eframe::App` is an inner app state; its desktop `main.rs` wraps it
# in a tiny struct that forwards `logic`/`ui`. Emit the same wrapper here.
has_eframe_app = bool(re.search(r"impl\s+eframe::App\s+for\s+" + re.escape(app_type) + r"\b", ui_text))
has_raw_hook = bool(re.search(r"pub fn raw_input_hook\b", ui_text))
if not re.search(r"\bServices\b|\bNoServices\b", construct) and "Services" not in ui_root and not spec:
    raise SystemExit(f"The UI crate does not visibly export Services; a custom adapter is required for {app}.")

# figcraft's `Services::pick_*` methods return a future on newer source releases and a plain
# Option on older ones. The recipe is written in the sync form, so rewrite it — and import the
# future type — to whatever the checked-out trait declares; otherwise a regenerated launcher
# cannot compile against the source it was generated from.
if saf and app == "figcraft" and re.search(r"fn pick_open\([^)]*\)\s*->\s*DialogFuture", ui_root):
    saf["imports"] += f"\nuse {ui_ident}::DialogFuture;"
    saf["services"] = re.sub(
        r"(fn pick_\w+\([^)]*\)) -> Option<[^>]*> \{\n(\s+)(.*?)\n\s*\}",
        lambda m: (
            f"{m.group(1)} -> DialogFuture {{\n"
            f"{m.group(2)}let result = {m.group(3).strip()};\n"
            f"{m.group(2)}Box::pin(async move {{ result }})\n"
            f"{m.group(2)[:-4]}}}"
        ),
        saf["services"],
        flags=re.S,
    )

# Prefer the app's own icon; don't accidentally bundle another ArtCraft app's branding.
# An explicit -appicon always wins.
if appicon:
    icon = Path(appicon)
    if not icon.is_file():
        raise SystemExit(f"App icon not found: {appicon}")
else:
    # The icon lives in the app's own source tree, where upstream still names it after its original
    # `ai.storyteller.<app>` package, so that spelling comes first; the `com.artcraft.<app>` and bare
    # `<app>` spellings are kept as fallbacks in case upstream renames the asset.
    icon_candidates = [
        src / "assets" / "app-icon" / "hicolor" / "256x256" / "apps" / f"ai.storyteller.{app}.png",
        src / "assets" / "app-icon" / "hicolor" / "256x256" / "apps" / f"com.artcraft.{app}.png",
        src / "assets" / "app-icon" / "hicolor" / "256x256" / "apps" / f"{app}.png",
        src / "assets" / "app-icon" / f"ai.storyteller.{app}.png",
        src / "assets" / "app-icon" / f"com.artcraft.{app}.png",
        src / "assets" / "app-icon" / f"{app}.png",
    ]
    icon = next((p for p in icon_candidates if p.is_file()), None)
    if icon is None:
        matches = [p for p in (src / "assets").rglob("*.png") if "app-icon" in p.parts and app in p.name.lower()]
        icon = sorted(matches)[0] if matches else None
    if icon is None:
        raise SystemExit(f"Could not find an app-specific PNG icon under assets/app-icon for {app}; pass -appicon=<path> or create a custom adapter.")

# Stage in a temporary sibling and publish the Android crate only when every generated file is ready.
staging_dir = android_dir.with_name(android_dir.name + ".artcraft-staging")
if staging_dir.exists():
    shutil.rmtree(staging_dir)
staging_dir.mkdir(parents=True)
try:
    for density in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"):
        out_dir = staging_dir / "res" / f"mipmap-{density}"
        out_dir.mkdir(parents=True)
        sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
        magick = shutil.which("magick")
        convert = shutil.which("convert")
        if magick:
            import subprocess
            subprocess.run([magick, str(icon), "-resize", f"{sizes[density]}x{sizes[density]}", str(out_dir / "ic_launcher.png")], check=True)
        elif convert:
            import subprocess
            subprocess.run([convert, str(icon), "-resize", f"{sizes[density]}x{sizes[density]}", str(out_dir / "ic_launcher.png")], check=True)
        else:
            shutil.copy2(icon, out_dir / "ic_launcher.png")

    serde_dep = 'serde_json = { workspace = true }\n' if (saf or _persist) else ''
    # The SAF bridge for rfd-driven apps (pdfcraft) calls `rfd::artcraft_saf` from the launcher, so
    # the launcher needs rfd as a direct dependency. The app's workspace patches it to the vendored
    # Android copy (see below), which carries the artcraft_saf module.
    rfd_dep = 'rfd = "0.17"\n' if re.search(r"\brfd::", ui_text) else ''
    # Audio output on Android comes from the platform layer: the launcher compiles the app's own
    # desktop cpal module (copied in below, next to `mod audio;`) and injects it into the app, so
    # the launcher needs cpal as a direct dependency. Only these apps ship such a module; the third
    # entry is (module name, source file, extra launcher dependencies).
    AUDIO_MODULES = {
        "filmcraft": ("audio", "audio.rs", ()),
        "effectcraft": ("audio_out", "audio_out.rs", ()),
        "deckcraft": ("audio", "audio.rs", ("deckcraft-media = { workspace = true }",)),
    }
    cpal_dep = "".join(f"{dep}\n" for dep in ('cpal = "0.16"', *AUDIO_MODULES[app][2])) if app in AUDIO_MODULES else ''
    java_sources = 'java_sources = "java"\n' if saf else ''
    config_changes = "orientation|keyboard|keyboardHidden|navigation|screenSize|screenLayout|smallestScreenSize|density|layoutDirection|uiMode|fontScale|locale"
    # Android open/share associations for the app's document types (the MAIN/LAUNCHER entry is always
    # first). Shared with the adapter launchers; see lib/file_associations.py.
    intent_filter_value = file_associations.intent_filter_toml(app)
    if saf:
        activity_block = f'''[[package.metadata.android.application.activity]]
name = ".{saf['activity']}"
config_changes = "{config_changes}"
label = "{title}"
launch_mode = "singleTask"
orientation = "sensor"
exported = true
# cargo-apk2 does NOT add a default MAIN/LAUNCHER filter when an activity is named, so declare it
# here: without it the APK has no launcher activity and cannot start from the home screen. The
# remaining filters register the app for its document types so the system can open/share them with
# it. Keep it inline: cargo-apk2's serde `flatten` rejects an `[[...activity.intent_filter]]` table.
intent_filter = {intent_filter_value}

[[package.metadata.android.application.activity.meta_data]]
name = "android.app.lib_name"
value = "{app}_android"
'''
    else:
        activity_block = f'''[package.metadata.android.application.activity]
config_changes = "{config_changes}"
label = "{title}"
launch_mode = "singleTask"
orientation = "sensor"
exported = true
intent_filter = {intent_filter_value}
'''

    package_name = packagename if packagename else f"com.artcraft.{app}"
    # Read the app's version from the source workspace manifest so the APK is named photocraft-0.8.0.apk.
    try:
        app_version = ws["workspace"]["package"]["version"]
    except (KeyError, TypeError):
        app_version = "0.0.0"
    apk_basename = f"{app}-{app_version}"
    manifest = f'''[package]
name = "{app}-android"
version.workspace = true
edition.workspace = true
license.workspace = true

[lib]
crate-type = ["cdylib"]

[dependencies]
{engine_pkg} = {{ path = "../../crates/engine" }}
{ui_pkg} = {{ path = "../../crates/ui-egui" }}
eframe = {{ workspace = true, features = ["wgpu", "persistence"] }}
egui = {{ workspace = true }}
log = {{ workspace = true }}
jni = "0.22"
{serde_dep}{rfd_dep}{cpal_dep}
[target.'cfg(target_os = "android")'.dependencies]
android-activity = {{ version = "0.6", default-features = false, features = ["native-activity"] }}

[package.metadata.android]
package = "{package_name}"
apk_name = "{apk_basename}"
build_targets = ["aarch64-linux-android"]
resources = "res"
{java_sources}
[package.metadata.android.sdk]
min_sdk_version = 28
target_sdk_version = {target_sdk}

# Let the app's own file browsers read and write files on the device (see
# templates/android/SafActivity.java: safRequestStoragePermission). Legacy permissions cover
# Android 12 and older; "All files access" covers Android 11+.
[[package.metadata.android.uses_permission]]
name = "android.permission.READ_EXTERNAL_STORAGE"
max_sdk_version = 32

[[package.metadata.android.uses_permission]]
name = "android.permission.WRITE_EXTERNAL_STORAGE"
max_sdk_version = 29

[[package.metadata.android.uses_permission]]
name = "android.permission.MANAGE_EXTERNAL_STORAGE"

[package.metadata.android.application]
label = "{title}"
theme = "@android:style/Theme.DeviceDefault.NoActionBar.Fullscreen"
icon = "@mipmap/ic_launcher"

{activity_block}'''
    (staging_dir / "Cargo.toml").write_text(manifest)

    if saf:
        pkg = packagename if packagename else f"com.artcraft.{app}"
        java_src = (root / "templates" / "android" / "SafActivity.java").read_text()
        java_src = (
            java_src.replace("__PACKAGE__", pkg)
            .replace("__CLASS__", saf["activity"])
            .replace("__TAG__", saf["activity"])
        )
        java_dir = staging_dir / "java" / Path(*pkg.split("."))
        java_dir.mkdir(parents=True, exist_ok=True)
        (java_dir / f"{saf['activity']}.java").write_text(java_src)

    imports = []
    # Pull in the shared Android system-font module (written next to our rust source below) so the
    # launcher can fall back to the device's own fonts for scripts the app's fonts do not cover.
    imports.append("mod system_fonts;")
    # Pull in the shared Android soft-keyboard bridge (also written below) so the launcher can drain
    # the Activity's IME events into egui. Its presence is also what keeps the vendored
    # android-activity (which forwards show/hide to the Activity's imeShow/imeHide) in step.
    imports.append("mod ime_bridge;")
    if re.search(r"\bSession\b", construct):
        imports.append(f"use {engine_ident}::Session;")
    services_syms = [s for s in ("NoServices", "Services") if re.search(r"\b" + s + r"\b", (SAF_RECIPES.get(app) or {}).get("construct_expr") or construct)]
    if services_syms:
        imports.append("use " + ui_ident + "::{" + ", ".join([app_type] + services_syms) + "};")
    else:
        imports.append(f"use {ui_ident}::{app_type};")
    use_block = "\n".join(imports)
    saf_block = ""
    if saf:
        use_block = use_block + "\n" + saf["imports"]
        saf_block = (root / "templates" / "android" / "saf_bridge.rs").read_text()
        saf_block = saf_block + "\n" + saf["state"] + saf["services"] + saf["poll"]

    if has_eframe_app:
        inner_logic = "self.inner.logic(ctx, frame);"
        inner_ui = "self.inner.ui(ui, frame);"
        inner_hook = "self.inner.raw_input_hook(ctx, raw);"
    else:
        inner_logic = "let _ = frame;\n        self.inner.logic(ctx);"
        inner_ui = "let _ = frame;\n        self.inner.ui(ui);"
        if has_raw_hook:
            inner_hook = "let _ = ctx;\n        self.inner.raw_input_hook(raw);"
        else:
            inner_hook = "let _ = (ctx, raw);"

    app_upper = re.sub(r"[^A-Za-z0-9]", "_", app).upper()
    # The SAF marker tracks the generator version so a reader can tell which template produced a
    # given APK. The non-SAF marker keeps its own feature version (fullscreen + modifier fix).
    shell_marker = (
        f"ARTCRAFT_{app_upper}_ANDROID_SHELL_V{GENERATOR_VERSION}_SAF_FILEACCESS"
        if saf
        else f"ARTCRAFT_{app_upper}_ANDROID_SHELL_V3_MODIFIERS_FULLSCREEN"
    )

    platform = r'''
use android_activity::AndroidApp;
use jni::{JavaVM, jni_sig, jni_str, objects::{JObject, JString, JValue}};

/// Emitted at startup so a device log (and the packaged `.so` strings) can confirm that this
/// shell — including the Android modifier-key fix and immersive fullscreen — is the one running.
const ARTCRAFT_ANDROID_SHELL_MARKER: &str = "MARKER_PLACEHOLDER";

/// Hide the Android status and navigation bars so the egui canvas owns the whole screen.
///
/// The theme's `windowFullscreen` flag only hides the status bar; the navigation bar needs sticky
/// immersive mode. `android_main` runs on its own Rust thread, so the Java main (UI) thread is
/// free and these window calls can run on it without a Java activity subclass.
fn apply_immersive_fullscreen(app: &AndroidApp) {
    let app_clone = app.clone();
    app.run_on_java_main_thread(Box::new(move || {
        // SAFETY: AndroidApp owns the live VM pointer for the lifetime of the activity.
        let jvm = unsafe { JavaVM::from_raw(app_clone.vm_as_ptr() as *mut _) };
        let result = jvm.attach_current_thread(|env| -> jni::errors::Result<()> {
            let activity_raw = app_clone.activity_as_ptr() as jni::sys::jobject;
            // SAFETY: AndroidApp retains this global Activity reference; as_cast_raw borrows it.
            let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw)? };
            let window = env
                .call_method(&*activity, jni_str!("getWindow"), jni_sig!("()Landroid/view/Window;"), &[])?
                .l()?;
            if window.is_null() {
                return Ok(());
            }
            let decor = env
                .call_method(&window, jni_str!("getDecorView"), jni_sig!("()Landroid/view/View;"), &[])?
                .l()?;
            if decor.is_null() {
                return Ok(());
            }
            // LAYOUT_STABLE | HIDE_NAVIGATION | FULLSCREEN | LAYOUT_HIDE_NAVIGATION
            // | LAYOUT_FULLSCREEN | IMMERSIVE_STICKY
            const IMMERSIVE: i32 =
                0x0000_0100 | 0x0000_0002 | 0x0000_0004 | 0x0000_0200 | 0x0000_0400 | 0x0000_1000;
            env.call_method(
                &decor,
                jni_str!("setSystemUiVisibility"),
                jni_sig!("(I)V"),
                &[JValue::Int(IMMERSIVE)],
            )?;
            Ok(())
        });
        if let Err(error) = result {
            log::error!("Could not apply immersive fullscreen: {error}");
        }
    }));
}

/// Reconstruct egui's modifier state on Android.
///
/// winit's Android backend delivers `KeyboardInput` events but never emits `ModifiersChanged`
/// (it discards the `KeyEvent`'s meta state), so egui's modifier state stays empty and
/// `Ctrl`/`Alt` shortcuts are ignored while plain keys continue to work. Physical modifier keys
/// do arrive as `Event::Key` events (`Key::ControlLeft`, `Key::AltLeft`, ...), so we track them
/// and stamp the resulting state onto this frame's events, suppressing the text character that
/// would otherwise be emitted alongside a Ctrl/Command shortcut.
fn apply_android_modifiers(state: &mut egui::Modifiers, raw: &mut egui::RawInput) {
    let before = *state;
    let mut kept: Vec<egui::Event> = Vec::with_capacity(raw.events.len());
    for mut event in raw.events.drain(..) {
        match &mut event {
            egui::Event::Key { key, physical_key, pressed, modifiers, .. } => {
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
            egui::Event::Text(_) if state.ctrl || state.command || state.mac_cmd => {}
            egui::Event::WindowFocused(false) => {
                *state = egui::Modifiers::default();
                kept.push(event);
            }
            _ => kept.push(event),
        }
    }
    raw.events = kept;
    if *state != before {
        raw.events.push(egui::Event::ModifiersChanged(*state));
    }
}

/// Read the Android system clipboard's text (empty when there is none). Reaches
/// `ClipboardManager` through JNI using the live VM and Activity held by `AndroidApp`,
/// so it works from `android_main`'s own thread without a Java activity subclass.
fn android_clipboard_get(app: &AndroidApp) -> String {
    let app = app.clone();
    // SAFETY: AndroidApp owns the live VM pointer for the lifetime of the activity.
    let vm = unsafe { JavaVM::from_raw(app.vm_as_ptr() as *mut _) };
    let activity_raw = app.activity_as_ptr() as jni::sys::jobject;
    let result = vm.attach_current_thread(|env| -> jni::errors::Result<String> {
        // SAFETY: AndroidApp retains this global Activity reference; as_cast_raw borrows it
        // without taking ownership or attempting to delete the reference.
        let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw)? };
        let service = JObject::from(env.new_string("clipboard")?);
        let manager = env
            .call_method(
                &*activity,
                jni_str!("getSystemService"),
                jni_sig!("(Ljava/lang/String;)Ljava/lang/Object;"),
                &[JValue::Object(&service)],
            )?
            .l()?;
        if manager.is_null() {
            return Ok(String::new());
        }
        let clip = env
            .call_method(
                &manager,
                jni_str!("getPrimaryClip"),
                jni_sig!("()Landroid/content/ClipData;"),
                &[],
            )?
            .l()?;
        if clip.is_null() {
            return Ok(String::new());
        }
        let count = env
            .call_method(&clip, jni_str!("getItemCount"), jni_sig!("()I"), &[])?
            .i()?;
        if count <= 0 {
            return Ok(String::new());
        }
        let item = env
            .call_method(
                &clip,
                jni_str!("getItemAt"),
                jni_sig!("(I)Landroid/content/ClipData$Item;"),
                &[JValue::Int(0)],
            )?
            .l()?;
        if item.is_null() {
            return Ok(String::new());
        }
        let text = env
            .call_method(
                &item,
                jni_str!("getText"),
                jni_sig!("()Ljava/lang/CharSequence;"),
                &[],
            )?
            .l()?;
        if text.is_null() {
            return Ok(String::new());
        }
        let text = env
            .call_method(
                &text,
                jni_str!("toString"),
                jni_sig!("()Ljava/lang/String;"),
                &[],
            )?
            .l()?;
        if text.is_null() {
            return Ok(String::new());
        }
        let text = JString::cast_local(env, text)?;
        Ok(text.try_to_string(env)?)
    });
    result.unwrap_or_else(|error| {
        log::error!("Could not read the Android clipboard: {error}");
        String::new()
    })
}

/// Write text to the Android system clipboard (`ClipboardManager`). Best-effort:
/// a refusal is logged, never raised into the frame loop.
fn android_clipboard_set(app: &AndroidApp, text: &str) {
    let app = app.clone();
    let text = text.to_owned();
    // SAFETY: AndroidApp owns the live VM pointer for the lifetime of the activity.
    let vm = unsafe { JavaVM::from_raw(app.vm_as_ptr() as *mut _) };
    let activity_raw = app.activity_as_ptr() as jni::sys::jobject;
    let result = vm.attach_current_thread(|env| -> jni::errors::Result<()> {
        // SAFETY: AndroidApp retains this global Activity reference; as_cast_raw borrows it
        // without taking ownership or attempting to delete the reference.
        let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw)? };
        let service = JObject::from(env.new_string("clipboard")?);
        let manager = env
            .call_method(
                &*activity,
                jni_str!("getSystemService"),
                jni_sig!("(Ljava/lang/String;)Ljava/lang/Object;"),
                &[JValue::Object(&service)],
            )?
            .l()?;
        if manager.is_null() {
            return Ok(());
        }
        let text_obj = JObject::from(env.new_string(&text)?);
        let label = JObject::from(env.new_string("egui")?);
        let clip = env
            .call_static_method(
                jni_str!("android/content/ClipData"),
                jni_str!("newPlainText"),
                jni_sig!("(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;"),
                &[JValue::Object(&label), JValue::Object(&text_obj)],
            )?
            .l()?;
        if clip.is_null() {
            return Ok(());
        }
        env.call_method(
            &manager,
            jni_str!("setPrimaryClip"),
            jni_sig!("(Landroid/content/ClipData;)V"),
            &[JValue::Object(&clip)],
        )?;
        Ok(())
    });
    if let Err(error) = result {
        log::error!("Could not write the Android clipboard: {error}");
    }
}
'''.replace("MARKER_PLACEHOLDER", shell_marker)

    if saf:
        saf_fields = "\n    saf_bridge: saf::Bridge,\n    saf_state: std::sync::Arc<SafState>,\n    saf_inbox: SafInbox,"
        saf_new_params = ", saf_bridge: saf::Bridge, saf_state: std::sync::Arc<SafState>, saf_inbox: SafInbox"
        saf_new_init = ", saf_bridge, saf_state, saf_inbox"
        saf_poll_method = '''
    /// Drain any finished Android file-picker requests and hand the results to the app.
    fn poll_file_picker(&mut self) {
        saf_poll(&self.saf_bridge, &self.saf_state, &self.saf_inbox);
    }
'''
        saf_logic_poll = "        self.poll_file_picker();\n"
        # Open documents the system handed us (ACTION_VIEW/ACTION_SEND). The Activity stages each
        # file off the UI thread and queues its private path; wait a couple of frames so the app has
        # finished its own start-up, then open one per frame exactly like a picked file.
        intent_body = INTENT_OPEN.get(app, "")
        if intent_body:
            intent_method = f'''
    fn open_incoming(&mut self, path: &str) {{
        log::info!("Opening the file the system handed the app: {{path}}");
{intent_body}    }}

    /// Open any file the system handed the app (an intent it is registered for). Runs once per
    /// staged file and is a no-op afterwards; a launcher without the intent host stops the poll.
    fn poll_incoming_files(&mut self) {{
        if self.intent_warmup > 0 {{
            self.intent_warmup -= 1;
            return;
        }}
        if self.intent_warmup < 0 {{
            return;
        }}
        for _ in 0..16 {{
            match self.saf_bridge.intent_poll() {{
                Ok(Some(path)) => self.open_incoming(&path),
                Ok(None) => break,
                Err(error) => {{
                    log::info!("Launcher does not report incoming files: {{error}}");
                    self.intent_warmup = -1;
                    break;
                }}
            }}
        }}
    }}
'''
            intent_logic = "        self.poll_incoming_files();\n"
            intent_field = "\n    intent_warmup: i64,"
            intent_init = ", intent_warmup: 2"
        else:
            intent_method = ""
            intent_logic = ""
            intent_field = ""
            intent_init = ""
        saf_setup = saf.get("setup", "")
        post_construct = saf.get("post_construct", "")
        if "construct_expr" in saf:
            construct_expr = saf["construct_expr"]
            if app == "lightcraft" and ".with_fs()" not in construct_expr:
                construct_expr = construct_expr.replace("Session::new()", "Session::new().with_fs()")
        else:
            if "Services::default()" not in construct:
                raise SystemExit(f"The SAF recipe for {app} expects a `Services::default()` constructor, found: {construct}")
            construct_expr = construct.replace("Services::default()", "platform_services")
            # Ensure filesystem hooks are installed for apps that need to read staged files (e.g., lightcraft with SAF)
            if app == "lightcraft" and ".with_fs()" not in construct_expr:
                construct_expr = construct_expr.replace("Session::new()", "Session::new().with_fs()")
            if not saf_setup:
                saf_setup = "    let platform_services = saf_services(saf_bridge.clone_ref(), std::sync::Arc::clone(&saf_state), saf_inbox.clone());\n"
        inner_decl = "let mut inner" if post_construct else "let inner"
    else:
        saf_fields = ""
        saf_new_params = ""
        saf_new_init = ""
        saf_poll_method = ""
        saf_logic_poll = ""
        construct_expr = construct
        saf_setup = ""
        post_construct = ""
        inner_decl = "let inner"
        intent_method = ""
        intent_logic = ""
        intent_field = ""
        intent_init = ""

    shell = f'''
/// On-device input diagnostics (reported through `adb logcat`).
///
/// Counts the egui events the platform backend produced since the last report: pointer
/// motion, mouse buttons, wheel scrolls and touches. The stock touch-only winit backend
/// turned a connected mouse into a finger: every mouse move/click arrived wrapped in
/// `Event::Touch`, so `touch` grew while hovering. With the builder-patched backend the
/// same mouse activity grows `pointer`/`buttons`/`wheel` and leaves `touch` at zero
/// (only real fingers grow it). Reports at most once per second, and only when a counter
/// actually changed.
#[derive(Default)]
struct InputProbe {{
    pointer_moved: u64,
    buttons: u64,
    wheels: u64,
    touches: u64,
    reported: (u64, u64, u64, u64),
    last_report: Option<std::time::Instant>,
}}

impl InputProbe {{
    fn observe(&mut self, raw: &egui::RawInput) {{
        for event in &raw.events {{
            match event {{
                egui::Event::PointerMoved(_) => self.pointer_moved += 1,
                egui::Event::PointerButton {{ .. }} => self.buttons += 1,
                egui::Event::MouseWheel {{ .. }} => self.wheels += 1,
                egui::Event::Touch {{ .. }} => self.touches += 1,
                _ => {{}}
            }}
        }}
        let totals = (self.pointer_moved, self.buttons, self.wheels, self.touches);
        if totals == self.reported {{
            return;
        }}
        let now = std::time::Instant::now();
        if self
            .last_report
            .is_some_and(|last| now.duration_since(last) < std::time::Duration::from_secs(1))
        {{
            return;
        }}
        log::info!(
            "input-probe: pointer={{}} buttons={{}} wheel={{}} touch={{}} (event totals)",
            totals.0, totals.1, totals.2, totals.3
        );
        self.reported = totals;
        self.last_report = Some(now);
    }}
}}

{persist_support}
struct AndroidShell {{
    inner: {app_type},
    app: AndroidApp,
    ime: ime_bridge::ime::ImeBridge,
    modifiers: egui::Modifiers,
    fullscreen_applied: bool,
    probe: InputProbe,{saf_fields}{intent_field}{persist_fields}
}}

impl AndroidShell {{
    fn new(mut inner: {app_type}, app: AndroidApp{saf_new_params}) -> Self {{
        {persist_new_body}let ime = ime_bridge::ime::ImeBridge::new(&app);
        Self {{ inner, app, ime, modifiers: egui::Modifiers::default(), fullscreen_applied: false, probe: InputProbe::default(){saf_new_init}{intent_init}{persist_new_init} }}
    }}
{saf_poll_method}{intent_method}{persist_methods}
    /// Re-apply sticky immersive mode on the first frame and whenever the window regains focus
    /// (the system restores the bars after a gesture or when another activity closes).
    fn refresh_fullscreen(&mut self, raw: &egui::RawInput) {{
        let refocused = raw
            .events
            .iter()
            .any(|event| matches!(event, egui::Event::WindowFocused(true)));
        if !self.fullscreen_applied || refocused {{
            self.fullscreen_applied = true;
            apply_immersive_fullscreen(&self.app);
        }}
    }}

    /// Emit egui `Copy`/`Cut`/`Paste` events for Ctrl/Cmd+C/X/V key presses.
    ///
    /// winit's Android backend never emits `ModifiersChanged`, so egui-winit's own
    /// modifier-based clipboard-shortcut detection never fires there. The shell detects the
    /// shortcuts after [`apply_android_modifiers`] has reconstructed the modifier state and
    /// synthesizes the events egui's widgets (text edits, label selection) expect.
    fn handle_clipboard_shortcuts(&mut self, raw: &mut egui::RawInput) {{
        let mut synthesized: Vec<egui::Event> = Vec::new();
        for event in &raw.events {{
            let egui::Event::Key {{ key, pressed: true, modifiers, .. }} = event else {{ continue }};
            if !modifiers.command && !modifiers.ctrl {{
                continue;
            }}
            match key {{
                egui::Key::C => synthesized.push(egui::Event::Copy),
                egui::Key::X => synthesized.push(egui::Event::Cut),
                egui::Key::V => {{
                    let text = android_clipboard_get(&self.app);
                    if !text.is_empty() {{
                        synthesized.push(egui::Event::Paste(text));
                    }}
                }}
                _ => {{}}
            }}
        }}
        raw.events.extend(synthesized);
    }}
}}

impl eframe::App for AndroidShell {{
    fn logic(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {{
{intent_logic}{saf_logic_poll}{persist_logic}        {inner_logic}
    }}

    fn ui(&mut self, ui: &mut egui::Ui, frame: &mut eframe::Frame) {{
        system_fonts::install_system_fonts(ui.ctx());
        {inner_ui}
    }}

    fn raw_input_hook(&mut self, ctx: &egui::Context, raw: &mut egui::RawInput) {{
        self.probe.observe(raw);
        self.ime.poll(raw);
        self.refresh_fullscreen(raw);
        apply_android_modifiers(&mut self.modifiers, raw);
        self.handle_clipboard_shortcuts(raw);
{persist_hook}        {inner_hook}
    }}
{persist_on_exit}}}
'''

    # Install fonts before the first pass. Some apps (figcraft) lay out text with a named font family
    # ("semibold") that only exists after their theme installs the fonts, and egui applies `set_fonts`
    # at the *next* pass: installing from the app's own first frame is one pass too late, so the frame
    # that first draws with that family panics ("FontFamily::Name(\"semibold\") is not bound to any
    # fonts"). The eframe creator runs before the first pass, so installing there makes the family
    # available from frame one.
    create_hook = {
        "figcraft": "            figcraft_ui_egui::theme::install_fonts(&cc.egui_ctx, false, 0);\n",
    }.get(app, "")
    creator = (
        "Box::new(move |cc| {\n" + create_hook + "            Ok(Box::new(shell))\n        })"
        if create_hook
        else "Box::new(move |_cc| Ok(Box::new(shell)))"
    )

    if saf:
        entry = f'''//! Generated Android launcher for {title}.
//! Starts the app's egui UI with Android Storage Access Framework (SAF) file services plus the
//! shared Android platform shell (immersive fullscreen and the Ctrl/Alt modifier-key fix).

{use_block}{platform}{saf_block}{shell}
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
fn android_main(android_app: android_activity::AndroidApp) {{
    log::info!("{{ARTCRAFT_ANDROID_SHELL_MARKER}} ready ({{}}, {{}})", saf::SAF_MARKER, ime_bridge::ime::IME_MARKER);
    apply_immersive_fullscreen(&android_app);
{persist_env_call}    system_fonts::install_font_env(&android_app);
    let saf_bridge = saf::Bridge::new(&android_app);
    saf_bridge.request_storage_permission();
    let saf_state = saf_new_state();
    let saf_inbox = SafInbox::default();
{saf_setup}    {inner_decl} = {construct_expr};
{post_construct}    let shell = AndroidShell::new(inner, android_app.clone(), saf_bridge, saf_state, saf_inbox);
    let options = eframe::NativeOptions {{
        viewport: egui::ViewportBuilder::default()
            .with_title("{title}")
            .with_drag_and_drop(true),
        android_app: Some(android_app),
        ..Default::default()
    }};
    let result = eframe::run_native(
        "{title}",
        options,
        {creator},
    );
    if let Err(error) = result {{
        log::error!("{title} Android exited with an error: {{error}}");
    }}
}}
'''
    else:
        entry = f'''//! Generated Android launcher for {title}.
//! Starts the app's egui UI with default services plus the shared Android platform shell
//! (immersive fullscreen and the Ctrl/Alt modifier-key fix).

{use_block}{platform}{saf_block}{shell}
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
fn android_main(android_app: android_activity::AndroidApp) {{
    log::info!("{{ARTCRAFT_ANDROID_SHELL_MARKER}} ready ({{}})", ime_bridge::ime::IME_MARKER);
    apply_immersive_fullscreen(&android_app);
{persist_env_call}    system_fonts::install_font_env(&android_app);
    let shell_app = android_app.clone();
    let options = eframe::NativeOptions {{
        viewport: egui::ViewportBuilder::default()
            .with_title("{title}")
            .with_drag_and_drop(true),
        android_app: Some(android_app),
        ..Default::default()
    }};
    let result = eframe::run_native(
        "{title}",
        options,
        Box::new(move |_cc| {{
            Ok(Box::new(AndroidShell::new({construct_expr}, shell_app.clone())))
        }}),
    );
    if let Err(error) = result {{
        log::error!("{title} Android exited with an error: {{error}}");
    }}
}}
'''
    (staging_dir / "src").mkdir()

    # The shared Android system-font module, referenced by `mod system_fonts;` in the entry above.
    shutil.copy2(root / "templates" / "android" / "system_fonts.rs", staging_dir / "src" / "system_fonts.rs")
    # The shared Android soft-keyboard bridge, referenced by `mod ime_bridge;` in the entry above.
    shutil.copy2(root / "templates" / "android" / "ime_bridge.rs", staging_dir / "src" / "ime_bridge.rs")

    # Audio output on Android: the apps get their audio backend from the platform layer (cpal), and
    # their desktop modules are plain cpal code compiled straight from the app's own source into the
    # launcher (no app edit). `mod audio;` / `mod audio_out;` in the entry picks them up.
    # (AUDIO_MODULES is defined above, beside the launcher dependencies it implies.)
    if app in AUDIO_MODULES:
        _, filename, _ = AUDIO_MODULES[app]
        src_audio = src / "apps" / app / "src" / filename
        if src_audio.is_file():
            shutil.copy2(src_audio, staging_dir / "src" / filename)
    (staging_dir / "src" / "lib.rs").write_text(entry)
    (staging_dir / ".artcraft-android-builder-generated").write_text(
        GENERATOR_VERSION + "\n"
        "Generated by artcraft-android-builder. Edit adapters/" + app + "/ for persistent customizations; "
        "do not hand-edit generated source if you want regeneration.\n"
    )
    # Validate the generated manifest before publishing the directory into Cargo's apps/* workspace glob.
    tomllib.loads((staging_dir / "Cargo.toml").read_text())
    staging_dir.rename(android_dir)
except BaseException:
    shutil.rmtree(staging_dir, ignore_errors=True)
    raise
print(f"Generated NativeActivity wrapper for {title}.")
print(f"  Engine crate: {engine_pkg}")
print(f"  UI crate: {ui_pkg}")
print(f"  UI app type: {app_type}")
print(f"  Icon: {icon.relative_to(src)}")
print("  Orientation: sensor (allows portrait and landscape rotation)")
PY
fi

[[ -f "$ANDROID_DIR/Cargo.toml" && -f "$ANDROID_DIR/src/lib.rs" ]] || fail "Android wrapper is incomplete at $ANDROID_DIR. See the build log and adapters/README.md."

# egui-winit's stock Android build gates its `arboard` clipboard backend behind
# `cfg(not(target_os = "android"))`, so on Android its `Clipboard` is only an in-app
# `String` — copy/paste never reaches the system clipboard. Vendor the builder's
# patched egui-winit (a self-contained JNI `ClipboardManager` backend) and patch it
# into the workspace so every app's eframe event loop uses it. The patch is
# platform-gated, so desktop builds are unaffected.
echo "Vendoring the Android-compatible egui-winit for $TITLE (system clipboard via JNI)..."
mkdir -p "$SRC/vendor"
rm -rf "$SRC/vendor/egui-winit"
cp -a "$ROOT/vendor/egui-winit" "$SRC/vendor/egui-winit"
python3 - "$SRC/Cargo.toml" <<'PY'
from pathlib import Path
import sys, tomllib
p = Path(sys.argv[1])
s = p.read_text()
entry = 'egui-winit = { path = "vendor/egui-winit" }'
import re
s = re.sub(r'^\s*egui-winit\s*=\s*\{.*?\}\s*(?:#.*)?\n?', '', s, flags=re.M)
if entry not in s:
    header = "[patch.crates-io]"
    s = (s.replace(header, header + "\n" + entry, 1) if header in s
         else s.rstrip() + "\n\n" + header + "\n" + entry + "\n")
    tomllib.loads(s)
    p.write_text(s)
PY

# Some apps call `rfd` directly from a crate that ends up in the launcher's dependency graph
# (PDFCraft does, in ~18 files), and rfd 0.17 ships no Android backend, so it fails to compile for
# `aarch64-linux-android`. Vendor the builder's Android-compatible copy (a stub backend that
# resolves dialogs to "cancelled") and patch it into the workspace so the launcher builds. Real
# open/save on Android needs a platform adapter (see adapters/README.md).
if grep -rqE '\brfd::' "$SRC"/crates/*/src 2>/dev/null; then
    echo "Vendoring an Android-compatible rfd for $TITLE (native file dialogs become no-ops)..."
    mkdir -p "$SRC/vendor"
    rm -rf "$SRC/vendor/rfd"
    cp -a "$ROOT/vendor/rfd" "$SRC/vendor/rfd"
    python3 - "$SRC/Cargo.toml" <<'PY'
from pathlib import Path
import sys, tomllib
p = Path(sys.argv[1])
s = p.read_text()
entry = 'rfd = { path = "vendor/rfd" }'
import re
s = re.sub(r'^\s*rfd\s*=\s*\{.*?\}\s*(?:#.*)?\n?', '', s, flags=re.M)
if entry not in s:
    header = "[patch.crates-io]"
    s = (s.replace(header, header + "\n" + entry, 1) if header in s
         else s.rstrip() + "\n\n" + header + "\n" + entry + "\n")
    tomllib.loads(s)
    p.write_text(s)
PY
fi

# Some apps also use arboard (the clipboard) from a crate in the launcher's dependency graph
# (PDFCraft does). arboard ships no Android backend and its Unix backend needs X11/Wayland, so it
# cannot compile for `aarch64-linux-android`. Vendor the builder's Android-compatible stub (a
# no-op clipboard) and patch it in, exactly like rfd above. Clipboard access degrades gracefully;
# real Android clipboard support needs a platform adapter (see adapters/README.md).
if grep -rqE '\barboard\b' "$SRC"/crates/*/src 2>/dev/null; then
    echo "Vendoring an Android-compatible arboard for $TITLE (clipboard access becomes a no-op)..."
    mkdir -p "$SRC/vendor"
    rm -rf "$SRC/vendor/arboard"
    cp -a "$ROOT/vendor/arboard" "$SRC/vendor/arboard"
    python3 - "$SRC/Cargo.toml" <<'PY'
from pathlib import Path
import sys, tomllib
p = Path(sys.argv[1])
s = p.read_text()
entry = 'arboard = { path = "vendor/arboard" }'
import re
s = re.sub(r'^\s*arboard\s*=\s*\{.*?\}\s*(?:#.*)?\n?', '', s, flags=re.M)
if entry not in s:
    header = "[patch.crates-io]"
    s = (s.replace(header, header + "\n" + entry, 1) if header in s
         else s.rstrip() + "\n\n" + header + "\n" + entry + "\n")
    tomllib.loads(s)
    p.write_text(s)
PY
fi

# winit's stock Android backend only translates touch actions: `handle_input_event` maps
# MotionAction::{Down,Move,Up,Cancel} to egui's `Touch` events and drops everything else
# (`_ => None // TODO mouse events`), so a connected mouse degenerated into finger taps —
# no right click, no wheel scrolling, no hover. Vendor the builder's patched winit (mouse
# buttons, wheel -> MouseWheel, hover -> CursorMoved/Entered/Left, mouse-source moves no
# longer masquerade as touch) and patch it into the workspace. PDFCraft already ships a
# forked winit on the same upstream base: only its Android backend directory is
# overwritten, so its non-Android customizations and its existing patch entry survive.
echo "Vendoring the mouse/scroll-aware winit for $TITLE..."
mkdir -p "$SRC/vendor"
if [[ -d "$SRC/vendor/winit" ]]; then
    rm -rf "$SRC/vendor/winit/src/platform_impl/android"
    cp -a "$ROOT/vendor/winit/src/platform_impl/android" "$SRC/vendor/winit/src/platform_impl/android"
else
    rm -rf "$SRC/vendor/winit"
    cp -a "$ROOT/vendor/winit" "$SRC/vendor/winit"
fi
python3 - "$SRC/Cargo.toml" <<'PY'
from pathlib import Path
import sys, tomllib
p = Path(sys.argv[1])
s = p.read_text()
entry = 'winit = { path = "vendor/winit" }'
# Remove any existing winit patch entry to avoid duplicate keys
import re
# Remove lines starting with winit = (possibly with whitespace) within patch.crates-io section
# Simple approach: remove all occurrences of lines that look like winit patch
s = re.sub(r'^\s*winit\s*=\s*\{.*?\}\s*(?:#.*)?\n?', '', s, flags=re.M)
if entry not in s:
    header = "[patch.crates-io]"
    s = (s.replace(header, header + "\n" + entry, 1) if header in s
         else s.rstrip() + "\n\n" + header + "\n" + entry + "\n")
    tomllib.loads(s)
    p.write_text(s)
PY

# The sync-picker ANR fix lives in android-activity's glue layer: while a blocking pick
# parks the Rust main thread, JVM-thread lifecycle callbacks must not block on it (they
# would be ANR'd by Android after ~5s). The builder's Android soft-keyboard bridge also
# overrides android-activity's native `show_soft_input`/`hide_soft_input` so they drive the
# Activity's own editable IME view (see templates/android/SafActivity.java) instead of the
# unreliable decor-view call. Both fixes live in the vendored copy, so any launcher that uses
# the SAF bridge (`ARTCRAFT_ANDROID_SAF_BRIDGE`) or the IME bridge (`mod ime_bridge`) needs it;
# the others keep the crates.io dependency.
if grep -qE 'ARTCRAFT_ANDROID_SAF_BRIDGE|mod ime_bridge' "$ANDROID_DIR/src/lib.rs"; then
    echo "Vendoring the ANR-safe android-activity glue for $TITLE..."
    rm -rf "$SRC/vendor/android-activity"
    cp -a "$ROOT/vendor/android-activity" "$SRC/vendor/android-activity"
    python3 - "$SRC/Cargo.toml" <<'PY'
from pathlib import Path
import sys, tomllib
p = Path(sys.argv[1])
s = p.read_text()
entry = 'android-activity = { path = "vendor/android-activity" }'
import re
s = re.sub(r'^\s*android-activity\s*=\s*\{.*?\}\s*(?:#.*)?\n?', '', s, flags=re.M)
if entry not in s:
    header = "[patch.crates-io]"
    s = (s.replace(header, header + "\n" + entry, 1) if header in s
         else s.rstrip() + "\n\n" + header + "\n" + entry + "\n")
    tomllib.loads(s)
    p.write_text(s)
PY
fi

# A `target/` directory left behind by running cargo inside a vendored crate must never be
# copied into the app tree: it is hundreds of megabytes and cargo ignores nested target dirs
# of path dependencies anyway. `rm -rf` is a no-op when the glob matches nothing.
rm -rf "$SRC/vendor"/*/target

# The Android adapter (adapters/<app>/) supplies both the complete eframe shell and the SAF
# file bridge, so the builder no longer rewrites apps/vectorcraft-android/src/lib.rs here. The
# hardcoded eframe-bridge repairs that used to live at this point were removed: they installed
# Services::default() (no file services) and could clobber the adapter.



say 5 "Preparing a builder-owned signing key..."
KEY="keys/artcraft-builder.jks"
KEY_PASSWORD_FILE="keys/.keystore-password"
mkdir -p keys
chmod 700 keys
if [[ ! -f "$KEY_PASSWORD_FILE" ]]; then
    if [[ -f "$KEY" ]]; then
        # Compatibility with earlier builder versions, which used this local-only password.
        printf 'android\n' > "$KEY_PASSWORD_FILE"
    else
        python3 -c 'import secrets; print(secrets.token_urlsafe(24))' > "$KEY_PASSWORD_FILE"
    fi
    chmod 600 "$KEY_PASSWORD_FILE"
fi
KEY_PASSWORD="$(<"$KEY_PASSWORD_FILE")"
if [[ ! -f "$KEY" ]]; then
    command -v keytool >/dev/null 2>&1 || fail "keytool is required. Install a JDK (on Fedora: sudo dnf install java-25-openjdk-devel)."
    keytool -genkeypair -noprompt -v \
        -keystore "$KEY" -storetype JKS \
        -storepass "$KEY_PASSWORD" -keypass "$KEY_PASSWORD" \
        -alias artcraftbuilder -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=ArtCraft Android Builder, OU=Local Builds, O=ArtCraft, C=US"
    chmod 600 "$KEY"
fi

# cargo-apk versions that predate signing environment variables can still use the same key.
# This path is relative to the generated Android crate's Cargo.toml and remains inside this builder.
if [[ -f "$ANDROID_DIR/.artcraft-android-builder-generated" ]]; then
    python3 - "$ANDROID_DIR/Cargo.toml" "$KEY_PASSWORD" <<'PY'
from pathlib import Path
import json, sys, tomllib
p = Path(sys.argv[1])
password = json.dumps(sys.argv[2])
s = p.read_text()
for profile in ("dev", "release"):
    section = f"[package.metadata.android.signing.{profile}]"
    if section not in s:
        s = s.rstrip() + f"\n\n{section}\npath = \"../../../../keys/artcraft-builder.jks\"\nkeystore_password = {password}\n"
tomllib.loads(s)
p.write_text(s)
PY
fi

say 6 "Building $TITLE ($MODE)..."
mkdir -p "build/$APP/target" output logs
export CARGO_TARGET_DIR="$ROOT/build/$APP/target"
STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_START_EPOCH="$(date +%s)"
LOG="logs/$APP-$MODE-$STAMP.log"
cd "$ANDROID_DIR"

# The APK is named after the version the app's own source declares, so a release built from
# `vectorcraft` v0.12.0 lands as `output/vectorcraft-0.12.0.apk` instead of a version-less
# `vectorcraft-release.apk`. Read the workspace `[workspace.package] version` (the value cargo bakes
# into the APK's own `versionName`) and fall back to the launcher crate's version for sources that do
# not pin one at the workspace level.
APP_VERSION="$(python3 - "$ROOT/$SRC" "$APP" <<'PY'
import pathlib, sys, tomllib

root, app = pathlib.Path(sys.argv[1]), sys.argv[2]
for path in (
    root / "Cargo.toml",
    root / "apps" / app / "Cargo.toml",
    root / "apps" / (app + "-android") / "Cargo.toml",
):
    try:
        data = tomllib.loads(path.read_text())
    except (OSError, tomllib.TOMLDecodeError):
        continue
    version = data.get("workspace", {}).get("package", {}).get("version")
    if not version:
        version = data.get("package", {}).get("version")
    if isinstance(version, str) and version:
        print(version)
        break
else:
    print("0.0.0")
PY
)"

# FigCraft and DeckCraft set `CRAFT_FONTS_DIR = "../craft-fonts"` (relative) in .cargo/config.toml.
# cargo-subcommand, which cargo-apk uses to locate the workspace, canonicalizes that path and aborts
# with an I/O error when the directory is absent. Create an (empty) directory so the path resolves;
# the fonts are optional and the app's build script warns and uses system fonts when they are missing.
mkdir -p "$ROOT/source/craft-fonts"

if needs_apk2 "$APP"; then APK_CMD=(cargo apk2 build); else APK_CMD=(cargo apk build); fi
if [[ "$MODE" == "release" ]]; then
    if CARGO_APK_RELEASE_KEYSTORE="$ROOT/$KEY" \
       CARGO_APK_RELEASE_KEYSTORE_PASSWORD="$KEY_PASSWORD" \
       "${APK_CMD[@]}" --release 2>&1 | tee "$ROOT/$LOG"; then
        :
    else
        status=$?
        fail "Release build failed (exit $status). Log: $ROOT/$LOG"
    fi
    FINAL_APK="$ROOT/output/$APP-$APP_VERSION.apk"
else
    if CARGO_APK_DEV_KEYSTORE="$ROOT/$KEY" \
       CARGO_APK_DEV_KEYSTORE_PASSWORD="$KEY_PASSWORD" \
       "${APK_CMD[@]}" 2>&1 | tee "$ROOT/$LOG"; then
        :
    else
        status=$?
        fail "Debug build failed (exit $status). Log: $ROOT/$LOG"
    fi
    FINAL_APK="$ROOT/output/$APP-$APP_VERSION-debug.apk"
fi

# cargo-apk and cargo-apk2 have used slightly different APK output subdirectories/names.
# Prefer an APK freshly produced by this invocation; fall back to the legacy path for older versions.
BUILT_APK="$(find "$CARGO_TARGET_DIR" -type f -name '*.apk' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk -v started="$BUILD_START_EPOCH" '$1 >= started - 3 { $1=""; sub(/^ /, ""); print; exit }')"
if [[ -z "$BUILT_APK" ]]; then
    if [[ "$MODE" == "release" && -f "$CARGO_TARGET_DIR/release/apk/$APP.apk" ]]; then
        BUILT_APK="$CARGO_TARGET_DIR/release/apk/$APP.apk"
    elif [[ "$MODE" == "debug" && -f "$CARGO_TARGET_DIR/debug/apk/$APP.apk" ]]; then
        BUILT_APK="$CARGO_TARGET_DIR/debug/apk/$APP.apk"
    fi
fi

[[ -n "$BUILT_APK" && -f "$BUILT_APK" ]] || {
    echo "Expected a newly built APK under $CARGO_TARGET_DIR" >&2
    echo "Searching generated artifacts:" >&2
    find "$CARGO_TARGET_DIR" -type f -name '*.apk' -print >&2 || true
    fail "Build command returned success but the APK artifact was not found. Log: $ROOT/$LOG"
}
cp -f "$BUILT_APK" "$FINAL_APK"

say 7 "Verifying the Android file bridge in the built APK..."
verify_android_bridge "$APP" "$BUILT_APK"

say 8 "Build succeeded."
echo "App: $TITLE"
echo "Mode: $MODE"
echo "APK: $FINAL_APK"
echo "Size: $(du -h "$FINAL_APK" | awk '{print $1}')"
echo "SHA-256: $(sha256sum "$FINAL_APK" | awk '{print $1}')"
echo "Log: $ROOT/$LOG"
echo
echo "This is a locally signed build. Keep keys/artcraft-builder.jks for compatible future updates."
echo "Public distribution should use a separately managed signing key."
