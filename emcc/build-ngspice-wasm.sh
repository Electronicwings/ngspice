#!/usr/bin/env bash
# Build a STATIC, -pthread libngspice.a for a multi-threaded WASM host.
#
# Lives beside run.sh, the other build entrypoint in this repo. run.sh produces
# the single-threaded CLI module (ngspice.js/.wasm) and the shared library; this
# one produces the archive a -pthread application can actually LINK. Like
# run.sh, it clones the ngspice SOURCE inside the container — this repository is
# the build harness, not the source tree.
#
# WHY THIS EXISTS
# ---------------
# The prebuilt `libngspice.so.0.0.15` from danchitnis/ngspice CANNOT be linked
# into SimulIDE. Two reasons, both verified:
#
#   1. It is a fully-linked wasm MODULE, not an archive (`old_library=''` in
#      libngspice.la), so it embeds the libc objects it pulled in — including
#      single-threaded `__pthread_exit` and `_emscripten_yield`.
#   2. It was built without -pthread (no `atomics` in its target-features).
#
# SimulIDE links `-pthread -s PTHREAD_POOL_SIZE=4` against Qt wasm_multithread,
# so emscripten's MT libc defines those same symbols and wasm-ld fails with:
#
#   wasm-ld: error: duplicate symbol: __pthread_exit
#   wasm-ld: error: duplicate symbol: _emscripten_yield
#
# (qucs-s links the .so happily because its wasm build is effectively
# single-threaded — that does not carry over to SimulIDE.)
#
# The fix is to produce a STATIC archive built WITH -pthread, i.e. exactly the
# shape SimulIDE's dependencies/binutils-avr already ships:
#
#   $ strings -n6 .../libbfd.a | grep -E '^atomics'
#   atomics+
#
# USAGE
# -----
#   ./build-ngspice-wasm.sh [output-dir]
#
# Default output: emcc/build, next to the artifacts run.sh produces. That is the
# path SimulIDE.pri points at (utils/ngspice/emcc/build), so a plain run needs
# no arguments and no configuration. `build` is gitignored, so the 12 MB archive
# stays a local artifact rather than entering the repo. Needs docker.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/build}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

echo "==> building libngspice.a (static, -pthread) into $OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/build.sh" <<'INNER'
#!/bin/bash
set -euo pipefail

# emsdk is baked into the image (see Dockerfile) so retries don't re-download it.
source /opt/emsdk/emsdk_env.sh

cd /opt
rm -rf ngspice-src
# NOT --depth 1: we pin to the revision the known-good build used. Current
# master fails under --disable-xspice with
#   cktsopt.c: error: use of undeclared identifier 'OPT_ENH_RSHUNT'
# (the case label is not guarded the way the enum member is). Override with
# NGSPICE_REV=<sha> to try a different revision.
git clone --shallow-since="${NGSPICE_SINCE:-2026-01-01}" \
    https://github.com/danchitnis/ngspice-sf-mirror ngspice-src
cd ngspice-src

REV="${NGSPICE_REV:-}"
if [ -z "$REV" ]; then
    REV="$(git rev-list -1 --before="${NGSPICE_BEFORE:-2026-04-25}" HEAD)"
fi
[ -n "$REV" ] || { echo "FAIL: could not resolve an ngspice revision"; exit 1; }
git checkout --detach "$REV"
echo "=== ngspice revision: $(git log -1 --format='%h %ad %s' --date=short)"

# Upstream fixes needed under emscripten (from danchitnis' run.sh).
sed -i 's/-Wno-unused-but-set-variable/-Wno-unused-const-variable/g' ./configure.ac
sed -i 's/AC_CHECK_FUNCS(\[time getrusage\])/AC_CHECK_FUNCS([time])/g'  ./configure.ac

./autogen.sh
mkdir -p release && cd release

# --enable-static (and NOT --disable-shared): we want the .a, but --with-ngshared
#     wires libngspice up as a libtool shared library, so disabling shared makes
#     libtool abort with "cannot build a shared library / Fatal configuration
#     error". Enabling BOTH makes libtool compile every object twice and emit a
#     real archive next to the .so. The archive is what we link: it holds only
#     ngspice's own objects, so it brings no embedded libc and no duplicate
#     __pthread_exit / _emscripten_yield.
# -pthread : emits the `atomics` target feature so the objects are legal in a
#     shared-memory link, and leaves libc references UNRESOLVED for the app's
#     MT libc to satisfy.
#
# -pthread is baked into CC/CXX rather than passed in CFLAGS: ngspice's
# configure rewrites CFLAGS, and a build #2 that passed it there produced
# objects with no `atomics` feature. As part of the compiler command it
# cannot be dropped.
emconfigure ../configure \
    --with-ngshared \
    --enable-static --enable-shared \
    --disable-debug --with-readline=no --disable-openmp --disable-xspice \
    CC="emcc -pthread" CXX="em++ -pthread" \
    CFLAGS="-O2" CXXFLAGS="-O2" LDFLAGS="-pthread"

