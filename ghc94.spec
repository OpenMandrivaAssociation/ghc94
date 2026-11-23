%global debug_package %{nil}
Summary:	Glasgow Haskell Compiler 9.4.8 (bootstrapped with in-chain GHC 9.0.2)
Name:		ghc94
Version:	9.4.8
Release:	1
License:	BSD
Group:		Development/Other
Url:		https://www.haskell.org/ghc/
# Complement package. Does not replace distro ghc, so no Epoch.
# Last make-based GHC. The boot compiler is in-chain GHC 9.0.2 on
# PATH as ghc90 / ghc-pkg90. Happy and alex are built from source
# inside %build. This spec does not copy a prebuilt prefix.
ExclusiveArch:	x86_64 znver1
Source0:	ghc-9.4.8-src.tar.xz
Source1:	ghc94-bootstrap-kit.tar.gz
Source2:	ghc94-build.sh
Source3:	%{name}.rpmlintrc

BuildRequires:	ghc90
BuildRequires:	make
BuildRequires:	python
BuildRequires:	perl
BuildRequires:	autoconf
BuildRequires:	patch
BuildRequires:	gcc
BuildRequires:	lld
BuildRequires:	diffutils
BuildRequires:	binutils
BuildRequires:	pkgconfig(gmp)
BuildRequires:	pkgconfig(ncurses)
BuildRequires:	pkgconfig(libffi)
BuildRequires:	pkgconfig(numa)
BuildRequires:	file
BuildRequires:	tar
BuildRequires:	xz
BuildRequires:	gzip

%description
GHC 9.4.8 compiled from its Haskell sources by the in-chain GHC 9.0.2
(make, static libraries, host GMP). No upstream bindist and no GHCup
compiler. Installed as ghc94 so later hops, including ghc98, can build
against it.

%prep
set -eu
cd %{_builddir}
rm -rf ghc94-root
mkdir -p ghc94-root
tar -xJf %{SOURCE0} -C ghc94-root
tar -xzf %{SOURCE1} -C ghc94-root
test -d ghc94-root/ghc-9.4.8/mk
test "$(tr -d '[:space:]' < ghc94-root/ghc-9.4.8/VERSION)" = "9.4.8"
test -f ghc94-root/bootstrap/regen-parsers.sh
test -f ghc94-root/bootstrap/cmp-regenerated.sh
test -f ghc94-root/bootstrap/StgCRunAsm-only-when-needed.patch
test -f ghc94-root/bootstrap/happy-1.20.1.1.tar.gz
test -f ghc94-root/bootstrap/alex-3.2.7.4.tar.gz
test -f %{SOURCE2}
set +u

%build
set -eu
bash %{SOURCE2} "%{_builddir}/ghc94-root"
set +u

%install
set -eu
dest=%{_builddir}/ghc94-root/dest
if [ -d "$dest/lib/ghc-9.4.8" ]; then
	src=$dest/lib/ghc-9.4.8
elif [ -d "$dest/lib64/ghc-9.4.8" ]; then
	src=$dest/lib64/ghc-9.4.8
else
	echo "ghc94: install tree has no lib/ghc-9.4.8" >&2
	exit 1
fi
mkdir -p %{buildroot}%{_libdir} %{buildroot}%{_bindir}
cp -a "$src" %{buildroot}%{_libdir}/ghc-9.4.8
test -x %{buildroot}%{_libdir}/ghc-9.4.8/bin/ghc
file %{buildroot}%{_libdir}/ghc-9.4.8/bin/ghc | grep -q ELF
test -f %{buildroot}%{_libdir}/ghc-9.4.8/settings
test -x %{buildroot}%{_libdir}/ghc-9.4.8/bin/host-gcc
libname=$(basename %{_libdir})
cat > %{buildroot}%{_bindir}/ghc94 << EOF
#!/bin/sh
if [ -x "\$0" ] && [ "\$0" != "\${0#*/}" ]; then
	arg0=\$0
else
	arg0=\$(command -v "\$0") || exit 1
fi
here=\$(CDPATH= cd -- "\$(dirname "\$arg0")" && pwd)
root=\$(dirname "\$here")
exec "\$root/$libname/ghc-9.4.8/bin/ghc" -B"\$root/$libname/ghc-9.4.8" "\$@"
EOF
cat > %{buildroot}%{_bindir}/ghc-pkg94 << EOF
#!/bin/sh
if [ -x "\$0" ] && [ "\$0" != "\${0#*/}" ]; then
	arg0=\$0
else
	arg0=\$(command -v "\$0") || exit 1
fi
here=\$(CDPATH= cd -- "\$(dirname "\$arg0")" && pwd)
root=\$(dirname "\$here")
top="\$root/$libname/ghc-9.4.8"
exec "\$top/bin/ghc-pkg" --global-package-db "\$top/package.conf.d" "\$@"
EOF
chmod 755 %{buildroot}%{_bindir}/ghc94 %{buildroot}%{_bindir}/ghc-pkg94
ln -sfn ghc94 %{buildroot}%{_bindir}/ghc-9.4.8
ln -sfn ghc-pkg94 %{buildroot}%{_bindir}/ghc-pkg-9.4.8
set +u

%files
%{_bindir}/ghc94
%{_bindir}/ghc-pkg94
%{_bindir}/ghc-9.4.8
%{_bindir}/ghc-pkg-9.4.8
%{_libdir}/ghc-9.4.8/

%check
set -eu
cd %{_builddir}
export PATH=%{buildroot}%{_bindir}:$PATH
hash -r
command -v ghc94 | grep -q '%{buildroot}'
b=$(command -v ghc94)
g=%{buildroot}%{_libdir}/ghc-9.4.8
test -x "$g/bin/ghc"
file "$g/bin/ghc" | grep -q ELF
test -f "$g/settings"
test -x "$g/bin/host-gcc"
"$b" --numeric-version | tee numeric.out
test "$(cat numeric.out)" = "9.4.8"
"$b" --numeric-version | tee numeric2.out
test "$(cat numeric2.out)" = "9.4.8"
cat > Helper.hs << 'EOF'
module Helper (sumList) where

sumList :: [Int] -> Int
sumList [] = 0
sumList (x:xs) = x + sumList xs
EOF
cat > Main.hs << 'EOF'
module Main where

import Helper

main :: IO ()
main = do
	let xs = [1, 2, 3, 4]
	putStrLn (show (sumList xs))
EOF
rm -rf sum-a sum-b
mkdir sum-a sum-b
cp Helper.hs Main.hs sum-a/
cp Helper.hs Main.hs sum-b/
( cd sum-a && "$b" -v0 --make Main.hs -o sum10 && ./sum10 ) > sum-a.out
test "$(cat sum-a.out)" = "10"
( cd sum-b && "$b" -v0 --make Main.hs -o sum10 && ./sum10 ) > sum-b.out
test "$(cat sum-b.out)" = "10"
set +u
