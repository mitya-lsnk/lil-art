#!/bin/bash
# Builds "lil art.app" from app/Sources/LilArt and the command-line generator
# tools/lilart-gen from app/Sources/LilArtGen, both inside the project folder (see tools/GEN.md).
#
#   build.sh        both
#   build.sh app    only the app
#   build.sh gen    only the generator (leaves a running app's bundle alone)
#
# Everything lives under build/ in the project folder so a cleared temp directory never costs us
# the 40-minute engine build again. Safe to re-run: the clone, the patch and the
# extra package targets are all idempotent.
set -euo pipefail

WHAT="${1:-all}"
case "$WHAT" in
  all|app|gen) ;;
  *) echo "использование: build.sh [all|app|gen]"; exit 2 ;;
esac

# The project is wherever this script lies, as the real path with no links: it is never assumed
# to be under $HOME. The program gets it built into its Info.plist (LilRoot); lilart-gen finds
# it from its own place in tools/.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORK="$ROOT/build"
SRC="$ROOT/app/Sources/LilArt"
GEN_SRC="$ROOT/app/Sources/LilArtGen"
# Logic with no engine and no window in it lives in its own small package, where `swift test`
# runs in seconds (app/Core). Its files are copied into the app and the generator like the
# rest, so nothing about how they are built changes.
CORE="$ROOT/app/Core/Sources/LilArtCore"
# The finished bundle is put together in a ".noindex" folder, which Spotlight never looks
# into, so search shows only the installed copy in /Applications.
APP="$ROOT/build.noindex/lil art.app"
INSTALLED="/Applications/lil art.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
GEN="$ROOT/tools/lilart-gen"
PKG="https://github.com/drawthingsai/media-generation-kit.git"

echo "==> рабочая папка: $WORK"
mkdir -p "$WORK"

if [ ! -d "$WORK/mgk/.git" ]; then
  echo "==> клонирую media-generation-kit"
  git clone --depth 1 "$PKG" "$WORK/mgk"
fi
cd "$WORK/mgk"

echo "==> добавляю наши цели в Package.swift"
python3 - <<'PY'
p = 'Package.swift'
s = open(p).read()
if 'name: "LilArt"' not in s:
    s = s.replace('''    .executableTarget(
      name: "MediaGenerationKitCLI",''', '''    .executableTarget(
      name: "LilArt",
      dependencies: ["MediaGenerationKit"]
    ),
    .executableTarget(
      name: "MediaGenerationKitCLI",''')
    s = s.replace('''    .executable(name: "media-generation-kit-cli", targets: ["MediaGenerationKitCLI"]),''',
                  '''    .executable(name: "media-generation-kit-cli", targets: ["MediaGenerationKitCLI"]),
    .executable(name: "LilArt", targets: ["LilArt"]),''')
    open(p, 'w').write(s)
    print("   цели добавлены")
else:
    print("   уже на месте")
if 'name: "LilArtGen"' not in s:
    cli_target = '''    .executableTarget(
      name: "MediaGenerationKitCLI",'''
    cli_product = '''    .executable(name: "media-generation-kit-cli", targets: ["MediaGenerationKitCLI"]),'''
    if cli_target not in s or cli_product not in s:
        raise SystemExit("   ЦЕЛЬ lilart-gen НЕ ВСТАЛА — Package.swift изменился, проверить вручную")
    s = s.replace(cli_target, '''    .executableTarget(
      name: "LilArtGen",
      dependencies: ["MediaGenerationKit"]
    ),
''' + cli_target, 1)
    s = s.replace(cli_product, cli_product + '''
    .executable(name: "lilart-gen", targets: ["LilArtGen"]),''', 1)
    open(p, 'w').write(s)
    print("   цель lilart-gen добавлена")
