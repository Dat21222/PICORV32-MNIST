#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if [[ -z "${CROSS_COMPILE:-}" ]]; then
    if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
        CROSS_COMPILE=riscv64-unknown-elf-
    elif command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then
        CROSS_COMPILE=riscv32-unknown-elf-
    else
        echo 'Missing bare-metal RISC-V GCC.' >&2
        exit 1
    fi
fi
mkdir -p build_multi3
"${CROSS_COMPILE}gcc" -march=rv32i -mabi=ilp32 -O2 \
    -ffreestanding -fno-builtin -fno-pic -fno-pie -fno-stack-protector \
    -fno-unwind-tables -fno-asynchronous-unwind-tables -msmall-data-limit=0 \
    -Wall -Wextra -nostdlib -nostartfiles -static \
    -Wl,--no-relax,--build-id=none,-Map=build_multi3/firmware_multi3.map \
    -T linker.ld start.S main_multi3.c -o build_multi3/firmware_multi3.elf
"${CROSS_COMPILE}objcopy" -O binary build_multi3/firmware_multi3.elf build_multi3/firmware_multi3.bin
"${CROSS_COMPILE}objdump" -d -M no-aliases build_multi3/firmware_multi3.elf > build_multi3/firmware_multi3.dis
"${CROSS_COMPILE}size" build_multi3/firmware_multi3.elf
python3 pack_multi3_coe.py --firmware build_multi3/firmware_multi3.bin --weights weights_original.coe --out build_multi3 \
    --image ../image/img_106.jpg ../image/img_107.jpg ../image/img_114.jpg
echo 'DONE: build_multi3/bram_cpu_multi3.coe'
