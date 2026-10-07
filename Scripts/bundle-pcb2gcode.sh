#!/bin/bash
# Copies pcb2gcode and every library it loads into the app bundle, so users
# need nothing installed. Run by the "Bundle pcb2gcode" build phase; the
# developer machine needs Homebrew's pcb2gcode (brew install pcb2gcode).
#
#   Contents/Helpers/pcb2gcode                    the program
#   Contents/Helpers/lib/*.dylib                  its libraries, via @rpath
#   Contents/Resources/LICENSE-pcb2gcode.txt      GPL-3.0 notice (pcb2gcode
#                                                 ships as a separate program)
#
# Only signed code may sit in Helpers, so the notice and the up-to-date stamp
# live in Resources.
#
# Usage: bundle-pcb2gcode.sh <Helpers dir> [codesign identity]
set -euo pipefail

DEST="${1:?usage: bundle-pcb2gcode.sh <Helpers dir> [identity]}"
IDENTITY="${2:--}"

# The App Store build (AppStore configuration) ships without pcb2gcode — it
# is GPL-3, which the App Store terms are widely held to conflict with — and
# uses the native engine only.
if [ "${BUNDLE_PCB2GCODE:-YES}" = "NO" ]; then
    rm -rf "$DEST"
    rm -f "$(dirname "$DEST")/Resources/LICENSE-pcb2gcode.txt" "$(dirname "$DEST")/Resources/pcb2gcode-bundled-from.txt"
    echo "note: BUNDLE_PCB2GCODE=NO — building without pcb2gcode (native engine only)."
    exit 0
fi
SOURCE="$(command -v pcb2gcode || true)"
[ -z "$SOURCE" ] && [ -x /opt/homebrew/bin/pcb2gcode ] && SOURCE=/opt/homebrew/bin/pcb2gcode
[ -z "$SOURCE" ] && [ -x /usr/local/bin/pcb2gcode ] && SOURCE=/usr/local/bin/pcb2gcode
if [ -z "$SOURCE" ]; then
    echo "warning: pcb2gcode not found on this Mac — the app is built without it (brew install pcb2gcode)."
    exit 0
fi
SOURCE="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SOURCE")"

RESOURCES="$(dirname "$DEST")/Resources"
mkdir -p "$RESOURCES"

# Up to date already? (Same source binary, same signing identity.)
STAMP="$RESOURCES/pcb2gcode-bundled-from.txt"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$SOURCE|$IDENTITY|sandboxed" ] && [ -x "$DEST/pcb2gcode" ]; then
    exit 0
fi

rm -rf "$DEST"
mkdir -p "$DEST/lib"

# Every non-system library, resolved through @rpath / @loader_path.
python3 - "$SOURCE" "$DEST" <<'PY'
import os, shutil, subprocess, sys
source, dest = sys.argv[1], sys.argv[2]
lib = os.path.join(dest, "lib")

def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout

def deps(f):
    return [l.strip().split(" (")[0] for l in run("otool", "-L", f).splitlines()[1:] if l.strip()]

def rpaths(f):
    lines = run("otool", "-l", f).splitlines()
    return [lines[i + 2].split()[1] for i, l in enumerate(lines) if "LC_RPATH" in l]

def resolve(ref, owner):
    here = os.path.dirname(owner)
    if ref.startswith("@loader_path/"):
        return os.path.join(here, ref[len("@loader_path/"):])
    if ref.startswith("@rpath/"):
        name = ref[len("@rpath/"):]
        for rp in rpaths(owner) + [here, "/opt/homebrew/lib", "/usr/local/lib"]:
            c = os.path.join(rp.replace("@loader_path", here), name)
            if os.path.exists(c):
                return c
    return ref

def system(ref):
    return ref.startswith("/usr/lib/") or ref.startswith("/System/")

# Walk the dependency graph from the program.
copied = {}                 # real source path -> bundled name
todo = [source]
refs = {}                   # file -> [(reference as written, real path)]
while todo:
    f = todo.pop()
    refs[f] = []
    for ref in deps(f):
        if system(ref):
            continue
        real = os.path.realpath(resolve(ref, f))
        if real == os.path.realpath(f):
            continue        # the library's own install name
        refs[f].append((ref, real))
        if real not in copied:
            copied[real] = os.path.basename(ref)   # the name others load it by
            todo.append(real)

prog = os.path.join(dest, "pcb2gcode")
shutil.copy2(source, prog)
for real, name in copied.items():
    shutil.copy2(real, os.path.join(lib, name))

def fix(path, original, is_prog):
    os.chmod(path, 0o755)
    for ref, real in refs[original]:
        run("install_name_tool", "-change", ref, "@rpath/" + copied[real], path)
    for rp in rpaths(path):
        run("install_name_tool", "-delete_rpath", rp, path)
    run("install_name_tool", "-add_rpath", "@executable_path/lib" if is_prog else "@loader_path", path)
    if not is_prog:
        run("install_name_tool", "-id", "@rpath/" + os.path.basename(path), path)

fix(prog, source, True)
for real, name in copied.items():
    fix(os.path.join(lib, name), real, False)
print(f"Bundled pcb2gcode with {len(copied)} libraries into {dest}")
PY

# Sign libraries first, then the program. With a real identity the program
# gets the hardened runtime, like the app (library validation then needs the
# libraries signed by the same team, which they are). Ad-hoc signing ("-")
# gives every file its own identity, so the runtime flag is left off there.
for f in "$DEST"/lib/*.dylib; do
    codesign --force --timestamp=none --sign "$IDENTITY" "$f" 2>/dev/null
done
RUNTIME=()
[ "$IDENTITY" != "-" ] && RUNTIME=(--options runtime)
# The app is sandboxed, so the helper must be too: it inherits the app's
# sandbox (App Store review requires exactly these two entitlements).
codesign --force --timestamp=none ${RUNTIME[@]+"${RUNTIME[@]}"} \
    --entitlements "$(dirname "$0")/pcb2gcode-helper.entitlements" --sign "$IDENTITY" "$DEST/pcb2gcode" 2>/dev/null

cat > "$RESOURCES/LICENSE-pcb2gcode.txt" <<'TXT'
pcb2gcode — https://github.com/pcb2gcode/pcb2gcode
Licensed under the GNU General Public License v3.0 or later.
It is included as a separate program, run as a subprocess; its source is
available at the address above. Its libraries (Boost, gerbv, GLib, cairo and
their dependencies) are under their own open-source licences.
TXT

echo "$SOURCE|$IDENTITY|sandboxed" > "$STAMP"
