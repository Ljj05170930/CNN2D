"""
txt_to_coe.py
=============
Convert bias / scale txt files to Vivado COE format.

Generates two independent COE files:
    bias_all.coe   -- 12-bit per address (one int12 bias  per filter)
    scale_all.coe  --  3-bit per address (one uint3 scale per filter)

Address mapping (same for both files):
    addr 0       = layer0, filter0
    addr 1       = layer0, filter1
    ...
    addr N-1     = layer7, last filter

Txt file format (one decimal value per line):
    layer0_bias.txt   -- int12  [-2048, 2047],  lines = num_filters in layer0
    layer0_scale.txt  -- uint3  [0, 7],         lines = num_filters in layer0
    (same structure for layer1 ~ layer7)

Usage:
    Place this script in the same folder as your txt files, then run:
        python txt_to_coe.py
"""

import os

# =============================================================================
# Configuration — edit file names / filter counts to match your project
# =============================================================================

# One txt per layer, 8 layers total
BIAS_TXT_FILES = [
    "data/layer_0_bias.txt",    # 8  filters
    "data/layer_1_bias.txt",    # 8  filters
    "data/layer_2_bias.txt",    # 16 filters
    "data/layer_3_bias.txt",    # 16 filters
    "data/layer_4_bias.txt",    # 32 filters
    "data/layer_5_bias.txt",    # 32 filters
    "data/layer_6_bias.txt",    # 32 filters
    "data/layer_7_bias.txt",    # 1 filters

]

SCALE_TXT_FILES = [
    "data/layer_0_scale_parameters.txt",   # 8  filters
    "data/layer_1_scale_parameters.txt",   # 8  filters
    "data/layer_2_scale_parameters.txt",   # 16 filters
    "data/layer_3_scale_parameters.txt",   # 16 filters
    "data/layer_4_scale_parameters.txt",   # 32 filters
    "data/layer_5_scale_parameters.txt",   # 32 filters
    "data/layer_6_scale_parameters.txt",   # 32 filters
    "data/layer_7_scale_parameters.txt",   # 1 filters
]


# Expected filter count per layer — used to validate txt line counts
FILTER_COUNTS = [4, 8, 16, 32,32,32,32,1]
OUTPUT_BIAS_COE  = "bias_all.coe"
OUTPUT_SCALE_COE = "scale_all.coe"

BIAS_BITS  = 12   # signed int12
SCALE_BITS = 3    # unsigned uint3

# =============================================================================
# Helpers
# =============================================================================

def read_txt(path: str) -> list:
    """Read a txt file and return a list of integers (one per non-empty line)."""
    if not os.path.exists(path):
        raise FileNotFoundError(
            f"File not found: {path}\n"
            f"Make sure it is in the same directory as this script."
        )
    with open(path, "r") as f:
        lines = [l.strip() for l in f if l.strip()]
    return [int(x) for x in lines]


def write_coe(path: str, entries: list, data_bits: int):
    """Write a list of integer values to a COE file in hex format."""
    hex_chars = (data_bits + 3) // 4      # number of hex characters needed
    fmt       = f"{{:0{hex_chars}X}}"
    total     = len(entries)
    with open(path, "w") as f:
        f.write("memory_initialization_radix  = 16;\n")
        f.write("memory_initialization_vector =\n")
        for i, val in enumerate(entries):
            sep = ";" if i == total - 1 else ","
            f.write(fmt.format(val) + sep + "\n")
    print(f"  Written: {path}  ({total} entries x {data_bits} bit)")


def int12_to_uint(val: int) -> int:
    """Map signed int12 [-2048, 2047] to unsigned 12-bit via two's complement."""
    assert -2048 <= val <= 2047, \
        f"Bias value {val} out of int12 range [-2048, 2047]"
    return val & 0xFFF


def uint3_check(val: int) -> int:
    """Validate unsigned 3-bit scale value [0, 7]."""
    assert 0 <= val <= 7, \
        f"Scale value {val} out of uint3 range [0, 7]"
    return val & 0x7


# =============================================================================
# Conversion functions
# =============================================================================

def convert_bias() -> list:
    entries = []
    for txt_file, expected in zip(BIAS_TXT_FILES, FILTER_COUNTS):
        values = read_txt(txt_file)
        if len(values) != expected:
            raise ValueError(
                f"{txt_file}: expected {expected} lines, got {len(values)}."
            )
        print(f"  [bias]  {txt_file}: {len(values)} entries")
        entries.extend([int12_to_uint(v) for v in values])
    return entries


def convert_scale() -> list:
    entries = []
    for txt_file, expected in zip(SCALE_TXT_FILES, FILTER_COUNTS):
        values = read_txt(txt_file)
        if len(values) != expected:
            raise ValueError(
                f"{txt_file}: expected {expected} lines, got {len(values)}."
            )
        print(f"  [scale] {txt_file}: {len(values)} entries")
        entries.extend([uint3_check(v) for v in values])
    return entries


# =============================================================================
# Main
# =============================================================================

def main():
    print("--- Converting Bias ---")
    bias_entries  = convert_bias()

    print("\n--- Converting Scale ---")
    scale_entries = convert_scale()

    # Sanity check: both must have the same total depth
    assert len(bias_entries) == len(scale_entries), (
        f"Depth mismatch: bias={len(bias_entries)}, scale={len(scale_entries)}"
    )
    total = len(bias_entries)

    print("\n--- Writing COE files ---")
    write_coe(OUTPUT_BIAS_COE,  bias_entries,  data_bits=BIAS_BITS)
    write_coe(OUTPUT_SCALE_COE, scale_entries, data_bits=SCALE_BITS)

    print(f"\n{'='*50}")
    print(f"Vivado BRAM settings:")
    print(f"  {OUTPUT_BIAS_COE}")
    print(f"    Port A Width = {BIAS_BITS},   Depth = {total}")
    print(f"  {OUTPUT_SCALE_COE}")
    print(f"    Port A Width = {SCALE_BITS},    Depth = {total}")
    print(f"\nBoth BRAMs share the same address index:")
    print(f"  addr 0 ~ {sum(FILTER_COUNTS[:1])-1}   : layer0 ({FILTER_COUNTS[0]} filters)")
    for i in range(1, len(FILTER_COUNTS)):
        base = sum(FILTER_COUNTS[:i])
        print(f"  addr {base} ~ {base + FILTER_COUNTS[i] - 1:<3}: layer{i} ({FILTER_COUNTS[i]} filters)")
    print(f"  Total depth = {total}")


if __name__ == "__main__":
    print("Converting txt files to COE...\n")
    main()