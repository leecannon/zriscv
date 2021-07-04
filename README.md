# zriscv
[![CI](https://github.com/leecannon/zriscv/actions/workflows/main.yml/badge.svg?branch=master)](https://github.com/leecannon/zriscv/actions/workflows/main.yml)

RISC-V emulator in Zig

Requires [Gyro](https://github.com/mattnite/gyro) and git lfs.

## What to expect
This is the first emulator I've made other than CHIP-8, don't expect high quality nor speed.

The only thing that should be expected is mistakes.

## Short term goal
 - RV64GC 
 - user, super and machine mode 
 - single hart (this allows us to ignore memory ordering/synchronization)
