# zriscv
[![CI](https://github.com/leecannon/zriscv/actions/workflows/main.yml/badge.svg?branch=master)](https://github.com/leecannon/zriscv/actions/workflows/main.yml)

RISC-V emulator in Zig

## What to expect
This is the first emulator I've made other than CHIP-8, don't expect high quality nor speed.

The only thing that should be expected is mistakes.

The focus is on correctness not performance, I'm expecting practically every execution path to be littered with potential optimization opportunities.

## Goal
 - RV64GC
 - user, super and machine mode
 - provide a linux userspace emulation similar to qemu's

## Progress
- [ ] RV64I (64-bit Base Integer)
- [ ] M (Multiplication and Division)
- [ ] A (Atomic)
- [ ] F (Single-Precision Floating-Point)
- [ ] D (Double-Precision Floating-Point)
- [ ] Zicsr (Control and Status Register)
- [ ] Zifencei (Instruction-Fetch Fence)
- [ ] C (Compressed Instructions)
- [ ] Counters
- [ ] Machine-Level ISA
- [ ] Supervisor-Level ISA
- [ ] CSRs

## Spec
The version of the riscv spec used is draft-20220825-1237e31 released 25/08/2022
