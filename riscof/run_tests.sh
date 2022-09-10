#!/bin/bash

set -e

die() {
    >&2 echo "die: $*"
    exit 1
}

RISCOF_BASE_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
TEST_DIR="$RISCOF_BASE_DIR/riscv-arch-test"
ZRISCV_BIN_DIR="$RISCOF_BASE_DIR/../zig-out/bin"

pushd $RISCOF_BASE_DIR > /dev/null

cleanup() {
   popd > /dev/null
}

trap cleanup EXIT

if [ ! -d $TEST_DIR ]; then
    echo "cloning riscv-arch-test"
    git clone --depth=1 --single-branch https://github.com/leecannon/riscv-arch-test.git $TEST_DIR &>/dev/null || die "couldn't clone riscv-arch-test"
else
    echo "updating riscv-arch-test"
    git -C $TEST_DIR pull &>/dev/null || die "couldn't update riscv-arch-test"
fi

riscof run --config=config.ini --suite=riscv-arch-test/riscv-test-suite/ --env=riscv-arch-test/riscv-test-suite/env --no-ref-run --no-dut-run
