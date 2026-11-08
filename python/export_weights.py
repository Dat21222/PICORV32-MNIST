import numpy as np
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

# Fixed-point formats must match mlp_acc_scale_folding_timing_Q22.v
W1_SCALE = 1 << 22   # W1' : signed INT16 Q22
B1_SCALE = 1 << 22   # b1' : signed INT32 Q22
W2_SCALE = 1 << 14   # W2  : signed INT16 Q14
B2_SCALE = 1 << 29   # b2  : signed INT32 Q29

INPUTS = 784
HIDDEN = 64
OUTPUTS = 10

EXPECTED_WORDS = {
    "W1_packed.hex": (INPUTS // 2) * HIDDEN,  # 25,088
    "b1.hex": HIDDEN,                        # 64
    "W2_packed.hex": (HIDDEN // 2) * OUTPUTS,# 320
    "b2.hex": OUTPUTS,                       # 10
}


def to_hex(value, bits):
    """Convert a signed integer to fixed-width two's-complement HEX."""
    value = int(value)
    min_val = -(1 << (bits - 1))
    max_val = (1 << (bits - 1)) - 1

    if not min_val <= value <= max_val:
        raise ValueError(
            f"Value {value} is outside signed {bits}-bit range "
            f"[{min_val}, {max_val}]"
        )

    return f"{value & ((1 << bits) - 1):0{bits // 4}X}"


def quantize(values, scale, bits, name):
    """Round float values to fixed-point integers and check range before cast."""
    values = np.asarray(values, dtype=np.float64)

    if not np.all(np.isfinite(values)):
        raise ValueError(f"{name} contains NaN or Inf")

    # Keep the rounded values in float64 until the range check is complete.
    q = np.rint(values * scale)

    min_val = -(1 << (bits - 1))
    max_val = (1 << (bits - 1)) - 1

    q_min = float(np.min(q))
    q_max = float(np.max(q))

    print(f"\n{name}:")
    print(f"  real min/max = {np.min(values):.12g} / {np.max(values):.12g}")
    print(f"  quantized min/max = {q_min:.0f} / {q_max:.0f}")
    print(f"  signed {bits}-bit allowed = [{min_val}, {max_val}]")

    if q_min < min_val or q_max > max_val:
        raise ValueError(
            f"{name} overflows signed {bits}-bit. "
            f"Do not export or cast to int16/int32. "
            f"Choose a different fixed-point format or retrain/rescale."
        )

    return q.astype(np.int64)


def export_hex(filename, array, bits):
    """Export one signed integer per line in two's-complement HEX."""
    path = BASE_DIR / filename
    with path.open("w", encoding="utf-8") as f:
        for value in np.asarray(array).reshape(-1):
            f.write(to_hex(value, bits) + "\n")


def pack_int16_pair(low, high):
    """
    Pack two signed INT16 values into one 32-bit word:
      [15:0]  = low
      [31:16] = high
    """
    low_hex = int(to_hex(low, 16), 16)
    high_hex = int(to_hex(high, 16), 16)
    return (high_hex << 16) | low_hex


def export_packed_weights(filename, weights):
    """
    weights has shape (N, M).
    For each even i and each column j, write:
      low  = weights[i,   j]
      high = weights[i+1, j]

    Word order matches the RTL address calculation:
      BASE + (i/2)*M + j
    """
    weights = np.asarray(weights)

    if weights.ndim != 2:
        raise ValueError(f"{filename}: expected a 2-D matrix")

    n, m = weights.shape
    if n % 2 != 0:
        raise ValueError(
            f"{filename}: number of rows must be even, got {n}"
        )

    path = BASE_DIR / filename
    with path.open("w", encoding="utf-8") as f:
        for i in range(0, n, 2):
            for j in range(m):
                word = pack_int16_pair(
                    weights[i, j],
                    weights[i + 1, j]
                )
                f.write(f"{word:08X}\n")


def count_words(filename):
    with (BASE_DIR / filename).open("r", encoding="utf-8") as f:
        return sum(1 for _ in f)


# ---------------------------------------------------------------------
# Load trained weights.
# IMPORTANT:
# W1.npy must already contain the folded weight W1_original / 255.
# b1.npy remains the original b1 because the training preprocessing is x/255.
# W2.npy and b2.npy remain the original second-layer parameters.
# ---------------------------------------------------------------------
W1 = np.load(BASE_DIR / "W1.npy").astype(np.float64)
b1 = np.load(BASE_DIR / "b1.npy").astype(np.float64)
W2 = np.load(BASE_DIR / "W2.npy").astype(np.float64)
b2 = np.load(BASE_DIR / "b2.npy").astype(np.float64)

# Check tensor dimensions.
if W1.shape != (INPUTS, HIDDEN):
    raise ValueError(f"W1 has wrong shape: {W1.shape}, expected {(INPUTS, HIDDEN)}")
if b1.shape != (HIDDEN,):
    raise ValueError(f"b1 has wrong shape: {b1.shape}, expected {(HIDDEN,)}")
if W2.shape != (HIDDEN, OUTPUTS):
    raise ValueError(f"W2 has wrong shape: {W2.shape}, expected {(HIDDEN, OUTPUTS)}")
if b2.shape != (OUTPUTS,):
    raise ValueError(f"b2 has wrong shape: {b2.shape}, expected {(OUTPUTS,)}")

# Quantize to the exact formats expected by the updated RTL.
W1_q = quantize(W1, W1_SCALE, 16, "W1_folded Q22 / INT16")
b1_q = quantize(b1, B1_SCALE, 32, "b1_folded Q22 / INT32")
W2_q = quantize(W2, W2_SCALE, 16, "W2 Q14 / INT16")
b2_q = quantize(b2, B2_SCALE, 32, "b2 Q29 / INT32")

# Export packed matrices and one-word-per-neuron biases.
export_packed_weights("W1_packed.hex", W1_q)
export_hex("b1.hex", b1_q, 32)

export_packed_weights("W2_packed.hex", W2_q)
export_hex("b2.hex", b2_q, 32)

# Verify output word counts against the RTL memory map.
print("\n========== EXPORTED HEX WORD COUNTS ==========")
total_words = 0
for filename, expected in EXPECTED_WORDS.items():
    actual = count_words(filename)
    print(f"{filename}: {actual:,} words (expected {expected:,})")
    if actual != expected:
        raise RuntimeError(
            f"{filename}: exported {actual} words, expected {expected}"
        )
    total_words += actual

print(f"\nTotal words: {total_words:,} (expected 25,482)")

print("\n========== BRAM PACKING ==========")
print("W1_packed: [31:16] = W1[i+1,h], [15:0] = W1[i,h]")
print("W2_packed: [31:16] = W2[h+1,o], [15:0] = W2[h,o]")
print("Bias files: signed 32-bit, one bias per 32-bit word")

print("\n========== RTL MEMORY MAP ==========")
print("W1: 0 .. 25087")
print("b1: 25088 .. 25151")
print("W2: 25152 .. 25471")
print("b2: 25472 .. 25481")
print("Highest used address: 25481 (fits in 15-bit BRAM address)")

print("\nExport completed successfully.")