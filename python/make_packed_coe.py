from pathlib import Path
import re

BASE_DIR = Path(__file__).resolve().parent

# Memory map must match mlp_top / mlp_acc.
FILES = [
    ("W1_packed.hex", 25088),  # 0 .. 25087
    ("b1.hex",           64),  # 25088 .. 25151
    ("W2_packed.hex",   320),  # 25152 .. 25471
    ("b2.hex",            10), # 25472 .. 25481
]

BRAM_DEPTH = 32768
EXPECTED_TOTAL = 25482
OUTPUT_FILE = BASE_DIR / "bram_init.coe"
HEX_PATTERN = re.compile(r"^[0-9A-Fa-f]{8}$")


def read_hex_words(filename, expected_count):
    """Read and validate 32-bit HEX words, one word per line."""
    path = BASE_DIR / filename

    if not path.is_file():
        raise FileNotFoundError(f"Khong tim thay file: {path}")

    words = []
    with path.open("r", encoding="utf-8") as f:
        for line_number, raw_line in enumerate(f, start=1):
            word = raw_line.strip()
            if not word:
                continue

            if not HEX_PATTERN.fullmatch(word):
                raise ValueError(
                    f"{filename}, dong {line_number}: "
                    f"can dung 8 ky tu HEX 32-bit, nhan '{word}'"
                )

            words.append(word.upper())

    if len(words) != expected_count:
        raise ValueError(
            f"{filename}: can {expected_count} word, "
            f"nhung co {len(words)} word"
        )

    return words


def main():
    all_words = []
    current_address = 0

    print("========== KIEM TRA CAC FILE HEX ==========")

    for filename, expected_count in FILES:
        words = read_hex_words(filename, expected_count)

        start_address = current_address
        end_address = current_address + len(words) - 1

        all_words.extend(words)
        current_address += len(words)

        print(
            f"{filename}: {len(words):,} words | "
            f"address {start_address} .. {end_address}"
        )

    if len(all_words) != EXPECTED_TOTAL:
        raise ValueError(
            f"Tong word sai: {len(all_words)}, mong doi {EXPECTED_TOTAL}"
        )

    if len(all_words) > BRAM_DEPTH:
        raise ValueError(
            f"Du lieu can {len(all_words)} words, vuot BRAM depth {BRAM_DEPTH}"
        )

    highest_address = len(all_words) - 1

    # COE: radix 16, comma-separated 32-bit words, final semicolon.
    with OUTPUT_FILE.open("w", encoding="ascii", newline="\n") as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        f.write(",\n".join(all_words))
        f.write(";\n")

    print("\n========== TAO COE THANH CONG ==========")
    print(f"Output: {OUTPUT_FILE}")
    print(f"Total initialized words: {len(all_words):,}")
    print(f"Highest initialized address: {highest_address}")
    print(f"BRAM depth: {BRAM_DEPTH:,}")
    print(f"Unused BRAM words: {BRAM_DEPTH - len(all_words):,}")

    print("\nMemory map:")
    print("W1_packed : 0       .. 25087")
    print("b1        : 25088   .. 25151")
    print("W2_packed : 25152   .. 25471")
    print("b2        : 25472   .. 25481")

    print("\nPacking:")
    print("W1: [31:16] = W1[i+1,h], [15:0] = W1[i,h]")
    print("W2: [31:16] = W2[h+1,o], [15:0] = W2[h,o]")
    print("Bias: one signed 32-bit word per neuron")


if __name__ == "__main__":
    main()