#!/bin/bash
# Compile GHC 9.4.8 from the unpacked release sources.
# Boot compiler: ghc90 / ghc-pkg90 (in-chain GHC 9.0.2).
# Happy 1.20.1.1 and alex 3.2.7.4 are compiled from the vendored
# tarballs in bootstrap/. This script does not copy a finished prefix.
set -euo pipefail

ROOT=${1:?usage: ghc94-build.sh ROOT}
case "$ROOT" in
*/ghc94-work|*/ghc94-work/*|*/ghc98-work|*/ghc98-work/*)
	printf 'GHC94_FAILED: refusing to build inside an existing prefix tree\n'
	exit 1
	;;
esac

TREE=$ROOT/ghc-9.4.8
BOOTSTRAP=$ROOT/bootstrap
PREFIX=$ROOT/dest
WORK=$ROOT/work
TOOLS=$WORK/tools
GMP_INC=/usr/include
GMP_LIB=/usr/lib64
JOBS=8
HAPPY_SHA=8b4e7dc5a6c5fd666f8f7163232931ab28746d0d17da8fa1cbd68be9e878881b
ALEX_SHA=8a13fa01ea00883aa3d75d15ce848835b18631b8c9a4966961492d7c6095226f

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
unset LD_LIBRARY_PATH || true
unset GHC_PACKAGE_PATH || true
# rpm exports optflags as CFLAGS and LDFLAGS, including -flto and
# -Werror=format-security. Those flags fail GHC's configure probes.
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS RPM_OPT_FLAGS RPM_LD_FLAGS || true

phase() { printf 'GHC94_PHASE %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
failed=0
fail() { failed=1; printf 'GHC94_FAILED: %s\n' "$*"; exit 1; }
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "$failed" != 1 ]; then printf "GHC94_FAILED: exit %s\n" "$rc"; fi' EXIT

GHC=${GHC90:-$(command -v ghc90 || true)}
GHC_PKG=${GHC_PKG90:-$(command -v ghc-pkg90 || true)}
[ -n "$GHC" ] && [ -x "$GHC" ] || fail "ghc90 is not on PATH"
[ -n "$GHC_PKG" ] && [ -x "$GHC_PKG" ] || fail "ghc-pkg90 is not on PATH"
GHC=$(readlink -f "$GHC")
GHC_PKG=$(readlink -f "$GHC_PKG")
ver=$("$GHC" --numeric-version | tr -d '[:space:]') || fail "ghc90 did not run"
[ "$ver" = "9.0.2" ] || fail "ghc90 numeric-version is '$ver'"

[ -d "$TREE/mk" ] || fail "unpacked tree missing: $TREE"
[ "$(tr -d '[:space:]' < "$TREE/VERSION")" = "9.4.8" ] || fail "VERSION is not 9.4.8"
[ -f "$BOOTSTRAP/regen-parsers.sh" ] || fail "regen-parsers.sh missing"
[ -f "$BOOTSTRAP/cmp-regenerated.sh" ] || fail "cmp-regenerated.sh missing"
[ -f "$BOOTSTRAP/StgCRunAsm-only-when-needed.patch" ] || fail "StgCRunAsm patch missing"
[ -f "$GMP_INC/gmp.h" ] || fail "gmp.h missing"
[ -e "$GMP_LIB/libgmp.so" ] || fail "libgmp.so missing"
command -v python >/dev/null || fail "python missing"
command -v autoconf >/dev/null || fail "autoconf missing"
command -v perl >/dev/null || fail "perl missing"
command -v patch >/dev/null || fail "patch missing"
[ -x /usr/bin/gcc ] || fail "/usr/bin/gcc missing"
command -v ld.lld >/dev/null || fail "ld.lld missing"
[ ! -e "$PREFIX/bin/ghc" ] || fail "dest already has a compiler; refusing to reuse it"

mkdir -p "$WORK/logs" "$WORK/bin" "$WORK/bootbin" "$WORK/src" "$WORK/shipped" "$TOOLS"
export TMPDIR=$WORK/tmp
export TEMP=$TMPDIR
export TMP=$TMPDIR
mkdir -p "$TMPDIR"
ulimit -s unlimited 2>/dev/null || true
phase "start pid $$ script $0 boot $GHC"

check_sha() {
	local file=$1 expect=$2
	local got
	got=$(sha256sum "$file" | awk '{print $1}')
	[ "$got" = "$expect" ] || fail "sha256 $file is $got"
}

check_sha "$BOOTSTRAP/happy-1.20.1.1.tar.gz" "$HAPPY_SHA"
check_sha "$BOOTSTRAP/alex-3.2.7.4.tar.gz" "$ALEX_SHA"

cat > "$WORK/bin/gcc" << 'EOF'
#!/bin/bash
link=1
for a in "$@"; do
	case "$a" in
	-c|-E|-S|-M|-MM|-shared|--version|-dumpversion) link=0 ;;
	esac
done
args=(-fno-pie "$@")
if [ "$link" = 1 ]; then
	args+=(-no-pie)
fi
exec /usr/bin/gcc "${args[@]}"
EOF
chmod 755 "$WORK/bin/gcc"

cat > "$WORK/bootbin/ghc" << EOF
#!/bin/sh
exec $(printf '%q' "$GHC") "\$@"
EOF
cat > "$WORK/bootbin/ghc-pkg" << EOF
#!/bin/sh
exec $(printf '%q' "$GHC_PKG") "\$@"
EOF
chmod 755 "$WORK/bootbin/ghc" "$WORK/bootbin/ghc-pkg"

clean=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '\.ghcup' -e '\.cabal' -e '/ghc[0-9]' -e '/happy' || true)
clean=$(printf '%s\n' "$clean" | paste -sd: -)
export PATH="$WORK/bootbin:$TOOLS/bin:$WORK/bin:$clean"
export CC="$WORK/bin/gcc"
export CFLAGS="-std=gnu11 -w"
hash -r
command -v ghc | grep -F -q "$WORK/bootbin/ghc" || fail "PATH ghc is $(command -v ghc)"
command -v gcc | grep -F -q "$WORK/bin/gcc" || fail "PATH gcc is $(command -v gcc)"

runlog() {
	local log=$1
	shift
	if ! "$@" > "$log" 2>&1; then
		fail "$log: $(tail -20 "$log" | tr '\n' ' ' | cut -c1-700)"
	fi
}

build_tool() {
	local tar=$1 name=$2 ver=$3
	local src=$WORK/src/$name-$ver
	phase "build $name-$ver"
	rm -rf "$src"
	tar -C "$WORK/src" -xzf "$tar"
	[ -f "$src/Setup.hs" ] || fail "$name has no Setup.hs"
	(
		cd "$src"
		"$GHC" --make -v0 Setup.hs -o Setup
		./Setup configure -v0 --prefix="$TOOLS" \
			--with-compiler="$GHC" --with-hc-pkg="$GHC_PKG" \
			--ghc-option=-rtsopts
		./Setup build -v0
		./Setup install -v0
	) > "$WORK/logs/$name-setup.log" 2>&1 || fail "$name setup: $(tail -20 "$WORK/logs/$name-setup.log" | tr '\n' ' ' | cut -c1-700)"
}

build_tool "$BOOTSTRAP/alex-3.2.7.4.tar.gz" alex 3.2.7.4
build_tool "$BOOTSTRAP/happy-1.20.1.1.tar.gz" happy 1.20.1.1

wrap_rts() {
	local bin=$1 rts=$2
	[ -x "$bin" ] || fail "missing $bin"
	mv "$bin" "$bin.real"
	cat > "$bin" << EOF
#!/bin/bash
exec "\$(dirname "\$0")/$(basename "$bin").real" $rts "\$@"
EOF
	chmod 755 "$bin"
}
wrap_rts "$TOOLS/bin/alex" "+RTS -K64M -RTS"
wrap_rts "$TOOLS/bin/happy" "+RTS -K64M -H128M -RTS"
hash -r
aver=$("$TOOLS/bin/alex" --version | tr -d '\r')
printf '%s\n' "$aver" | grep -q 'Alex version 3.2.7.4' || fail "alex is '$aver'"
hver=$("$TOOLS/bin/happy" --version | tr -d '\r')
printf '%s\n' "$hver" | grep -q 'Happy Version 1.20.1.1' || fail "happy is '$hver'"
phase "tools alex 3.2.7.4 happy 1.20.1.1"

cd "$TREE"
phase "StgCRunAsm patch"
runlog "$WORK/logs/patch.log" patch -p1 -i "$BOOTSTRAP/StgCRunAsm-only-when-needed.patch"

phase "regen parsers"
if ! SHIPPED="$WORK/shipped" sh "$BOOTSTRAP/regen-parsers.sh" > "$WORK/logs/regen.log" 2>&1; then
	fail "regen-parsers: $(tail -20 "$WORK/logs/regen.log" | tr '\n' ' ' | cut -c1-700)"
fi
phase "regen $(grep -c '^regen-parsers:' "$WORK/logs/regen.log" || true) lines"

phase "build.mk"
cat > mk/build.mk << 'EOF'
GhcUnregisterised = NO
GhcWithNativeCodeGen = YES
GhcWithInterpreter = YES
GhcWithSMP = YES
GhcLibWays = v
GhcRTSWays = thr
DYNAMIC_BY_DEFAULT = NO
DYNAMIC_GHC_PROGRAMS = NO
DYNAMIC_TOO = NO
BUILD_PROF_LIBS = NO
SplitObjs = NO
SplitSections = NO
HADDOCK_DOCS = NO
HSCOLOUR_SRCS = NO
BUILD_SPHINX_HTML = NO
BUILD_SPHINX_PDF = NO
BUILD_MAN = NO
GhcStage1HcOpts = -O
GhcStage2HcOpts = -O -fasm
GhcLibHcOpts = -O -fasm
SRC_HC_OPTS = -H64m -O -optc-std=gnu11 -optc-w
SRC_CC_OPTS += -std=gnu11 -w
SRC_HSC2HS_OPTS += --cflag=-std=gnu11 --cflag=-w
EOF

phase "configure"
if ! ./configure --prefix="$PREFIX" GHC="$GHC" CC="$WORK/bin/gcc" \
	--with-gmp-includes="$GMP_INC" --with-gmp-libraries="$GMP_LIB" \
	CFLAGS="-std=gnu11 -w" > "$WORK/logs/configure.log" 2>&1
then
	fail "configure: $({ grep -E 'error:|Error |needed|cannot |Failed' "$WORK/logs/configure.log" || true; tail -15 "$WORK/logs/configure.log"; } | tr '\n' ' ' | cut -c1-2000)"
fi
grep -F "GHC=$GHC" config.log >/dev/null || fail "config.log did not record ghc90"
grep -F "$TOOLS/bin/happy" mk/config.mk >/dev/null || fail "config.mk did not record happy"
grep -F "$TOOLS/bin/alex" mk/config.mk >/dev/null || fail "config.mk did not record alex"
phase "configured"

phase "make -j$JOBS"
if ! stdbuf -oL -eL make -j"$JOBS" > "$WORK/logs/make.log" 2>&1; then
	fail "make: $(tail -30 "$WORK/logs/make.log" | tr '\n' ' ' | cut -c1-800)"
fi
phase "make rc=0"

phase "install"
if ! make -j1 install > "$WORK/logs/install.log" 2>&1; then
	fail "install: $(tail -20 "$WORK/logs/install.log" | tr '\n' ' ' | cut -c1-700)"
fi

if [ -f "$PREFIX/lib/ghc-9.4.8/settings" ]; then
	ghclib=$PREFIX/lib/ghc-9.4.8
elif [ -f "$PREFIX/lib64/ghc-9.4.8/settings" ]; then
	ghclib=$PREFIX/lib64/ghc-9.4.8
else
	fail "install tree has no settings"
fi
cp -f "$WORK/bin/gcc" "$ghclib/bin/host-gcc"
chmod 755 "$ghclib/bin/host-gcc"
python - "$ghclib/settings" '$topdir/bin/host-gcc' << 'PY'
import pathlib, re, sys
path, rel = sys.argv[1], sys.argv[2]
file = pathlib.Path(path)
text = file.read_text()
def repl(m):
    return '("%s", "%s")' % (m.group(1), rel)
new, n = re.subn(
    r'\("(C compiler command|Haskell CPP command)", "[^"]*"\)',
    repl,
    text,
)
if n != 2:
    sys.stderr.write("rewrote %s settings entries\n" % n)
    sys.exit(1)
file.write_text(new)
PY
phase "settings use \$topdir/bin/host-gcc"

# make install stores absolute paths. pkgroot is the parent of
# package.conf.d, which is this libdir, so the packaged tree can move.
phase "pkgroot"
python - "$ghclib" << 'PY' || fail "pkgroot rewrite failed"
import pathlib, sys
root = pathlib.Path(sys.argv[1])
db = root / "package.conf.d"
prefix = str(root)
if not db.is_dir():
    sys.stderr.write("no package.conf.d under %s\n" % root)
    sys.exit(1)
nfiles = 0
nsubs = 0
for conf in sorted(db.glob("*.conf")):
    text = conf.read_text()
    count = text.count(prefix)
    if count == 0:
        continue
    conf.write_text(text.replace(prefix, "${pkgroot}"))
    nfiles += 1
    nsubs += count
left = [p.name for p in db.glob("*.conf") if prefix in p.read_text()]
if nfiles < 1 or nsubs < 1 or left:
    sys.stderr.write(
        "pkgroot rewrite files=%s subs=%s left=%s\n"
        % (nfiles, nsubs, " ".join(left))
    )
    sys.exit(1)
sys.stdout.write("pkgroot rewrite: %s files, %s substitutions\n" % (nfiles, nsubs))
PY
"$ghclib/bin/ghc-pkg" --global-package-db "$ghclib/package.conf.d" recache \
	> "$WORK/logs/recache.log" 2>&1 || fail "ghc-pkg recache failed"
raw=$("$ghclib/bin/ghc-pkg" --global-package-db "$ghclib/package.conf.d" field base import-dirs --simple-output --no-expand-pkgroot | tr -d '[:space:]')
[ "$raw" = '${pkgroot}/base-4.17.2.1' ] || fail "unexpanded base import-dirs '$raw'"
exp=$("$ghclib/bin/ghc-pkg" --global-package-db "$ghclib/package.conf.d" field base import-dirs --simple-output | tr -d '[:space:]')
[ "$exp" = "$ghclib/base-4.17.2.1" ] || fail "expanded base import-dirs '$exp'"
python - "$ghclib" << 'PY' || fail "package.cache still contains the install prefix"
import pathlib, sys
root = pathlib.Path(sys.argv[1])
cache = (root / "package.conf.d" / "package.cache").read_bytes()
if str(root).encode() in cache:
    sys.exit(1)
PY
phase "pkgroot ok"

ELF=$ghclib/bin/ghc
TOP=$ghclib
[ -x "$ELF" ] || fail "installed ELF missing"
file "$ELF" | grep -q ELF || fail "installed driver is not an ELF"
iver=$("$ELF" -B"$TOP" --numeric-version | tr -d '[:space:]') || fail "installed ghc did not run"
[ "$iver" = "9.4.8" ] || fail "installed numeric-version '$iver'"
iver2=$("$ELF" -B"$TOP" --numeric-version | tr -d '[:space:]')
[ "$iver2" = "9.4.8" ] || fail "second numeric-version '$iver2'"
"$ghclib/bin/ghc-pkg" --global-package-db "$ghclib/package.conf.d" field ghc-bignum library-dirs \
	> "$WORK/logs/gmp-libdir.log"
grep -q "$GMP_LIB" "$WORK/logs/gmp-libdir.log" || fail "ghc-bignum library-dirs missing $GMP_LIB"

phase "sum10"
for i in 1 2; do
	d=$WORK/sum10-$i
	rm -rf "$d"
	mkdir -p "$d"
	cat > "$d/Helper.hs" << 'EOF'
module Helper (sumList) where

sumList :: [Int] -> Int
sumList [] = 0
sumList (x:xs) = x + sumList xs
EOF
	cat > "$d/Main.hs" << 'EOF'
module Main where

import Helper

main :: IO ()
main = do
    let xs = [1, 2, 3, 4]
    putStrLn (show (sumList xs))
EOF
	(
		cd "$d"
		"$ELF" -B"$TOP" -v0 --make Main.hs -o sum10
		./sum10 > out
	) > "$WORK/logs/sum10-$i.log" 2>&1 || fail "sum10-$i: $(tail -20 "$WORK/logs/sum10-$i.log" | tr '\n' ' ' | cut -c1-500)"
	got=$(tr -d '[:space:]' < "$d/out")
	[ "$got" = "10" ] || fail "sum10-$i output '$got'"
done
phase "sum10 ok"

# Compile again after the libdir has moved, so absolute paths cannot pass.
phase "relocate"
reldir=$WORK/relocated
rm -rf "$reldir"
mkdir -p "$reldir" "$WORK/sum10-reloc"
cp -f "$WORK/sum10-1/Helper.hs" "$WORK/sum10-1/Main.hs" "$WORK/sum10-reloc/"
mv "$ghclib" "$reldir/ghc-9.4.8"
set +e
(
	cd "$WORK/sum10-reloc"
	"$reldir/ghc-9.4.8/bin/ghc" -B"$reldir/ghc-9.4.8" -v0 --make Main.hs -o sum10
	./sum10 > out
) > "$WORK/logs/sum10-reloc.log" 2>&1
rc=$?
set -e
mv "$reldir/ghc-9.4.8" "$ghclib"
[ "$rc" = 0 ] || fail "relocate compile: $(tail -20 "$WORK/logs/sum10-reloc.log" | tr '\n' ' ' | cut -c1-500)"
got=$(tr -d '[:space:]' < "$WORK/sum10-reloc/out")
[ "$got" = "10" ] || fail "relocate output '$got'"
phase "relocate ok"

file "$ELF" | tee "$WORK/logs/file-ghc.txt"
printf 'GHC94_DONE installed %s numeric-version %s\n' "$ELF" "$iver"
