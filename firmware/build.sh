#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
# Usage: bash build.sh [image_28x28.png | image.bin | image.txt]
# Paths are relative to this script directory, or use absolute paths.
if [[ -z "${CROSS_COMPILE:-}" ]]; then
    if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
        CROSS_COMPILE=riscv64-unknown-elf-
    elif command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then
        CROSS_COMPILE=riscv32-unknown-elf-
    else
        echo 'Missing bare-metal RISC-V GCC. Install gcc-riscv64-unknown-elf and binutils-riscv64-unknown-elf, or set CROSS_COMPILE.' >&2
        exit 1
    fi
fi
for tool in gcc objcopy objdump size; do
    command -v "${CROSS_COMPILE}${tool}" >/dev/null || { echo "Missing ${CROSS_COMPILE}${tool}" >&2; exit 1; }
done
command -v python3 >/dev/null
mkdir -p build
"${CROSS_COMPILE}gcc" -march=rv32i -mabi=ilp32 -O2 \
    -ffreestanding -fno-builtin -fno-pic -fno-pie -fno-stack-protector \
    -fno-unwind-tables -fno-asynchronous-unwind-tables -msmall-data-limit=0 \
    -Wall -Wextra -nostdlib -nostartfiles -static \
    -Wl,--no-relax,--build-id=none,-Map=build/firmware.map \
    -T linker.ld start.S main.c -o build/firmware.elf
"${CROSS_COMPILE}objcopy" -O binary build/firmware.elf build/firmware.bin
"${CROSS_COMPILE}objdump" -d -M no-aliases build/firmware.elf > build/firmware.dis
"${CROSS_COMPILE}size" build/firmware.elf
args=(--firmware build/firmware.bin --weights weights_original.coe --out build)
if [[ $# -gt 0 ]]; then args+=(--image "$1"); fi
python3 pack_cpu_coe.py "${args[@]}"
echo 'DONE: build/bram_cpu.coe; instruction source = GCC-built firmware.bin'
