#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# MARK: File Overview
# gcc_build_profiles.sh
#
# author  Roman Horshkov <github.com/RomanHorshkov>
# date    2026
# (c) 2026
#
# =============================================================================
#
# Purpose
# -------
# Repository-ready GCC build profiles for a production-quality C project.
#
# This file is intentionally detailed. It serves two roles:
#
#   1. a reusable Bash fragment that exposes GCC, CPP, and LD flag arrays; and
#   2. a reference document describing why each flag is present, what trade-offs
#      it introduces, and where it should or should not be used.
#
# This version keeps preprocessor flags, compiler flags, and linker flags
# separate on purpose:
#
#   CPPFLAGS
#       Preprocessor-only policy: include roots, feature macros, project macros.
#
#   CFLAGS
#       Language mode, warnings, optimization, debug info, instrumentation.
#
#   LDFLAGS
#       Link-time policy: sanitizers, LTO, linker options.
#
# This file ships in the kyr-build package (/usr/local/share/kyr-build/, or a
# repository's build/sysroot/share/kyr-build/ through deps.sh sysroot). A
# repository never edits a copy: it sources the shipped file through its thin
# utils/gcc_build_profiles.sh wrapper and overrides what it must in its own
# utils/<name>_project.sh (see "Project Overrides" near the end).
#
# Intended usage
# --------------
# Source this file from your build script:
#
#   source ./gcc_build_profiles.sh
#
# Then select one profile:
#
#   gcc "${CPPFLAGS_DEBUG[@]}"    "${CFLAGS_DEBUG[@]}"    src/*.c -o app_debug \
#       "${LDFLAGS_DEBUG[@]}"
#
#   gcc "${CPPFLAGS_RELEASE[@]}"  "${CFLAGS_RELEASE[@]}"  src/*.c -o app_release \
#       "${LDFLAGS_RELEASE[@]}"
#
#   gcc "${CPPFLAGS_NATIVE[@]}"   "${CFLAGS_NATIVE[@]}"   src/*.c -o app_native \
#       "${LDFLAGS_NATIVE[@]}"
#
# Or print flags for command substitution:
#
#   gcc $(./gcc_build_profiles.sh print-cppflags sanitize) \
#       $(./gcc_build_profiles.sh print-cflags sanitize) \
#       src/*.c -o app_sanitize \
#       $(./gcc_build_profiles.sh print-ldflags sanitize)
#
# Or inspect a profile:
#
#   ./gcc_build_profiles.sh explain
#   ./gcc_build_profiles.sh print-cppflags debug
#   ./gcc_build_profiles.sh print-cflags native
#
# Design Principles
# -----------------
# Build configuration discussions often blur together concerns that should be
# evaluated independently. This file keeps them separate:
#
#   1. project customization
#      Language standard, feature macros, include roots, and project-local
#      defines. These are the first things you should edit after copy-paste.
#
#   2. warnings
#      Compile-time diagnostics. They do not make the final binary slower.
#      Every profile carries the whole strict set and -Werror, the tests'
#      builds included, and every link -Wl,--fatal-warnings: no build passes
#      with a warning, under the host's gcc or the build root's (zero
#      tolerated, the "Power of 10" rule 10 stance). The set is what both
#      compilers accept; each flag's reason is next to it, the flags left out
#      are under "Left Out" with theirs.
#
#   3. instrumentation / hardening
#      Runtime checks or safety mechanisms inserted into the generated binary.
#      Examples include sanitizers, stack protectors, and _FORTIFY_SOURCE.
#      These may increase runtime cost and binary size.
#
#   4. optimization
#      Code-generation policy. Examples include -O1, -O2, -O3, -flto, and
#      -march=native. These affect runtime performance, binary size, debugging
#      quality, and sometimes whether latent undefined behavior becomes visible.
#
# The profiles below keep those concerns explicit:
#
#   debug
#       Debugger-oriented development profile (-Og, no inlining).
#
#   audit
#       Compiler-driven validation profile with strong warnings and GCC static
#       analyzer. No runtime sanitizers.
#
#   sanitize
#       Runtime-defect hunting profile with ASan + UBSan + LSan.
#
#   release
#       Portable production profile with sensible hardening. This is the
#       default release configuration for software that must be fast without
#       abandoning baseline defensive measures.
#
#   native
#       Local-machine tuned release-like profile for benchmarking and local
#       validation, while still keeping hardening.
#
#   extreme
#       Maximum-performance local-machine profile. It intentionally removes some
#       safety and debugging features and is intended for benchmarking or tightly
#       controlled deployment, not for general distribution.
#
#   tsan
#       Optional dedicated ThreadSanitizer profile for concurrency analysis.
#
# Recommended workflow
# --------------------
#
#   1. Develop with: debug
#   2. Run compiler-centric cleanup with: audit
#   3. Run runtime bug hunting with: sanitize
#   4. Re-run the same tests with: release
#   5. Benchmark with: release and native
#   6. Use: extreme only when there is a concrete need to pursue the final
#      increment of performance
#   7. Use: tsan when auditing concurrent code
#
# Canonical Profile List
# ----------------------
# The ordered profile list is exported as a Bash array so build scripts can
# iterate over the same profile lineup without re-declaring it locally.
#
# Example:
#
#   source ./gcc_build_profiles.sh
#   for profile in "${GCC_BUILD_PROFILES[@]}"; do
#       ...
#   done
#
# Important Note
# --------------
# Passing the sanitize profile does not prove that the release, native, or
# extreme profiles are correct. Optimized builds can expose undefined behavior
# that did not manifest under sanitizer-heavy or debug-oriented builds. The same
# test suite should therefore be exercised under the optimized profiles as well.
#
# Compatibility Note
# ------------------
# This file targets GCC on Linux/glibc. Several flags are GCC-specific and may
# be unavailable in Clang, TinyCC, embedded cross-compilers, or older GCC
# releases. If the project must support multiple toolchains, add a small
# feature-detection or compatibility layer rather than weakening the policy
# globally.
#
# =============================================================================
# MARK: Helpers
# Usage helper
# =============================================================================