PY
# the generator's own file plus what it shares with the app: the PNG encoder and the
# conversion of VAEs and encoders (--check-part, --import-part)
mkdir -p Sources/LilArtGen
rm -f Sources/LilArtGen/*.swift
cp "$GEN_SRC"/*.swift Sources/LilArtGen/
cp "$SRC/TensorImage.swift" "$SRC/ModelParts.swift" "$SRC/WeightCompressor.swift" Sources/LilArtGen/
cp "$CORE/ScaledCheckpoint.swift" "$CORE/Storage.swift" "$CORE/ProjectRoot.swift" "$CORE/GenArguments.swift" "$CORE/GenCommand.swift" Sources/LilArtGen/
# the settings store lies in the shared lil file, which brings its generated companion along
cp "$SRC/LilKit.swift" "$SRC/LilApp.swift" Sources/LilArtGen/

echo "==> поднимаю движок до свежей версии"
python3 - <<'PYEOF'
import re
# The wrapper pins an engine revision from July that does not know the newer model
# families. We run the current one instead; the app is GPL anyway, which is what that
# revision's licence asks for.
# Pinned to the commit of a tagged release (v26.1023.0), the same one their standalone
# server binary is built from, so the client and the engine agree on model families and
# configuration fields. Untagged main is not used: it has at times expected a newer s4nnc
# than its own Package.swift pins, and then it does not compile.
NEW = "0670fa63531cae31766df7a50d9067b33d51c048"
p = 'Package.swift'
s = open(p).read()
s2 = re.sub(r'(draw-things-community\.git",\s*\n\s*revision: ")[0-9a-f]{40}(")',
            lambda m: m.group(1) + NEW + m.group(2), s)
# The root manifest also names s4nnc (for NNC, below) at the old engine's revision; left
# there, it asks for a different ccv than the new engine and resolve refuses. It is moved to
# the new engine's own s4nnc before resolving, read from SwiftPM's cached copy of the repo.
import glob, subprocess
for repo in glob.glob('.build/repositories/draw-things-community-*'):
    try:
        dt = subprocess.run(['git', '-C', repo, 'show', NEW + ':Package.swift'],
                            capture_output=True, text=True, check=True).stdout
    except Exception:
        continue
    m = re.search(r's4nnc\.git",\s*\n\s*revision: "([0-9a-f]{40})"', dt)
    if m:
        s2 = re.sub(r'(\.package\(url: "https://github\.com/liuliu/s4nnc\.git", revision: ")[0-9a-f]{40}(")',
                    lambda x: x.group(1) + m.group(1) + x.group(2), s2)
    break
if s2 != s:
    open(p, 'w').write(s2)
    print("   движок -> " + NEW[:12])
else:
    print("   уже на нужной версии" if NEW in s else "   ВНИМАНИЕ: строку с версией не нашёл")
PYEOF

echo "==> разрешаю зависимости"
swift package resolve

echo "==> подключаю NNC: через него приложение сжимает модели до 8 бит"
python3 - <<'PY'
import re, sys
# s4nnc is already in the build as the engine's own dependency; only a package the root
# manifest names can hand its library to our targets, so it is named here at exactly the
# revision the engine pins.
dt = open('.build/checkouts/draw-things-community/Package.swift').read()
m = re.search(r's4nnc\.git",\s*\n\s*revision: "([0-9a-f]{40})"', dt)
if not m:
    sys.exit("   не нашёл версию s4nnc в манифесте движка")
rev = m.group(1)
p = 'Package.swift'
s = open(p).read()
orig = s
s = re.sub(r'\n    \.package\(url: "https://github\.com/liuliu/s4nnc\.git", revision: "[0-9a-f]{40}"\),', '', s)
s = s.replace('  dependencies: [\n    .package(\n      url: "https://github.com/drawthingsai/draw-things-community.git",',
              '  dependencies: [\n    .package(url: "https://github.com/liuliu/s4nnc.git", revision: "%s"),\n'
              '    .package(\n      url: "https://github.com/drawthingsai/draw-things-community.git",' % rev, 1)
for target in ("LilArt", "Probe", "LilArtGen"):
    s = s.replace('      name: "%s",\n      dependencies: ["MediaGenerationKit"]\n' % target,
                  '      name: "%s",\n      dependencies: ["MediaGenerationKit", .product(name: "NNC", package: "s4nnc")]\n' % target)
if 's4nnc.git' not in s or any(
        'name: "%s",\n      dependencies: ["MediaGenerationKit", .product(name: "NNC"' % t not in s
        for t in ("LilArt", "LilArtGen")):
    sys.exit("   ЗАВИСИМОСТЬ NNC НЕ ВСТАЛА — Package.swift изменился, проверить вручную")
if s != orig:
    open(p, 'w').write(s)
    open('.nnc-changed', 'w').write(rev)
    print("   подключён, s4nnc " + rev[:12])
else:
    print("   уже подключён")
PY
if [ -f .nnc-changed ]; then rm .nnc-changed; swift package resolve; fi

echo "==> заплатка предпросмотра: без мини-декодеров Draw Things"
python3 - <<'PY'
import os, sys
# The live preview of a run is decoded on this side. The kit always asks for the tiny
# CoreML decoders ("TAESD"), whose weights ship only inside the Draw Things app bundle;
# the engine source force-unwraps their bundle URL, so in any other app the first preview
# of most model families aborts the whole process. Without them the kit falls back to its
# plain latent-to-colour conversion: coarser, but a preview is only a preview.
p = '.build/checkouts/draw-things-community/Libraries/MediaGenerationKit/Sources/MediaGenerationImageCodec.swift'
if not os.path.exists(p):
    sys.exit("   нет MediaGenerationImageCodec.swift — resolve не отработал")
os.chmod(p, 0o644)
s = open(p).read()
start = s.find('static func previewImage(')
end = s.find('\n  }', start)
if start < 0 or end < 0:
    sys.exit("   ЗАПЛАТКА НЕ ЛЕГЛА — previewImage не найден, проверить вручную")
body = s[start:end]
if 'canUseTAESD: false' in body:
    print("   уже пропатчен")
elif 'canUseTAESD: true' in body:
    open(p, 'w').write(s[:start] + body.replace('canUseTAESD: true', 'canUseTAESD: false') + s[end:])
    print("   пропатчен")
else:
    sys.exit("   ЗАПЛАТКА НЕ ЛЕГЛА — код предпросмотра изменился, проверить вручную")
PY

echo "==> заплатка подсказок ControlNet: поза, набросок, цвет, свой контур"
python3 - <<'PY'
import os, sys
# The kit hands the engine only four kinds of picture: the canvas, a mask, moodboard pictures
# and a depth map. ControlNets for pose, scribble, colour and line art need a ready control
# picture of their own kind, which the engine accepts as a hint of that name; the kit just
# has no way to say so. One more input role, `.hint("pose")`, passes such a picture through
# as a hint of that type, the same way the depth map already goes.
p = '.build/checkouts/draw-things-community/Libraries/MediaGenerationKit/Sources/MediaGenerationPipeline.swift'
if not os.path.exists(p):
    sys.exit("   нет MediaGenerationPipeline.swift — resolve не отработал")
os.chmod(p, 0o644)
s = open(p).read()
if 'case hint(String)' in s:
    print("   уже пропатчен")
    sys.exit(0)
HINT_INPUT = """  /// Wraps an image input as a ready ControlNet hint of the named type ("pose", "scribble",
  /// "color", "custom"), for ControlNets that cannot make their input from the canvas.
  public struct HintInput: MediaGenerationInput {
    public let source: any MediaGenerationImageInput
    public let name: String

    public init(_ source: any MediaGenerationImageInput, name: String) {
      self.source = source
      self.name = name
    }

    public var role: InputRole {
      .hint(name)
    }
  }

"""
DEPTH_CASE = """      case .depth:
        depthImages.append(
          MediaGenerationExecutionHintImage(
            data: try encodedImageData(from: input),
            weight: 1.0
          ))
      }"""
HINT_CASE = """      case .depth:
        depthImages.append(
          MediaGenerationExecutionHintImage(
            data: try encodedImageData(from: input),
            weight: 1.0
          ))
      case .hint(let name):
        guard let type = ControlHintType(rawValue: name) else {
          throw MediaGenerationKitError.generationFailed("unknown hint type \\(name)")
        }
        let image = MediaGenerationExecutionHintImage(
          data: try encodedImageData(from: input), weight: 1.0)
        if let index = namedHints.firstIndex(where: { $0.0 == type }) {
          namedHints[index].1.append(image)
        } else {
          namedHints.append((type, [image]))
        }
      }"""
DEPTH_HINTS = """    if !depthImages.isEmpty {
      hints.append(MediaGenerationExecutionHint(type: .depth, images: depthImages))
    }"""
DEPTH_DATA = """    if let depth = input as? DepthInput,
      let source = depth.source as? MediaGenerationImageDataSource
    {
      return try source.mediaGenerationEncodedData()
    }"""
HINT_DATA = """
    if let hint = input as? HintInput,
      let source = hint.source as? MediaGenerationImageDataSource
    {
      return try source.mediaGenerationEncodedData()
    }"""
DEPTH_FUNC = """  public func depth() -> MediaGenerationPipeline.Input {
    MediaGenerationPipeline.DepthInput(self)
  }"""
HINT_FUNC = """

  public func hint(_ name: String) -> MediaGenerationPipeline.Input {
    MediaGenerationPipeline.HintInput(self, name: name)
  }"""
STATE = "  /// Progress states emitted during generation.\n  public enum State: Sendable {"
steps = [
    ("    case moodboard\n    case depth\n  }", "    case moodboard\n    case depth\n    case hint(String)\n  }"),
    (STATE, HINT_INPUT + STATE),
    ("    var depthImages: [MediaGenerationExecutionHintImage] = []\n",
     "    var depthImages: [MediaGenerationExecutionHintImage] = []\n"
     "    var namedHints: [(ControlHintType, [MediaGenerationExecutionHintImage])] = []\n"),
    (DEPTH_CASE, HINT_CASE),
    (DEPTH_HINTS, DEPTH_HINTS + "\n    for (type, images) in namedHints {\n"
     "      hints.append(MediaGenerationExecutionHint(type: type, images: images))\n    }"),
    (DEPTH_DATA, DEPTH_DATA + HINT_DATA),
    (DEPTH_FUNC, DEPTH_FUNC + HINT_FUNC),
]
for old, new in steps:
    if s.count(old) != 1:
        sys.exit("   ЗАПЛАТКА НЕ ЛЕГЛА — код кита изменился, проверить вручную: " + old[:60])
    s = s.replace(old, new)
open(p, 'w').write(s)
print("   пропатчен")
PY

echo "==> заплатка Metal 4 для нейроускорителей M5"
python3 - <<'PY'
import glob, os, sys
d = '.build/checkouts/ccv/lib/nnc/mfa/kernels'
if not os.path.isdir(d):
    sys.exit("   нет папки ccv — resolve не отработал")
old = 'library = NS::TransferPtr(device->newLibrary(string, nil, &error));'
new = '''{
    // Neural-accelerator kernels emit <metal_tensor> / MetalPerformancePrimitives
    // tensor-op code, which only parses under the Metal 4 language version. Passing
    // nil compile options leaves the default (3.x), so every mpp::tensor_ops
    // identifier comes back "undeclared" and the process traps on first generation.
    auto compileOptions = NS::TransferPtr(MTL::CompileOptions::alloc()->init());
    compileOptions->setLanguageVersion(MTL::LanguageVersion(4 << 16));
    library = NS::TransferPtr(device->newLibrary(string, compileOptions.get(), &error));
  }'''
done = 0
for f in sorted(glob.glob(os.path.join(d, 'NA*.cpp'))):
    os.chmod(f, 0o644)
    s = open(f).read()
    if old in s:
        n = s.count(old)
        open(f, 'w').write(s.replace(old, new))
        print(f"   пропатчен {os.path.basename(f)} ({n})")
        done += n
    elif 'setLanguageVersion' in s:
        print(f"   уже пропатчен {os.path.basename(f)}")
        done += 1
if done == 0:
    sys.exit("   ЗАПЛАТКА НЕ ЛЕГЛА — код ccv изменился, проверить вручную")
PY

if [ "$WHAT" != gen ]; then
echo "==> копирую исходники приложения"
mkdir -p Sources/LilArt
rm -f Sources/LilArt/*.swift
cp "$SRC"/*.swift "$CORE"/*.swift Sources/LilArt/

echo "==> собираю (первый раз это долго)"
swift build -c release --product LilArt

echo "==> собираю бандл"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LilArt "$APP/Contents/MacOS/lil art"
chmod +x "$APP/Contents/MacOS/lil art"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/design/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>lil art</string>
  <key>CFBundleDisplayName</key><string>lil art</string>
  <key>CFBundleExecutable</key><string>lil art</string>
  <key>CFBundleIdentifier</key><string>com.lil.art</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.9.2</string>
  <key>CFBundleVersion</key><string>16</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"
# the real path of the project, known only now (the file above is written without expanding anything)
/usr/libexec/PlistBuddy -c "Add :LilRoot string $ROOT" "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify "$APP"
# the build's copy is not an app the Mac should know about
"$LSREGISTER" -u "$APP" || true

echo "==> ставлю в /Applications"
if [ -e "$INSTALLED" ]; then
  # The old version is kept beside the build, never put in the Trash: a cleaner watching the
  # Trash (Pearcleaner) then removes the app's "leftovers" too — its settings and the
  # links in the home folder, which is how the models once went missing.
  OLD="$ROOT/build.noindex/old"
  mkdir -p "$OLD"
  rm -rf "$OLD/lil art.app"
  mv "$INSTALLED" "$OLD/lil art.app"
  "$LSREGISTER" -u "$OLD/lil art.app" || true
fi
ditto "$APP" "$INSTALLED"
"$LSREGISTER" -f "$INSTALLED"
echo "==> готово: $INSTALLED"
fi

if [ "$WHAT" != app ]; then
echo "==> собираю lilart-gen"
swift build -c release --product lilart-gen
# copied through a temporary name so a caller never runs a half-written binary
cp .build/release/lilart-gen "$GEN.tmp"
mv -f "$GEN.tmp" "$GEN"
echo "==> готово: $GEN"
fi
