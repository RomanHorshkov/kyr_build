#!/usr/bin/env bash
# shellcheck shell=bash
# kyr_word_project.sh — everything project-specific. Rename to <repo>_project.sh (the prefix of the sysroot variables
# deps.sh exports: KYR_WORD_DEPS_INCLUDE_DIR / KYR_WORD_DEPS_LIB_DIR). Sourced after the profile catalog; override
# catalog flags here with gcc_build_add / gcc_build_drop / gcc_build_replace, with the reason next to the change.
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