_print_array() {
    local -n arr="$1"
    if ((${#arr[@]} == 0)); then
        printf '\n'
        return 0
    fi
    printf '%q ' "${arr[@]}"
    printf '\n'
}

#
# Keep ThreadSanitizer available for explicit concurrency work, but exclude it
# from the default automated lineup. TSAN frequently misbehaves on this host
# (e.g. "unexpected memory mapping") and its output is rarely actionable here,
# so the normal build/test/pipeline scripts must not pull it in by default.
# Set GCC_BUILD_ENABLE_TSAN=1 to append tsan back for a deliberate run.
#
GCC_BUILD_ENABLE_TSAN="${GCC_BUILD_ENABLE_TSAN:-0}"

GCC_BUILD_PROFILES=(
  debug
  audit
  sanitize
  release
  native
  extreme
)

if [[ "${GCC_BUILD_ENABLE_TSAN}" == "1" ]]; then
    GCC_BUILD_PROFILES+=(tsan)
fi

# =============================================================================
# MARK: Language And Platform Policy
# Language / platform policy
# =============================================================================
#
# CPPFLAGS_BASE / CFLAGS_BASE
# ---------------------------
# These arrays define the project's baseline compilation contract.
#
# Keep the per-project customization here so the rest of the file can stay
# reusable across repositories.
#
# -std=c11
#     Compile as ISO C11.
#
#     Compile-time cost: none/minimal.
#     Runtime cost: none.
#     Risk: if you use GNU-only syntax, GCC may reject it unless the extension is
#           still accepted as an extension. With -Wpedantic, it will complain.
#
# -D_GNU_SOURCE
#     Expose GNU/glibc extensions in system headers.
#
#     This is useful for Linux systems programming: accept4, pipe2, O_TMPFILE,
#     memfd_create, pthread_setname_np, asprintf, etc.
#
#     Compile-time cost: none.
#     Runtime cost: none.
#     Portability: Linux/glibc-specific behavior becomes easier to depend on.
#
#     Alternative for stricter POSIX code:
#
#       -D_POSIX_C_SOURCE=200809L
#
#     Alternative if you knowingly want GNU C dialect:
#
#       -std=gnu11
#
# -D_POSIX_C_SOURCE=200809L
#     Request the POSIX.1-2008 interface set from libc headers.
#
#     This is a good default when you want a disciplined POSIX-oriented surface
#     without enabling the wider GNU extension namespace everywhere.
#
#     Compile-time cost: none.
#     Runtime cost: none.
#     Portability: generally better than _GNU_SOURCE, though still libc/platform
#                  dependent in the details.
#
#     Common reason to switch away from it:
#
#       - you need GNU/glibc-only APIs such as pipe2, accept4, memfd_create,
#         or asprintf and you want those prototypes exposed directly.
#
# -I.
#     Add the current directory as an include root. In larger projects, a more
#     explicit include layout such as -Iinclude or -Iapp/include is often
#     preferable.
#

CPPFLAGS_FEATURES=(
  # -D_GNU_SOURCE
  -D_POSIX_C_SOURCE=200809L
  # -DPROJECT_INTERNAL_BUILD=1
)

CPPFLAGS_INCLUDES=(
  -I.
  # -Iinclude
  # -Iapp/include
  # -Isrc
)

CPPFLAGS_BASE=(
  "${CPPFLAGS_FEATURES[@]}"
  "${CPPFLAGS_INCLUDES[@]}"
)

FORTIFY_SOURCE_LEVEL="${FORTIFY_SOURCE_LEVEL:-3}"

CPPFLAGS_FORTIFY=(
  # -U_FORTIFY_SOURCE
  #   Undefine _FORTIFY_SOURCE if inherited from environment or distro flags.
  -U_FORTIFY_SOURCE

  # -D_FORTIFY_SOURCE=<level>
  #   Enables extra glibc checks for certain libc calls when optimization is on.
  #
  #   Examples: memcpy, strcpy, sprintf, etc., may get compile-time or runtime
  #   object-size checks.
  #
  #   Requires optimization to be useful: -O1 or higher.
  #   Runtime cost: usually small, sometimes none, occasionally measurable.
  #   Portability: glibc-specific. Level 3 requires sufficiently recent glibc/GCC.
  #
  #   GCC's hardened profile falls back to level 2 on older glibc. Match that
  #   manually when needed with:
  #       FORTIFY_SOURCE_LEVEL=2 ./gcc_build_profiles.sh print-cppflags release
  -D_FORTIFY_SOURCE="${FORTIFY_SOURCE_LEVEL}"
)

CPPFLAGS_RELEASE_POLICY=(
  # -DNDEBUG
  #   Disables assert() from <assert.h>.
  #
  #   Runtime: removes assertion checks.
  #   Risk: if your program relies on assert side effects, the program is wrong.
  #   Never write:
  #       assert(init_thing() == 0);
  #   if init_thing() must run in release.
  -DNDEBUG
)

CPPFLAGS_HARDENING=(
  "${CPPFLAGS_FORTIFY[@]}"
)

CPPFLAGS_EXTREME_POLICY=(
  # -U_FORTIFY_SOURCE
  #   Undefine _FORTIFY_SOURCE if inherited from environment or distro flags.
  #
  #   Runtime: may remove some libc object-size checks.
  #   Safety: worse.
  #   Use only when you explicitly want no fortify overhead/checking.
  -U_FORTIFY_SOURCE
)

CFLAGS_LANGUAGE=(
  -std=c11
)

# =============================================================================
# MARK: Reproducibility
# Reproducible-build policy (plan 4.1): the same clone in the same build root
# gives the same bytes on any machine.
# =============================================================================
#
# umask 022
#     Staged files carry the mode install(1) gave them, never the caller's.
#
# SOURCE_DATE_EPOCH
#     The one timestamp every tool is allowed to embed: dpkg-deb clamps the
#     tar and ar members to it, tar --mtime takes it, gcc uses it for
#     __DATE__/__TIME__. Taken from the last commit that touched a build
#     input (lib/epoch.sh: app, VERSION, deps.txt, utils, debian, plus the
#     project file's KYR_BUILD_INPUTS additions) unless the caller already
#     exported one: a docs- or tests-only commit builds the same bytes.
#
# -ffile-prefix-map=<root>=.
#     Every path the compiler records (DW_AT_comp_dir, DW_AT_name, __FILE__,
#     .debug_line) is relative to the repository root, never /home/<user>/...
#     -fdebug-prefix-map is the older, debug-info-only form; both are set so
#     an object built with a compiler that only honours one still has none.
#
# GCC_BUILD_ARFLAGS (rcsD)
#     D: deterministic archive members (uid 0, gid 0, mtime 0, mode 644).
#
umask 022

GCC_BUILD_SOURCE_ROOT="${GCC_BUILD_SOURCE_ROOT:-${ROOT_DIR:-${PWD}}}"

# shellcheck source=lib/epoch.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/epoch.sh"
kyr_epoch_init "${GCC_BUILD_SOURCE_ROOT}"

CFLAGS_REPRODUCIBLE=(
  -ffile-prefix-map="${GCC_BUILD_SOURCE_ROOT}=."
  -fdebug-prefix-map="${GCC_BUILD_SOURCE_ROOT}=."
)

GCC_BUILD_ARFLAGS=(rcsD)

CFLAGS_BASE=(
  "${CFLAGS_LANGUAGE[@]}"
  "${CFLAGS_REPRODUCIBLE[@]}"
)

# =============================================================================
# MARK: Baseline Warnings
# Warning group 1a: day-to-day core warnings
# =============================================================================
#
# CFLAGS_WARN_CORE
# ----------------
# These warnings are broadly appropriate for day-to-day development. They are
# useful enough even in debug builds, and they are much less likely to stop you
# while you are still trying to get the code running.
#
# Runtime cost of all warning flags: none.
# Binary-size cost of all warning flags: none.
# Compile-time cost: usually tiny, except where explicitly noted.
#
CFLAGS_WARN_CORE=(
  # -Wall
  #   Enables GCC's common warning set. Despite the name, it does NOT enable all
  #   warnings. It catches many basic mistakes: suspicious control flow,
  #   unused variables, missing returns in many cases, bad printf usage, etc.
  -Wall

  # -Wextra
  #   Adds more useful warnings not included in -Wall. Examples: unused
  #   parameters in some contexts, missing field initializers in some cases,
  #   sign comparisons, etc.
  -Wextra

  # -Wpedantic
  #   Warn when using code that violates the selected ISO C standard.
  #   With -std=c11, this helps detect non-standard constructs.
  #
  #   Important: if the project enables GNU or POSIX feature-test macros,
  #   system headers and project code may intentionally use non-ISO APIs. That
  #   is fine. This warning mainly helps keep the language syntax honest.
  -Wpedantic

  # -Wformat=2
  #   Strong printf/scanf format checking. This includes extra checks beyond the
  #   default format warnings.
  #
  #   Catches wrong format specifiers, dangerous nonliteral formats in some
  #   cases, and security-sensitive formatting mistakes.
  -Wformat=2

  # -Wshadow
  #   Warn when a local declaration shadows another variable, parameter, global,
  #   or type depending on context.
  #
  #   Value: excellent for maintainability.
  #   Cost: no runtime cost.
  -Wshadow

  # -Wundef
  #   Warn if an undefined macro is used in an #if expression.
  #
  #   Example caught:
  #       #if FEATURE_X
  #   when FEATURE_X was never defined.
  #
  #   Safer style:
  #       #if defined(FEATURE_X) && FEATURE_X
  -Wundef

  # -Wreturn-type
  #   Warn about functions that should return a value but may not.
  #   Usually included by -Wall, kept explicit because it is critical.
  -Wreturn-type
)

# =============================================================================
# MARK: API Warnings
# Warning group 1b: external-symbol and API hygiene warnings
# =============================================================================
#
# CFLAGS_WARN_API
# ---------------
# These warnings are still "baseline good citizenship" for disciplined C, but
# they are more about API hygiene than about basic "let me get the program
# running" development. That is why debug does not force them.
#
CFLAGS_WARN_API=(
  # -Wmissing-prototypes
  #   Warn if a global function is defined without a previous prototype.
  #
  #   This is extremely useful in C. It catches accidental external functions
  #   that should have been static, and public functions missing from headers.
  -Wmissing-prototypes

  # -Wstrict-prototypes
  #   Warn about old-style prototypes like:
  #       int f();
  #   That does NOT mean "function with no parameters".
  #   It means "function with unspecified parameters".
  #
  #   Proper C prototype:
  #       int f(void);
  -Wstrict-prototypes

  # -Wold-style-definition
  #   Warn about K&R-style function definitions.
  #
  #   Modern C code should use prototype-style definitions only.
  -Wold-style-definition

  # -Wmissing-declarations
  #   Warn if a global function has no previous declaration.
  #
  #   This overlaps somewhat with -Wmissing-prototypes, but it is still useful
  #   when trying to keep external symbols intentional.
  -Wmissing-declarations
)

# =============================================================================
# MARK: Strict Warnings
# Warning group 2: strict value/type/memory warnings
# =============================================================================
#
# CFLAGS_WARN_STRICT
# ------------------
# These warnings are highly valuable, but they require discipline. Adopting
# them often means introducing explicit casts, revisiting type choices, and
# tightening API design.
#
CFLAGS_WARN_STRICT=(
  # -Wconversion
  #   Warn for implicit conversions that may change a value.
  #
  #   Examples:
  #       uint32_t x = some_uint64;
  #       int i = some_size_t;
  #       uint8_t b = 300;
  #
  #   Value: excellent for serialization, binary formats, UUIDs, file sizes,
  #   indexes, wire protocols, endian code, and embedded targets.
  #
  #   Adoption cost: high. Intentional boundaries often require explicit casts.
  -Wconversion

  # -Wduplicated-cond
  #   Warn about duplicated conditions in if/else chains.
  #
  #   Example:
  #       if (x == 1) { ... }
  #       else if (x == 1) { ... }
  -Wduplicated-cond

  # -Wduplicated-branches
  #   Warn when two branches contain identical code.
  #
  #   Sometimes catches copy/paste bugs.
  #   Sometimes complains about deliberate symmetry.
  #   Good for test builds.
  -Wduplicated-branches

  # -Wlogical-op
  #   Warn about suspicious logical expressions.
  #
  #   Example classes: self-comparisons, always-true/false logic, duplicated
  #   operands. GCC-specific and occasionally noisy.
  -Wlogical-op

  # -Wnull-dereference
  #   Warn when GCC can prove a null pointer is dereferenced.
  #
  #   More effective with optimization enabled. No runtime cost.
  -Wnull-dereference

  # -Wsign-conversion
  #   Warn for implicit conversions that change signedness.
  #
  #   This is extremely useful in C because size_t/int mixing is a bug factory.
  #   It is also noisy until the codebase is disciplined.
  -Wsign-conversion

  # -Wimplicit-fallthrough=5
  #   Warn about switch cases that fall through without an explicit recognized
  #   annotation.
  #
  #   Level 5 is strict. Prefer the C attribute when available:
  #       __attribute__((fallthrough));
  #   or a project macro around it.
  -Wimplicit-fallthrough=5

  # -Wswitch-enum
  #   Warn when a switch over an enum does not handle all enum values.
  #
  #   Very useful for finite-state machines and typed status enums.
  #   Can be noisy if default is intentionally used for many enums.
  -Wswitch-enum

  # -Wswitch-default
  #   Warn when a switch does not have a default case.
  #
  #   Note: there is a style tension with -Wswitch-enum. For safety-critical-ish
  #   code, one common pattern is:
  #       - explicitly list all enum cases;
  #       - still have default for corrupted/out-of-range values.
  -Wswitch-default

  # -Wdouble-promotion
  #   Warn when float is implicitly promoted to double.
  #
  #   Useful in embedded/FP-heavy code. Less relevant for integer-only systems
  #   code. Can be noisy around printf because float arguments are promoted to
  #   double by the C calling convention for variadic functions.
  -Wdouble-promotion

  # -Wfloat-equal
  #   Warn when comparing floating-point values with == or !=.
  #
  #   Useful for numerical code, control code, simulation, and filters, where
  #   exact equality is often suspicious.
  #
  #   May be annoying if you intentionally compare against 0.0, NaN-handling
  #   patterns, or exact encoded values.
  -Wfloat-equal

  # -Wcast-qual
  #   Warn when a cast removes const or volatile qualifiers.
  #
  #   Very useful for API hygiene. Removing const is often a design smell.
  #   Removing volatile can be disastrous for MMIO/concurrency-ish code.
  -Wcast-qual

  # -Wcast-align=strict
  #   Warn when a cast may increase alignment requirements.
  #
  #   Example danger:
  #       uint8_t *p = ...;
  #       uint64_t *q = (uint64_t *)p;
  #
  #   On x86 this may merely be slower. On other architectures it may fault.
  #   Very relevant for portable C and embedded targets.
  -Wcast-align=strict

  # -Wwrite-strings
  #   Give string literals type "const char[N]" for warning purposes.
  #
  #   This catches code that tries to modify string literals or stores them in
  #   mutable char * pointers.
  -Wwrite-strings

  # -Wpointer-arith
  #   Warn about pointer arithmetic on void* or function pointers.
  #
  #   GNU C allows void* arithmetic as an extension.
  #   ISO C does not.
  #   Prefer uint8_t* / char* when doing byte addressing.
  -Wpointer-arith

  # -Wbad-function-cast
  #   Warn when a function call result is cast to an incompatible type.
  #
  #   Useful in C code with factory functions, integer/pointer conversion
  #   mistakes, or old-style APIs.
  -Wbad-function-cast

  # -Wstrict-aliasing=3
  #   Warn about code that may violate strict aliasing rules.
  #
  #   Important when using -O2/-O3 because GCC optimizes assuming strict
  #   aliasing by default.
  #   Many ugly type-punning tricks are undefined behavior.
  #
  #   Safer type-punning tools:
  #       memcpy
  #       unions only when used with care and compiler support
  #       explicit byte buffers
  -Wstrict-aliasing=3

  # -Wvla
  #   Warn on variable-length arrays.
  #
  #   VLAs can create unpredictable stack usage.
  #   For robust systems code, avoid
  #   them unless you have a very explicit reason.
  -Wvla

  # -Walloca
  #   Warn on alloca().
  #
  #   alloca() consumes stack dynamically and is hard to reason about.
  #   Avoid in robust systems code.
  -Walloca

  # -Wmissing-field-initializers
  #   Warn when aggregate initialization does not initialize every field.
  #
  #   Note: this can be annoying with idioms like {0}. GCC usually treats {0}
  #   specially, but designated initializers are often clearer:
  #       struct cfg c = { .mode = MODE_X, .size = 42 };
  -Wmissing-field-initializers

  # -Wjump-misses-init
  #   Warn when a goto or a case label jumps forward past a variable's
  #   initialization: the variable is in scope there with no value.
  -Wjump-misses-init

  # -Winit-self
  #   Warn about a variable initialized with itself (int i = i;), the idiom that
  #   hides an uninitialized read from -Wuninitialized.
  -Winit-self

  # -Wnested-externs
  #   Warn about an extern declaration inside a function: the declaration
  #   belongs in a header, where every user sees the one prototype.
  -Wnested-externs

  # -Wformat-signedness
  #   With -Wformat: %d given an unsigned value, %u given a signed one. The
  #   output is wrong for half the range, and a wrong log line is a lie.
  -Wformat-signedness

  # -Wshift-overflow=2
  #   Also warn when a left shift moves a 1 into the sign bit of a signed type
  #   (1 << 31): undefined behaviour in C11.
  -Wshift-overflow=2

  # -Wmissing-format-attribute
  #   Warn when a function hands its format string and va_list to a printf-like
  #   function without carrying the format attribute itself: its callers'
  #   arguments would go unchecked.
  -Wmissing-format-attribute

  # -Wbidi-chars=any
  #   Refuse every bidirectional control character in the source, paired or
  #   not (Trojan Source, CVE-2021-42574).
  -Wbidi-chars=any

  # -Wuse-after-free=3
  #   Level 3 also diagnoses a freed or reallocated pointer used in an equality
  #   comparison.
  -Wuse-after-free=3

  # -Wstack-protector
  #   Warn about a function the stack protector cannot protect (with
  #   -fstack-protector-strong in effect).
  -Wstack-protector

  # -Wpacked
  #   Warn about a packed attribute that changes nothing in the layout.
  -Wpacked
)

# =============================================================================
# MARK: Paranoid Warnings
# Warning group 3: paranoid / GCC-specific diagnostics
# =============================================================================
#
# CFLAGS_WARN_PARANOID
# --------------------
# These diagnostics are useful in rigorous validation builds, but they are more
# sensitive to compiler-version differences and can be noisy. They are kept
# separate intentionally.
#
CFLAGS_WARN_PARANOID=(
  # -Warray-bounds=2
  #   Stronger array bounds diagnostics.
  #
  #   More effective with optimization. Can find real bugs in fixed-size array
  #   code, serialization code, and manual buffers.
  -Warray-bounds=2

  # -Wstringop-overflow=4
  #   Aggressive warnings for overflowing string/memory builtins like memcpy,
  #   strcpy, memset, etc., when GCC can reason about object sizes.
  #
  #   Very useful with _FORTIFY_SOURCE and optimization.
  -Wstringop-overflow=4

  # -Wformat-overflow=2
  #   Warn when sprintf-like formatting may overflow the destination buffer.
  -Wformat-overflow=2

  # -Wformat-truncation=2
  #   Warn when snprintf-like formatting may truncate output.
  #
  #   Note: truncation is not always a bug if you intentionally handle it.
  -Wformat-truncation=2

  # -Walloc-zero
  #   Warn about allocations of size zero.
  #
  #   malloc(0) is implementation-defined-ish in practical behavior.
  #   Often indicates a missing validation path.
  -Walloc-zero

  # -Wsizeof-pointer-memaccess
  #   Warn about suspicious sizeof(pointer) used in memory operations.
  #
  #   Example:
  #       memset(ptr, 0, sizeof(ptr));    // probably wrong
  -Wsizeof-pointer-memaccess

  # -Wsizeof-array-div
  #   Warn about suspicious sizeof(array) / sizeof(pointer-or-wrong-type)
  #   element-count calculations.
  -Wsizeof-array-div

  # -Wmemset-elt-size
  #   Warn when memset appears to use element count instead of byte count.
  -Wmemset-elt-size

  # -Wmemset-transposed-args
  #   Warn about suspicious memset argument order.
  #
  #   Example:
  #       memset(buf, sizeof(buf), 0);    // probably meant memset(buf, 0, sizeof buf)
  -Wmemset-transposed-args

  # -Wtrampolines
  #   Warn when GCC must generate trampolines, often caused by nested functions
  #   whose addresses escape.
  #
  #   Trampolines can require executable stack. Avoid in hardened/portable C.
  -Wtrampolines

  # -Wdate-time
  #   Warn on __DATE__, __TIME__, __TIMESTAMP__.
  #
  #   These macros make builds non-reproducible.
  -Wdate-time

  # -Wredundant-decls
  #   Warn about redundant declarations.
  #
  #   Useful for header hygiene, but can be noisy if system headers or legacy
  #   patterns repeat declarations.
  -Wredundant-decls
)

# =============================================================================
# MARK: Stack Bound
# Warning group 4: the stack a function may take
# =============================================================================
#
# CFLAGS_WARN_STACK (every profile without instrumentation: sanitizers and
# coverage measure their own frames, not the code's)
#
# -Wframe-larger-than=<n>
#   Warn about a function whose frame exceeds n bytes.
#
# -Wstack-usage=<n>
#   Warn about a function whose stack use may exceed n bytes, and about any
#   whose use is unbounded (a VLA, alloca): every frame has a fixed bound.
#
# n is GCC_BUILD_STACK_MAX, default 16384 bytes: above the largest frame
# measured across the platform's code for 3.1.0, with headroom.
#
GCC_BUILD_STACK_MAX="${GCC_BUILD_STACK_MAX:-16384}"
CFLAGS_WARN_STACK=(
  -Wframe-larger-than="${GCC_BUILD_STACK_MAX}"
  -Wstack-usage="${GCC_BUILD_STACK_MAX}"
)

# =============================================================================
# MARK: Zero Warnings
# Every warning is an error, in every profile; every link refuses its warnings
# =============================================================================
#
# -Werror
#   A warning fails the build. The pipeline's warnings stage also refuses any
#   warning line a tool printed without stopping (check_warnings.sh).
#
# -Wl,--fatal-warnings
#   The linker's -Werror: an executable-stack note, a dangerous-function note,
#   a textrel, any ld warning fails the link.
#
CFLAGS_WARN_ERROR=(
  -Werror
)

LDFLAGS_FATAL=(
  -Wl,--fatal-warnings
)

CFLAGS_WARN_ALL=(
  "${CFLAGS_WARN_CORE[@]}"
  "${CFLAGS_WARN_API[@]}"
  "${CFLAGS_WARN_STRICT[@]}"
  "${CFLAGS_WARN_PARANOID[@]}"
  "${CFLAGS_WARN_ERROR[@]}"
)

# =============================================================================
# MARK: Left Out
# Warnings measured and left out of the set, with the reason
# =============================================================================
#
#   -Wstrict-overflow=5     reports the optimizer's assumptions, not the code's
#                           defects, and changes with each GCC; the sanitize
#                           profile's UBSan catches a real signed overflow
#   -Warith-conversion      -Wconversion on arithmetic whose operands already
#                           have the result's type: a cast on every narrow sum,
#                           and casts hide the conversions -Wconversion exists
#                           to show
#   -Wpadded                padding is a layout choice; the ABI gate records it
#   -Wunused-macros         a macro used under one profile's #if only (NDEBUG,
#                           a test seam) reads as unused in every other profile
#   -Wdisabled-optimization a compiler resource limit, not a code defect
#   -Wtraditional*, -Wc++-compat, -Wdeclaration-after-statement
#                           other dialects' rules, not C11's
#   -Wunsuffixed-float-constants, -Wlarger-than=
#                           no defect class this code has
#   GCC 14+ only (-Wflex-array-member-not-at-end, -Wcalloc-transposed-args
#   outside -Wextra, -Wheader-guard, -Wtrailing-whitespace): the build root's
#   gcc 13 does not know them; revisit with the next root
#

# =============================================================================
# MARK: GCC Analyzer
# Static analyzer group
# =============================================================================
#
# CFLAGS_GCC_ANALYZER
# -------------------
# -fanalyzer enables GCC's path-sensitive static analyzer.
#
# It tries to find problems such as:
#   - double free;
#   - use after free;
#   - file descriptor leaks;
#   - memory leaks;
#   - null dereferences;
#   - use of uninitialized values;
#   - impossible paths.
#
# Compile-time cost: can be very high.
# Runtime cost: none.
# Binary-size cost: none.
# False positives: possible, and they differ between GCC releases.
# In the audit profile, over the library, the binaries and the tests: under
# -Werror its findings fail the build like any warning. A second analyzer pass
# over the release profile was measured for 3.1.0 and found nothing the audit
# pass does not, so there is no separate stage.
#
CFLAGS_GCC_ANALYZER=(
  -fanalyzer
)

# =============================================================================
# MARK: Sanitizers
# Sanitizer groups
# =============================================================================
#
# Sanitizers insert runtime instrumentation into the binary. They are among the
# most effective tools available for C testing, but they are not release flags.
#
# Important sanitizer rule
# ------------------------
# AddressSanitizer and ThreadSanitizer should not be combined in the same
# build. Use separate profiles.
#
# This file's sanitize profile uses ASan, UBSan, and LSan. If thread analysis
# is required, use CFLAGS_TSAN / LDFLAGS_TSAN below.
#
CFLAGS_SANITIZER_ADDRESS=(
  # -fsanitize=address
  #   Detects many memory bugs:
  #       heap buffer overflow
  #       stack buffer overflow
  #       global buffer overflow
  #       use after free
  #       use after scope in some cases
  #
  #   Runtime cost: high, commonly ~1.5x-3x slower.
  #   Memory cost: high, often ~2x or more.
  #   Release use: no.
  -fsanitize=address

  # -fsanitize=undefined
  #   Detects many forms of undefined behavior at runtime:
  #       signed integer overflow
  #       invalid shifts
  #       misaligned access
  #       null passed where nonnull is required
  #       out-of-bounds in some cases
  #       invalid enum values in some cases
  #
  #   Runtime cost: moderate.
  #   Release use: generally no, except special hardened diagnostic builds.
  -fsanitize=undefined

  # -fsanitize=leak
  #   Detects memory leaks at process exit.
  #
  #   Note: often included with AddressSanitizer on Linux, but explicit is fine.
  #   Runtime cost: mostly at shutdown/reporting.
  -fsanitize=leak
)

CFLAGS_SANITIZER_THREAD=(
  # -fsanitize=thread
  #   Detects data races and some threading misuse.
  #
  #   Runtime cost: very high, commonly 5x-15x slower.
  #   Memory cost: high.
  #   Cannot be combined with AddressSanitizer.
  #   Use for concurrent code: worker threads, queues, reactors, caches, etc.
  -fsanitize=thread
)

CFLAGS_SANITIZER_DIAGNOSTICS=(
  # -fno-optimize-sibling-calls
  #   Preserve more call frames in sanitizer reports. This pairs with
  #   -fno-omit-frame-pointer for clearer backtraces.
  -fno-optimize-sibling-calls
)

# Link-time sanitizer note
# ------------------------
# For GCC driver links, sanitizer flags must be present at link time too so the
# correct sanitizer runtime libraries are pulled in.
#
LDFLAGS_SANITIZER_ADDRESS=(
  "${CFLAGS_SANITIZER_ADDRESS[@]}"
)

LDFLAGS_SANITIZER_THREAD=(
  "${CFLAGS_SANITIZER_THREAD[@]}"
)

# =============================================================================
# MARK: Coverage Instrumentation
# Optional coverage instrumentation
# =============================================================================
#
# Coverage instrumentation is kept separate from the main profile lineup on
# purpose. It is not a "normal build profile" by itself. Instead, it is a
# composable extra that can be layered on top of another build when you
# explicitly want coverage data.
#
# Typical use:
#
#   - start from a base profile that represents the behavior you care about;
#   - add coverage instrumentation;
#   - build a derived variant such as release_cov.
#
# This keeps the reusable profile lineup clean while still making coverage
# support available to build scripts.
#
# CFLAGS_INSTRUMENT_COVERAGE / LDFLAGS_INSTRUMENT_COVERAGE
# --------------------------------------------------------
# --coverage is GCC's convenience switch for gcov-style instrumentation.
#
# In practice it enables the compile/link support needed to produce:
#   - .gcno files at build time;
#   - .gcda files when the instrumented code actually runs.
#
# Important:
#   - instrumentation must be present when compiling the code you want covered;
#   - link with --coverage as well so the gcov runtime support is included;
#   - coverage is usually meaningful on a debug-ish or release-ish build you
#     intentionally chose, not as a permanent always-on default.
#
# Runtime cost: noticeable.
# Binary-size cost: higher.
# Build-artifact side effects: produces .gcno/.gcda files.
#
CFLAGS_INSTRUMENT_COVERAGE=(
  # --coverage
  #   Enable gcov-compatible coverage instrumentation.
  #
  #   This is the flag you will usually want to see in the build script when a
  #   coverage-specific variant is being produced.
  --coverage
  # -fprofile-update=atomic
  #   Update the gcov counters atomically. Any code that runs on several threads
  #   WITHOUT a lock (EMlog's default emit path, ring buffers, the uuid7 CAS loop)
  #   otherwise races on the counters and gcov emits negative hit counts that
  #   gcovr refuses (GCC bug 68080). Slightly slower instrumented binaries; the
  #   counts become trustworthy.
  -fprofile-update=atomic
)

LDFLAGS_INSTRUMENT_COVERAGE=(
  # --coverage
  #   Repeat coverage instrumentation at link time so the gcov runtime support
  #   is linked into the final executable or shared-library link step.
  --coverage
)

# =============================================================================
# MARK: Hardening
# Instrumentation / hardening flags
# =============================================================================
#
# These flags alter generated code. They belong in validation and production
# profiles by default, and should only be removed in the extreme profile when
# lower overhead is explicitly more important than defensive hardening.
#
CFLAGS_EXE_HARDENING=(
  # -fPIE
  #   Generate position-independent code suitable for PIE executables.
  #
  #   Executable release hardening: pair with -pie at link time.
  #   Shared libraries should normally use -fPIC and -shared instead.
  -fPIE
)

CFLAGS_HARDENING_FLAGS=(
  # -fstack-protector-strong
  #   Adds stack canary checks to functions that are more likely to suffer stack
  #   smashing: local arrays, address-taken locals, etc.
  #
  #   Runtime cost: usually small.
  #   Binary-size cost: small.
  #   Security value: good.
  #   Extreme-speed choice: may remove with -fno-stack-protector.
  -fstack-protector-strong

  # -fstack-clash-protection
  #   Protects against stack clash attacks which involves exhausting the stack
  #   and causing a clash with another memory region, which can lead to code
  #   execution in some cases.
  
  # If the compiler emits code that adjusts the stack pointer by a huge amount at once:
  # - sub rsp, huge_size
  # then the program may jump over the guard page without touching it.
  # That is the “clash”: the stack can collide with another memory mapping.
  # What -fstack-clash-protection does
  # It changes stack allocation code so large stack growth happens page by page.
  # Conceptually, instead of:
  # - sub rsp, 1048576
  # the compiler emits something more like:
  # - loop:
  # -     sub rsp, 4096
  # -     touch [rsp]
  # -     repeat until enough stack allocated
  # So every memory page is touched while the stack grows.
  # If there is a guard page, the program hits it and crashes immediately instead
  # of silently jumping past it.

  # use when:
  # VLA
  # alloca()
  # large local arrays
  # deep recursion
  # parser code
  # decompression code
  # untrusted input controlling sizes
  # thread stacks
  # embedded-ish fixed stack limits

  #   Runtime cost: usually small.
  #   Binary-size cost: small.
  #   Security value: good.
  -fstack-clash-protection

  # -fcf-protection=full
  #   x86-64 Control-flow Enforcement Technology (CET): indirect-branch
  #   tracking (endbr64 landing pads) + shadow-stack support for returns.
  #
  #   On CPUs without CET the landing pads execute as NOPs: tiny code-size
  #   cost, no measurable time cost. On CET-capable CPUs (Intel 11th gen+,
  #   AMD Zen 3+) control-flow hijacks hit a hardware fault.
  #   Every Ubuntu distro package is built with this; our code should not be
  #   the least-protected code in the process.
  #
  #   Portability: x86-64 GCC/Linux. Remove for other architectures.
  -fcf-protection=full

  # Deliberately NOT enabled (measured decisions, revisit with benchmarks):
  #
  # -ftrivial-auto-var-init=zero
  #   Zero-fills locals the code does not initialize — stops stack info
  #   leaks, but pays a real memset cost in hot paths. This codebase
  #   initializes and bounds-checks aggressively, so the marginal value is
  #   low. Adopt only if tests/stress shows the cost is under the noise
  #   floor.
  #
  # -fno-plt
  #   With -z now everywhere, PLT indirection is pure overhead and this
  #   turns cross-.so calls into direct GOT loads. Likely a small WIN, not a
  #   cost — benchmark before adopting so the claim is proven, not assumed.

  # -fno-common
  #   Make tentative global definitions behave strictly.
  #
  #   Catches accidental multiple global definitions at link time.
  #   Modern GCC defaults to -fno-common already, but keeping it explicit.
  #
  #   Runtime cost: none.
  -fno-common
)

LDFLAGS_EXE_HARDENING=(
  # -pie
  #   Link a position-independent executable. Use for executable release
  #   profiles, not shared-library links (see LDFLAGS_SHARED warning).
  -pie

  # -Wl,-z,relro / -Wl,-z,now
  #   Ask the linker for RELRO and immediate binding. This hardens executable
  #   relocation tables at the cost of resolving symbols at startup.
  #   For a long-running server the startup cost is paid exactly once.
  -Wl,-z,relro
  -Wl,-z,now

  # -Wl,-z,noexecstack
  #   Assert a non-executable stack for the final executable. Nearly always
  #   already true (every object carries .note.GNU-stack), but explicit means
  #   a stray asm object cannot silently regress it. glibc 2.41+ refuses
  #   executable stacks outright — this just front-runs the platform.
  -Wl,-z,noexecstack
)

CFLAGS_SHARED=(
  # -fPIC
  #   Generate position-independent code suitable for shared libraries.
  #   Use this instead of -fPIE when compiling objects for .so output.
  -fPIC
)

LDFLAGS_SHARED=(
  # -shared
  #   Link a shared library. Keep this separate from executable -pie policy.
  #
  #   IMPORTANT: never pass LDFLAGS_RELEASE/LDFLAGS_NATIVE (which contain -pie)
  #   into a shared-library link. `gcc -shared ... -pie` makes the driver link
  #   an executable image (it pulls Scrt1.o and demands main) — the .so link
  #   FAILS. Shared links take THIS array; executable links take the profile
  #   LDFLAGS. Verified on GCC 13 / binutils 2.42.
  -shared

  # -Wl,-z,relro / -Wl,-z,now
  #   Full RELRO for the shared library itself: after the dynamic linker
  #   resolves everything at load time, the .so's GOT/PLT pages are remapped
  #   read-only. Without this, a write primitive anywhere in the process can
  #   redirect the library's own outgoing calls.
  #
  #   Cost: symbol resolution happens at load instead of first call — a
  #   one-time startup cost, irrelevant for long-running services.
  -Wl,-z,relro
  -Wl,-z,now

  # -Wl,-z,noexecstack
  #   Assert that nothing in this library requires an executable stack. One
  #   stray object (hand-written asm without a .note.GNU-stack section) would
  #   otherwise silently flip the WHOLE process stack to executable.
  -Wl,-z,noexecstack

  # -Wl,-z,defs
  #   Refuse to produce a .so with undefined symbols. An underlinked library
  #   fails HERE, loudly, at build time — not at load time on the target box.
  #   (House doctrine: fail fast, fail loud.)
  -Wl,-z,defs

  # -Wl,--as-needed
  #   Only record DT_NEEDED entries for libraries that actually satisfy a
  #   symbol reference. Keeps the dependency surface honest.
  -Wl,--as-needed

  # -Wl,--fatal-warnings
  #   Any linker warning fails the link (LDFLAGS_FATAL).
  -Wl,--fatal-warnings
)

# =============================================================================
# MARK: Debuggability
# Debuggability flags
# =============================================================================
#
CFLAGS_DEBUG_INFO=(
  # -g3
  #   Emit maximum debug information, including macro definitions.
  #
  #   Runtime cost: normally none.
  #   Binary/object/debug file size: much larger.
  #   Compile/link cost: somewhat higher.
  -g3

  # -fno-omit-frame-pointer
  #   Keep frame pointers.
  #
  #   Runtime cost: small on some architectures/workloads.
  #   Debug/profiling value: excellent. Stack traces become more reliable.
  -fno-omit-frame-pointer
)

# =============================================================================
# MARK: Optimization Groups
# Optimization groups
# =============================================================================
#
CFLAGS_OPT_DEBUG=(
  # -Og
  #   Generate machine code optimized for debugging.
  #
  #   Good for stepping in GDB. Not the strongest sanitizer choice, not the
  #   fastest runtime choice.
  -Og
)

CFLAGS_OPT_CHECKED=(
  # -O1
  #   Light optimization.
  #
  #   Why not -O0 for sanitizer testing?
  #   Because some compiler diagnostics and sanitizer checks work better when
  #   the compiler performs at least basic analysis. -O1 is a good sanitizer
  #   default.
  #
  #   Runtime: much faster than -O0, slower than -O2/-O3.
  #   Debuggability: still decent with -g3 and frame pointers.
  -O1
)

CFLAGS_OPT_RELEASE=(
  # -O2
  #   Strong general-purpose optimization.
  #
  #   Compared with -O3, -O2 is usually the safer default production target:
  #   fewer aggressive code transformations, often smaller binaries, and more
  #   stable build times. Many real programs are no slower under -O2.
  #
  #   Runtime: usually high.
  #   Compile time: moderate.
  #   Binary size: usually smaller than -O3.
  #   Risk: can still make latent undefined behavior surface more aggressively
  #         than debug or sanitizer builds.
  -O2
)

# Optional release ISA baseline (build-on-target deployments).
# ------------------------------------------------------------
# This platform builds its debs ON the machine that runs them, so the
# portable-binary constraint is a choice, not a necessity. Export
#
#   GCC_BUILD_MARCH=x86-64-v3      (or: native, x86-64-v2, ...)
#
# to give the release profile a CPU baseline and buy back the hardening cost
# with interest. Default is unset = fully portable release. Never bake
# -march=native into a deb that could migrate to another box.
if [[ -n "${GCC_BUILD_MARCH:-}" ]]; then
    CFLAGS_OPT_RELEASE+=("-march=${GCC_BUILD_MARCH}")
fi

CFLAGS_OPT_NATIVE=(
  # -O3
  #   Aggressive optimization.
  #
  #   Enables more inlining, vectorization, loop transformations, and other
  #   optimizations beyond -O2.
  #
  #   Runtime: often fastest, but not always. Sometimes -O2 is smaller/faster.
  #   Compile time: higher than -O2.
  #   Binary size: may increase due to inlining/unrolling.
  #   Risk: can make latent undefined behavior surface more aggressively.
  -O3

  # -flto
  #   Link Time Optimization.
  #
  #   Allows optimization across translation units.
  #
  #   Runtime: can improve speed and/or reduce size.
  #   Compile/link time: higher, sometimes much higher.
  #   Tooling risk: needs compatible compiler, linker plugin, and archive tools.
  #   Use gcc-ar/gcc-ranlib for static libraries when needed.
  #   =auto: the link-time code generation runs in parallel (make's jobserver,
  #   else one job per CPU); a bare -flto compiles serially and lto-wrapper
  #   says so with a warning.
  -flto=auto

  # -march=native
  #   Generate instructions for the CPU of the build machine.
  #
  #   Runtime: can improve performance significantly for CPU-heavy code.
  #   Portability: bad for distributing binaries. The program may crash with
  #   illegal instruction on older/different CPUs.
  #
  #   Excellent for local benchmarks and deployment to identical machines.
  -march=native
)

CFLAGS_OPT_EXTREME=(
  # -O3
  #   Same aggressive optimization as native.
  -O3

  # -flto=auto
  #   Whole-program-ish optimization at link time, in parallel.
  -flto=auto

  # -march=native
  #   Generate instructions for the CPU of the build machine.
  #
  #   Runtime: can improve performance significantly for CPU-heavy code.
  #   Portability: bad for distributing binaries. The program may crash with
  #   illegal instruction on older/different CPUs.
  #
  #   Excellent for local benchmarks and deployment to identical machines.
  -march=native

  # -fomit-frame-pointer
  #   Allow compiler to use the frame pointer register for general optimization.
  #
  #   Runtime: sometimes small speed gain.
  #   Debug/profiling: worse stack traces on some platforms/tools.
  -fomit-frame-pointer

  # -fno-stack-protector
  #   Explicitly remove stack canaries.
  #
  #   Runtime: tiny speed/size gain in affected functions.
  #   Security/safety: worse.
  #
  #   Use only for the "I want the lightest fastest local binary" profile.
  -fno-stack-protector
)

# =============================================================================
# MARK: Link-Time Optimization Policy
# Link-time notes
# =============================================================================
#
# When LTO is enabled during compilation, pass -flto again during the final link
# so the GCC driver runs the LTO pipeline and loads the required linker plugin.
#
LDFLAGS_LTO=(
  # -flto=auto
  #   Repeat LTO at link time so the link step performs cross-translation-unit
  #   optimization instead of merely seeing object files that were compiled with
  #   LTO metadata; =auto runs its code generation in parallel.
  -flto=auto

  # -Werror
  #   The link-time compilation reports its own warnings (a type mismatch
  #   across units, a late overflow): they fail the link like any other.
  -Werror
)

# =============================================================================
# MARK: Ofast Policy
# Optional dangerous optimization: -Ofast
# =============================================================================
#
# This file deliberately does not use -Ofast by default.
#
# -Ofast enables -O3 plus optimizations that may violate strict standards
# semantics, especially floating-point behavior. It may imply flags such as
# -ffast-math depending on compiler version.
#
# For robotics, simulation, filtering, control, orbital math, geometry, and any
# code where NaN/Inf handling, rounding, or IEEE semantics matter, -Ofast
# should not be adopted casually.
#
# For pure integer-heavy systems code, it may be worth benchmarking, but still
# test carefully.
#
# If you want an experimental profile, add -Ofast manually and compare against
# -O3 with tests and benchmarks.
#

# =============================================================================
# MARK: Build Profiles
# Build profiles
# =============================================================================

# MARK: Debug Profile
# DEBUG PROFILE
# -------------
# Friction-minimized development profile.
#
# Use for:
#   - day-to-day development;
#   - interactive debugging;
#   - stepping through control flow.
#
# Properties:
#   Compile time: low to medium.
#   Runtime speed: moderate.
#   Memory usage: normal.
#   Debuggability: excellent.
#   Warning strictness: the whole set, as every profile.
#   Hardening: intentionally minimal.
#   Release suitability: not suitable.
#
CPPFLAGS_DEBUG=(
  "${CPPFLAGS_BASE[@]}"
)

CFLAGS_DEBUG=(
  "${CFLAGS_BASE[@]}"
  "${CFLAGS_WARN_ALL[@]}"
  "${CFLAGS_WARN_STACK[@]}"
  "${CFLAGS_OPT_DEBUG[@]}"
  "${CFLAGS_DEBUG_INFO[@]}"

  # -fno-inline
  #   Discourage inlining so function boundaries stay visible while debugging.
  #
  #   Debugging value: excellent.
  #   Runtime cost: can be noticeable for tiny hot functions.
  -fno-inline
)

LDFLAGS_DEBUG=(
  "${LDFLAGS_FATAL[@]}"
)

# MARK: Audit Profile
# AUDIT PROFILE
# -------------
# Compiler-centric validation profile.
#
# Use for:
#   - warning cleanup passes;
#   - API hygiene;
#   - static-analysis sweeps;
#   - "make the compiler complain about everything interesting" sessions.
#
# Properties:
#   Compile time: high to very high because of warning breadth and -fanalyzer.
#   Runtime speed: moderate.
#   Memory usage: normal.
#   Debuggability: good.
#   Runtime instrumentation: none.
#   Release suitability: not suitable.
#
# This profile intentionally separates compile-time quality enforcement from
# runtime sanitizer instrumentation. That makes it useful when you want the
# compiler to do the heavy thinking without paying AddressSanitizer runtime cost.
#
CPPFLAGS_AUDIT=(
  "${CPPFLAGS_BASE[@]}"
  "${CPPFLAGS_HARDENING[@]}"
)

CFLAGS_AUDIT=(
  "${CFLAGS_BASE[@]}"
  "${CFLAGS_WARN_ALL[@]}"
  "${CFLAGS_WARN_STACK[@]}"
  "${CFLAGS_OPT_CHECKED[@]}"
  "${CFLAGS_DEBUG_INFO[@]}"
  "${CFLAGS_GCC_ANALYZER[@]}"
  "${CFLAGS_HARDENING_FLAGS[@]}"
)

LDFLAGS_AUDIT=(
  "${LDFLAGS_FATAL[@]}"
)

# MARK: Sanitize Profile
# SANITIZE PROFILE
# ----------------
# High-diagnostic runtime validation profile.
#
# Use for:
#   - unit tests;
#   - fuzz tests;
#   - integration tests;
#   - filesystem, path, and database stress tests;
#   - pre-release defect hunting for memory bugs and UB.
#
# Properties:
#   Compile time: high.
#   Runtime speed: slow.
#   Memory usage: high.
#   Debuggability: good.
#   Release suitability: not suitable.
#
# This profile is the runtime-bug-hunting answer to the old generic "test"
# build idea. If you want compile-time analysis, use audit. If you want runtime
# memory/UB detection, use sanitize. If you want shipping behavior, test release
# or native directly.
#
CPPFLAGS_SANITIZE=(
  "${CPPFLAGS_BASE[@]}"

  # -U_FORTIFY_SOURCE — and deliberately NO -D_FORTIFY_SOURCE here.
  #
  #   _FORTIFY_SOURCE and AddressSanitizer conflict: fortified calls are
  #   routed to glibc __*_chk variants that BYPASS ASan's interceptors, so
  #   the exact overflows this profile exists to catch can be masked (or
  #   double-reported). The sanitizer owns memory checking in this profile;
  #   fortify hardening belongs to audit/release/native.
  -U_FORTIFY_SOURCE
)

CFLAGS_SANITIZE=(
  "${CFLAGS_BASE[@]}"
  "${CFLAGS_WARN_ALL[@]}"
  "${CFLAGS_OPT_CHECKED[@]}"
  "${CFLAGS_DEBUG_INFO[@]}"
  "${CFLAGS_SANITIZER_ADDRESS[@]}"
  "${CFLAGS_SANITIZER_DIAGNOSTICS[@]}"
  "${CFLAGS_HARDENING_FLAGS[@]}"
)

LDFLAGS_SANITIZE=(
  "${LDFLAGS_SANITIZER_ADDRESS[@]}"
  "${LDFLAGS_FATAL[@]}"
)

# MARK: Release Profile
# RELEASE PROFILE
# ---------------
# Portable production profile with baseline hardening.
#
# Use for:
#   - standard release builds;
#   - representative performance testing;
#   - deployed binaries where baseline hardening still matters.
#
# Properties:
#   Compile time: medium.
#   Runtime speed: high.
#   Memory usage: normal.
#   Debuggability: lower than sanitize/debug.
#   Safety: still keeps stack protector and fortify.
#   Portability: much better than native/extreme.
#
# This file intentionally keeps the default release profile at -O2 and without
# LTO. The goal is a strong, portable production default rather than trying to
# win every benchmark in the generic release profile.
#
CPPFLAGS_RELEASE=(
  "${CPPFLAGS_BASE[@]}"
  "${CPPFLAGS_HARDENING[@]}"
  "${CPPFLAGS_RELEASE_POLICY[@]}"
)

CFLAGS_RELEASE=(
  "${CFLAGS_BASE[@]}"
  "${CFLAGS_WARN_ALL[@]}"
  "${CFLAGS_WARN_STACK[@]}"
  "${CFLAGS_OPT_RELEASE[@]}"
  "${CFLAGS_EXE_HARDENING[@]}"
  "${CFLAGS_HARDENING_FLAGS[@]}"
)

LDFLAGS_RELEASE=(
  "${LDFLAGS_EXE_HARDENING[@]}"
  "${LDFLAGS_FATAL[@]}"
)

# MARK: Native Profile
# NATIVE PROFILE
# --------------
# Local-machine tuned release-like profile.
#
# Use for:
#   - local performance validation;
#   - benchmark experiments on the deployment-equivalent machine;
#   - proving whether -O3 + LTO + -march=native buy you anything meaningful;
#   - running the same test suite on a faster but still hardened build.
#
# Properties:
#   Compile time: high.
#   Runtime speed: potentially very high on the build-machine CPU class.
#   Memory usage: normal.
#   Debuggability: lower than release.
#   Portability: low because of -march=native.
#   Safety: still keeps stack protector and fortify.
#
# This profile fills the gap between portable release and deliberately unsafe
# extreme. It is the "serious local benchmark" profile.
#
CPPFLAGS_NATIVE=(
  "${CPPFLAGS_BASE[@]}"
  "${CPPFLAGS_HARDENING[@]}"
  "${CPPFLAGS_RELEASE_POLICY[@]}"
)

CFLAGS_NATIVE=(
  "${CFLAGS_BASE[@]}"
  "${CFLAGS_WARN_ALL[@]}"
  "${CFLAGS_WARN_STACK[@]}"
  "${CFLAGS_OPT_NATIVE[@]}"
  "${CFLAGS_EXE_HARDENING[@]}"
  "${CFLAGS_HARDENING_FLAGS[@]}"
)

LDFLAGS_NATIVE=(
  "${LDFLAGS_LTO[@]}"
  "${LDFLAGS_EXE_HARDENING[@]}"
  "${LDFLAGS_FATAL[@]}"
)

# MARK: Extreme Profile
# EXTREME PROFILE
# ---------------
# Maximum-performance local-machine profile.
#
# Use for:
#   - benchmark experiments;
#   - local-only binaries;
#   - controlled deployment to known identical CPUs;
#   - cases where you explicitly accept less hardening/debuggability.
#
# Properties:
#   Compile time: high.
#   Runtime speed: potentially highest.
#   Memory usage: normal.
#   Debuggability: low.
#   Portability: low because of -march=native.
#   Safety/hardening: intentionally reduced.
#
# This profile exists for narrowly scoped performance work. It should not be
# confused with the default release configuration.
#
CPPFLAGS_EXTREME=(
  "${CPPFLAGS_BASE[@]}"
  "${CPPFLAGS_RELEASE_POLICY[@]}"
  "${CPPFLAGS_EXTREME_POLICY[@]}"
)

CFLAGS_EXTREME=(
  "${CFLAGS_BASE[@]}"

  # The whole set: warnings have no runtime cost.
  "${CFLAGS_WARN_ALL[@]}"
  "${CFLAGS_WARN_STACK[@]}"

  "${CFLAGS_OPT_EXTREME[@]}"
)

LDFLAGS_EXTREME=(
  "${LDFLAGS_LTO[@]}"
  "${LDFLAGS_FATAL[@]}"
)

# MARK: TSAN Profile
# TSAN PROFILE
# ------------
# Optional dedicated ThreadSanitizer profile.
#
# Use for:
#   - auditing concurrent code;
#   - race detection;
#   - validation of thread coordination paths.
#
# Properties:
#   Compile time: high.
#   Runtime speed: very slow.
#   Memory usage: very high.
#   Release suitability: not suitable.
#
CPPFLAGS_TSAN=(
  "${CPPFLAGS_BASE[@]}"
)

CFLAGS_TSAN=(
  "${CFLAGS_BASE[@]}"
  "${CFLAGS_WARN_ALL[@]}"
  "${CFLAGS_OPT_CHECKED[@]}"
  "${CFLAGS_DEBUG_INFO[@]}"
  "${CFLAGS_SANITIZER_THREAD[@]}"
  "${CFLAGS_SANITIZER_DIAGNOSTICS[@]}"
  -fno-common
)

LDFLAGS_TSAN=(
  "${LDFLAGS_SANITIZER_THREAD[@]}"
  "${LDFLAGS_FATAL[@]}"
)

# =============================================================================
# MARK: Coverage Profile
# Coverage profile: the debug profile at -O0 with the coverage layer
# =============================================================================
#
# What lib/test.sh compiles a coverage run with (library and tests alike): -O0
# after -Og so gcov line and branch data map one to one onto the source. Not in
# GCC_BUILD_PROFILES: nothing ships from it. No stack bound: instrumented frames.
#
CPPFLAGS_COVERAGE=(
  "${CPPFLAGS_DEBUG[@]}"
)

CFLAGS_COVERAGE=(
  "${CFLAGS_BASE[@]}"
  "${CFLAGS_WARN_ALL[@]}"
  "${CFLAGS_OPT_DEBUG[@]}"
  "${CFLAGS_DEBUG_INFO[@]}"
  -fno-inline
  -O0
  "${CFLAGS_INSTRUMENT_COVERAGE[@]}"
)

LDFLAGS_COVERAGE=(
  "${LDFLAGS_DEBUG[@]}"
  "${LDFLAGS_INSTRUMENT_COVERAGE[@]}"
)

# =============================================================================
# MARK: Cost Summary
# Build-time / runtime cost summary
# =============================================================================
#
# Approximate qualitative cost summary for individual flag families:
#
#   warnings only
#       Compile time: low to medium
#       Runtime cost: none
#       Binary size: none
#
#   -fanalyzer
#       Compile time: high to very high
#       Runtime cost: none
#       Binary size: none
#
#   -fsanitize=address
#       Compile time: medium
#       Runtime cost: high
#       Memory cost: high
#       Binary size: higher
#
#   -fsanitize=undefined
#       Compile time: medium
#       Runtime cost: low to medium
#       Binary size: higher
#
#   -fsanitize=thread
#       Compile time: high
#       Runtime cost: very high
#       Memory cost: very high
#
#   -fstack-protector-strong
#       Compile time: tiny
#       Runtime cost: usually tiny
#       Binary size: slightly higher
#
#   -D_FORTIFY_SOURCE=<level>
#       Compile time: low
#       Runtime cost: usually low/tiny
#       Binary size: maybe slightly higher
#
#   -O2
#       Compile time: moderate
#       Runtime speed: usually high
#       Binary size: usually moderate
#
#   -O3
#       Compile time: medium/high
#       Runtime speed: usually high, sometimes not better than -O2
#       Binary size: can increase
#
#   -flto
#       Compile/link time: high
#       Runtime speed: can improve
#       Binary size: can improve or worsen
#       Tooling: needs compatible build pipeline
#
#   -march=native
#       Compile time: normal
#       Runtime speed: can improve
#       Portability: bad outside the build machine class
#
# Approximate qualitative cost summary for the ready-made profiles:
#
#   debug
#       Compile time: low to medium
#       Runtime speed: moderate
#       Debuggability: excellent
#
#   audit
#       Compile time: high to very high
#       Runtime speed: moderate
#       Best for: compiler-driven cleanup
#
#   sanitize
#       Compile time: high
#       Runtime speed: slow
#       Memory usage: high
#       Best for: runtime memory / UB bug hunting
#
#   release
#       Compile time: medium
#       Runtime speed: high
#       Portability: good
#
#   native
#       Compile time: high
#       Runtime speed: potentially very high on the build-machine CPU class
#       Portability: low
#
#   extreme
#       Compile time: high
#       Runtime speed: potentially highest
#       Safety / debuggability: intentionally reduced
#
#   tsan
#       Compile time: high
#       Runtime speed: very slow
#       Memory usage: very high
#
# =============================================================================
# MARK: Build Policy
# Suggested make/build-script policy
# =============================================================================
#
# Suggested default policy:
#
#   during development:
#       debug
#
#   before merging:
#       audit
#       sanitize
#       release
#       tsan if the code is threaded
#
#   before performance claims:
#       release benchmark
#       native benchmark
#       extreme benchmark only after release/native pass tests
#
#   for CI:
#       audit
#       sanitize
#       tsan where relevant
#       release
#
# Zero warnings (3.1.0): -Werror and --fatal-warnings are in every profile, the
#   tests' builds included. A dependency's headers are included with -isystem
#   and gated in their own repository; vendored code (app/extern) is built under
#   its repository's KYR_LIB_VENDOR_CFLAGS, never -w, never silenced inline. A
#   project file may still extend an array (gcc_build_add), never with -Wno-*:
#   the pipeline's pragmas stage refuses it outside pragmas.allow.
#
# Linker hardening — two distinct policies, never mixed:
#   Executables (release/native LDFLAGS):
#       -fPIE (compile) + -pie -Wl,-z,relro,-z,now,-z,noexecstack (link)
#   Shared libraries (ALWAYS link with LDFLAGS_SHARED, never profile LDFLAGS):
#       -fPIC (compile) + -shared -Wl,-z,relro,-z,now,-z,noexecstack,-z,defs,
#       --as-needed (link)
#   Passing profile LDFLAGS (-pie) into a -shared link BREAKS the link — see
#   the LDFLAGS_SHARED comment.
#
# Artifact verification:
#   check_hardening.sh (same directory) asserts the resulting ELFs actually
#   carry PIE / full RELRO / non-exec stack / canaries. Build scripts run it
#   on release-profile artifacts; a red check fails the build.
#
# =============================================================================
# MARK: Project Overrides
# Per-project overrides: the catalog is the default, never a law
# =============================================================================
#
# A repository sources this catalog and then its own utils/<name>_project.sh.
# That file may extend or replace any array above with these helpers, or with
# plain bash (CFLAGS_RELEASE+=(...), CFLAGS_RELEASE=(...)). The reason lives
# in the project file next to the change.
#
#   gcc_build_add     CFLAGS_RELEASE -fno-plt              append flags
#   gcc_build_drop    CFLAGS_RELEASE -fcf-protection=full  remove every match
#   gcc_build_replace LDFLAGS_NATIVE -pie -Wl,-z,now       replace the whole array
#
gcc_build_add() {
    local -n _gcc_build_arr="$1"; shift
    _gcc_build_arr+=("$@")
}

gcc_build_drop() {
    local -n _gcc_build_arr="$1"; shift
    local kept=() flag drop keep
    for flag in "${_gcc_build_arr[@]}"; do
        keep=1
        for drop in "$@"; do [[ "${flag}" == "${drop}" ]] && keep=0; done
        (( keep )) && kept+=("${flag}")
    done
    _gcc_build_arr=("${kept[@]}")
}

gcc_build_replace() {
    local -n _gcc_build_arr="$1"; shift
    _gcc_build_arr=("$@")
}

# =============================================================================
# MARK: CLI
# Command-line interface
# =============================================================================

_explain() {
    cat <<'TXT'
Available profiles:

Every profile: the whole warning set, -Werror, -Wl,--fatal-warnings; the
stack bound (-Wframe-larger-than, -Wstack-usage) where nothing is instrumented.

  debug
      Development profile: -Og, -g3, frame pointers, no inlining, no forced
      stack protection.

  audit
      Compiler-centric validation profile: GCC static analyzer, debug
      information, and hardening.

  sanitize
      Runtime bug-hunting profile: ASan + UBSan + LSan, debug information, and
      hardening (minus _FORTIFY_SOURCE, which conflicts with ASan's
      interceptors).

  release
      Portable production profile: -O2, -DNDEBUG, and baseline hardening.

  native
      Local-machine tuned release-like profile: -O3, -flto=auto, -march=native,
      and hardening still enabled.

  extreme
      Maximum-performance local-machine profile: -O3, -flto=auto,
      -march=native, no frame pointer, no stack protector, and no fortify.

  tsan
      Optional ThreadSanitizer profile. Use separately from AddressSanitizer.

  coverage
      The debug profile at -O0 with gcov instrumentation (coverage runs only).

Examples:

  gcc $(./gcc_build_profiles.sh print-cppflags debug) \
      $(./gcc_build_profiles.sh print-cflags debug) \
      src/*.c -o app_debug \
      $(./gcc_build_profiles.sh print-ldflags debug)

  gcc $(./gcc_build_profiles.sh print-cppflags sanitize) \
      $(./gcc_build_profiles.sh print-cflags sanitize) \
      src/*.c -o app_sanitize \
      $(./gcc_build_profiles.sh print-ldflags sanitize)

  gcc $(./gcc_build_profiles.sh print-cppflags native) \
      $(./gcc_build_profiles.sh print-cflags native) \
      src/*.c -o app_native \
      $(./gcc_build_profiles.sh print-ldflags native)

  source ./gcc_build_profiles.sh
  gcc "${CPPFLAGS_RELEASE[@]}" "${CFLAGS_RELEASE[@]}" src/*.c -o app_release \
      "${LDFLAGS_RELEASE[@]}"
TXT
}

_profile_to_cpparray_name() {
    case "$1" in
        debug)    printf 'CPPFLAGS_DEBUG\n' ;;
        audit)    printf 'CPPFLAGS_AUDIT\n' ;;
        sanitize) printf 'CPPFLAGS_SANITIZE\n' ;;
        release)  printf 'CPPFLAGS_RELEASE\n' ;;
        native)   printf 'CPPFLAGS_NATIVE\n' ;;
        extreme)  printf 'CPPFLAGS_EXTREME\n' ;;
        tsan)     printf 'CPPFLAGS_TSAN\n' ;;
        coverage) printf 'CPPFLAGS_COVERAGE\n' ;;
        *)
            printf 'unknown profile: %s\n' "$1" >&2
            return 1
            ;;
    esac
}

_profile_to_carray_name() {
    case "$1" in
        debug)    printf 'CFLAGS_DEBUG\n' ;;
        audit)    printf 'CFLAGS_AUDIT\n' ;;
        sanitize) printf 'CFLAGS_SANITIZE\n' ;;
        release)  printf 'CFLAGS_RELEASE\n' ;;
        native)   printf 'CFLAGS_NATIVE\n' ;;
        extreme)  printf 'CFLAGS_EXTREME\n' ;;
        tsan)     printf 'CFLAGS_TSAN\n' ;;
        coverage) printf 'CFLAGS_COVERAGE\n' ;;
        *)
            printf 'unknown profile: %s\n' "$1" >&2
            return 1
            ;;
    esac
}

_profile_to_ldarray_name() {
    case "$1" in
        debug)    printf 'LDFLAGS_DEBUG\n' ;;
        audit)    printf 'LDFLAGS_AUDIT\n' ;;
        sanitize) printf 'LDFLAGS_SANITIZE\n' ;;
        release)  printf 'LDFLAGS_RELEASE\n' ;;
        native)   printf 'LDFLAGS_NATIVE\n' ;;
        extreme)  printf 'LDFLAGS_EXTREME\n' ;;
        tsan)     printf 'LDFLAGS_TSAN\n' ;;
        coverage) printf 'LDFLAGS_COVERAGE\n' ;;
        *)
            printf 'unknown profile: %s\n' "$1" >&2
            return 1
            ;;
    esac
}

_main() {
    local cmd="${1:-}"
    local profile="${2:-}"
    local arr_name

    case "$cmd" in
        explain|'')
            _explain
            ;;

        print-cppflags)
            if [[ -z "$profile" ]]; then
                printf 'usage: %s print-cppflags {debug|audit|sanitize|release|native|extreme|tsan|coverage}\n' "$0" >&2
                return 2
            fi
            arr_name="$(_profile_to_cpparray_name "$profile")" || return 2
            _print_array "$arr_name"
            ;;

        print-cflags)
            if [[ -z "$profile" ]]; then
                printf 'usage: %s print-cflags {debug|audit|sanitize|release|native|extreme|tsan|coverage}\n' "$0" >&2
                return 2
            fi
            arr_name="$(_profile_to_carray_name "$profile")" || return 2
            _print_array "$arr_name"
            ;;

        print-ldflags)
            if [[ -z "$profile" ]]; then
                printf 'usage: %s print-ldflags {debug|audit|sanitize|release|native|extreme|tsan|coverage}\n' "$0" >&2
                return 2
            fi
            arr_name="$(_profile_to_ldarray_name "$profile")" || return 2
            _print_array "$arr_name"
            ;;

        *)
            printf 'unknown command: %s\n' "$cmd" >&2
            printf 'usage: %s {explain|print-cppflags|print-cflags|print-ldflags} [profile]\n' "$0" >&2
            return 2
            ;;
    esac
}

# Only execute the helper CLI when run as a script, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _main "$@"
fi