# Fail fast if the flag still did not survive, rather than after a long build.
cat > /tmp/feat.c <<'EOF'
int probe(void){ return 0; }
EOF
emcc -pthread -c /tmp/feat.c -o /tmp/feat.o
if ! strings -n 6 /tmp/feat.o | grep -qx 'atomics+'; then
    echo "FAIL: even a bare 'emcc -pthread' object has no 'atomics' feature."
    echo "      The emsdk in this image is not usable for a threaded build."
    exit 1
fi

# Don't abort on a failed FINAL shared-library link: the static archive is
# produced earlier and is all we need.
emmake make -j"$(nproc)" || echo "!! make reported errors — looking for the archive anyway"

mkdir -p /mnt/out
rm -f /mnt/out/libngspice.a          # never let a stale archive look like success

# sharedspice.c defines ngSpice_Init and is compiled LAST, as part of the
# library link. If it is missing the build died partway and any archive we
# could assemble would be useless — say so plainly instead of shipping it.
if ! find . -name '*sharedspice*.o' -print -quit | grep -q .; then
    echo
    echo "FAIL: sharedspice.o was never compiled, so the build did not reach the"
    echo "      library stage. Scroll up to the FIRST compiler error — that is"
    echo "      the real failure; everything after it is fallout."
    exit 1
fi

ARCHIVE="$(find . -name 'libngspice.a' -print -quit || true)"

if [ -n "$ARCHIVE" ]; then
    echo "=== found libtool archive: $ARCHIVE"
    cp "$ARCHIVE" /mnt/out/
else
    # Fallback: assemble the archive from libtool's compiled objects. Under
    # emscripten PIC vs non-PIC is meaningless, so .libs/*.o are fine.
    # Exclude main.o (a second entry point would clash with SimulIDE's own
    # main()) and configure's conftest scratch objects.
    echo "=== no libtool archive; assembling one with emar"
    find . -name '*.o' ! -name 'main.o' ! -name 'conftest*' > /tmp/objs.txt
    if [ ! -s /tmp/objs.txt ]; then echo "FAIL: no objects were built"; exit 1; fi
    echo "    $(wc -l < /tmp/objs.txt) objects"
    emar rcs /mnt/out/libngspice.a @/tmp/objs.txt \
      || xargs -a /tmp/objs.txt emar rcs /mnt/out/libngspice.a
fi

cp ../src/include/ngspice/sharedspice.h /mnt/out/

echo "=== produced ==="
ls -la /mnt/out/
INNER
chmod +x "$WORK/build.sh"

cat > "$WORK/Dockerfile" <<'DOCKER'
FROM fedora:latest
RUN dnf -y install autoconf automake make cmake bzip2 gcc-c++ libstdc++-static \
                   libtool bison xz which git wget curl python3 \
 && dnf clean all

# emsdk lives in its own layer so retrying the ngspice build does not
# re-download ~1GB. 4.0.7 MUST match the emsdk Qt 6.11.0 was built with,
# or the objects will not link.
RUN git clone --depth 1 https://github.com/emscripten-core/emsdk.git /opt/emsdk \
 && cd /opt/emsdk \
 && ./emsdk install  4.0.7 \
 && ./emsdk activate 4.0.7

COPY build.sh /build.sh
ENTRYPOINT ["/build.sh"]
DOCKER

docker build -t ngspice-wasm:pthread "$WORK"
docker run --rm -v "$OUT:/mnt/out" ngspice-wasm:pthread

echo
echo "==> verifying"
test -f "$OUT/libngspice.a" || { echo "FAIL: libngspice.a not produced"; exit 1; }

# NOTE: results are captured into variables first, deliberately. `cmd | grep -q`
# under `set -o pipefail` reports FAILURE on a MATCH: grep exits at the first hit,
# the producer dies of SIGPIPE (141), and pipefail surfaces that as the pipeline
# status. That inverted every check here once already.
fail=0

FEATS="$(strings -n 6 "$OUT/libngspice.a" \
         | grep -E '^(atomics|bulk-memory|mutable-globals|sign-ext|simd128|reference-types)\+' \
         | sort -u || true)"
if [[ "$FEATS" == *"atomics+"* ]]; then
    echo "OK  : built with -pthread ('atomics' target feature present)"
else
    echo "FAIL: no 'atomics' feature — will not link into the -pthread build."
    echo "      Features actually present:"
    printf '%s\n' "$FEATS" | sed 's/^/        /'
    fail=1
fi

NM="$(command -v llvm-nm || echo "$HOME/emsdk/upstream/bin/llvm-nm")"
if [ -x "$NM" ]; then
    SYMS="$("$NM" "$OUT/libngspice.a" 2>/dev/null || true)"
    missing=""
    for s in ngSpice_Init ngSpice_Command ngGet_Vec_Info ngSpice_CurPlot ngSpice_AllVecs; do
        [[ "$SYMS" == *" T $s"* ]] || missing="$missing $s"
    done
    if [ -z "$missing" ]; then
        echo "OK  : exports the shared API (ngSpice_Init, ngSpice_Command, ngGet_Vec_Info, ...)"
    else
        echo "FAIL: missing symbols:$missing — was --with-ngshared applied?"
        fail=1
    fi
fi

[ "$fail" = 0 ] || exit 1
echo "==> done. Re-run qmake so SimulIDE.pri picks it up:"
echo "    it should print  libngspice: linking $OUT/libngspice.a"
