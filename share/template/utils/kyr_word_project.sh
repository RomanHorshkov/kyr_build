#!/usr/bin/env bash
# shellcheck shell=bash
# kyr_word_project.sh — everything project-specific, declarations only (template_check refuses a function or a compiler call
# here; the wrappers in utils/ are kyr-build's and never change). Rename to <repo>_project.sh (the prefix of the sysroot
# variables deps.sh exports: KYR_WORD_DEPS_INCLUDE_DIR / KYR_WORD_DEPS_LIB_DIR). Sourced after the profile catalog; override
# catalog flags here with gcc_build_add / gcc_build_drop / gcc_build_replace, with the reason next to the change. The names a
# repository may declare: kyr-build share/lib/build.sh (library, binaries, tests), lib/test.sh (suites, coverage, stress,
# fuzzing, smoke), lib/deb.sh (KYR_DEBS and the recipes), pipeline.sh (KYR_PIPELINE_EXTRA), template_check.sh (KYR_REPO_GATES).
KYR_LIB="kyr_word"
KYR_LIB_SOURCES=(app/src/word.c)
KYR_LIB_HEADER="app/include/kyr/word/word.h"
KYR_LIB_MAP="utils/kyr_word.map"
KYR_LIB_CPPFLAGS=(-I"${ROOT_DIR}/app/include" -isystem "${KYR_WORD_DEPS_INCLUDE_DIR:-${ROOT_DIR}/build/sysroot/include}")
KYR_LIB_LDLIBS=(-L"${KYR_WORD_DEPS_LIB_DIR:-${ROOT_DIR}/build/sysroot/lib}")
KYR_BIN=""
KYR_BIN_SOURCES=()
KYR_BIN_LDLIBS=()
KYR_TEST_SOURCES=(tests/UTs/word_tests.c)
KYR_TEST_LDLIBS=()
KYR_PKG="libkyr-word"
KYR_PKG_DESCRIPTION="kyr word library"
KYR_INCLUDE_ROOT="kyr/word"
# Build inputs (lib/epoch.sh) beyond app VERSION deps.txt utils debian, when a deb packages more: KYR_BUILD_INPUTS+=(web)
