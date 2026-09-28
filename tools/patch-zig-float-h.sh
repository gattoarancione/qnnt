#!/usr/bin/env bash
#
# Teach Zig 0.16.0's bundled Clang <float.h> to answer __need_infinity_nan, so that
# Zig can build its own libc++ against macOS SDK 27.
#
# Without this, every `-lc++` link on this machine dies with
#
#     error: sub-compilation of libcxx failed
#     .../__random/clamp_to_integral.h:47:58: use of undeclared identifier 'INFINITY'
#
# The chain:
#
#   1. Zig compiles its bundled libc++ sources with -std=c++23. C++20 and later turn on
#      __has_feature(modules).
#   2. SDK 27's <math.h> stops defining INFINITY and NAN itself when modules are on and
#      <float.h> is reachable. Instead it sets __need_infinity_nan and includes <float.h>,
#      expecting Clang's header to supply the two macros.
#   3. Clang 21 (what Xcode ships) answers that through __float_infinity_nan.h. The
#      <float.h> bundled with Zig 0.16.0 predates the split: it has no __need_infinity_nan
#      path, a plain __CLANG_FLOAT_H include guard that makes re-inclusion a no-op, and it
#      gates INFINITY/NAN behind `!__STRICT_ANSI__` -- which a strict -std=c++23 build,
#      as opposed to -std=gnu++23, does not satisfy.
#   4. So nothing defines INFINITY, and libc++'s clamp_to_integral.h fails to compile.
#
# None of Zig's supported knobs reach this: --sysroot and SDKROOT do not move the -isystem
# the libcxx sub-compilation uses, and the -std it passes is internal. Hence a patch.
#
# Idempotent. Keeps float.h.qnnt-orig beside the file. Re-run after `brew upgrade zig` or
# any Zig reinstall. Drop it once Zig ships a Clang whose float.h honours the macro.

set -euo pipefail

marker='__need_infinity_nan) /* qnnt patch */'

lib_dir=$(zig env | sed -n 's/^[[:space:]]*\.lib_dir = "\(.*\)",$/\1/p')
if [ -z "$lib_dir" ]; then
    echo "could not read .lib_dir out of \`zig env\`" >&2
    exit 1
fi

header="$lib_dir/include/float.h"
[ -f "$header" ] || { echo "no such header: $header" >&2; exit 1; }

if grep -qF "$marker" "$header"; then
    echo "already patched: $header"
    exit 0
fi

# Only macOS SDKs from 27 on delegate the two macros; elsewhere this is a no-op anyway,
# but there is no reason to touch a toolchain that does not need it.
if [ "$(uname -s)" != "Darwin" ]; then
    echo "not macOS -- nothing to do"
    exit 0
fi

# Unconditional: reaching here means the header carries no marker, so it *is* an
# original. After a Zig upgrade that is a new original, and keeping the stale one would
# wrap the previous toolchain's header around the new compiler.
# rm first: a backup from an earlier run is mode 444, which cp cannot overwrite.
rm -f "$header.qnnt-orig"
cp -p "$header" "$header.qnnt-orig"

# Zig installs these headers read-only (444), so write a sibling and rename over the top:
# the directory is writable even though the file is not. mktemp in the same directory keeps
# the rename atomic and on the same filesystem.
tmp=$(mktemp "$lib_dir/include/.float.h.qnnt.XXXXXX")
{
    cat <<EOF
#if defined($marker
/* Apple's SDK 27 <math.h> hands INFINITY and NAN off to <float.h> whenever Clang modules
 * are active, which -std=c++20 and later enable. Clang 21 answers through
 * __float_infinity_nan.h; this header predates that split and gates both macros behind
 * !__STRICT_ANSI__, which a strict -std=c++23 build does not satisfy -- so libc++ saw
 * neither and failed to compile. Answer the narrow request, and nothing else.
 *
 * Applied by qnnt's tools/patch-zig-float-h.sh. Original kept as float.h.qnnt-orig.
 */
#undef INFINITY
#undef NAN
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))
#undef __need_infinity_nan
#else
EOF
    cat "$header.qnnt-orig"
    echo "#endif"
} > "$tmp"

# Match the mode Zig shipped, then rename over the read-only original.
chmod --reference="$header" "$tmp" 2>/dev/null || chmod 444 "$tmp"
mv -f "$tmp" "$header"

echo "patched: $header"
echo "original: $header.qnnt-orig"
