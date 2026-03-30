"""
txt_to_weight_coe_v2.py
=======================
Convert pairs of weight txt files into Vivado COE format.

Two COE files are generated:
    weight_96bit.coe   -- 96-bit per address  (24 x int4 weights)
    weight_128bit.coe  -- 128-bit per address (32 x int4 weights)

Merge rule (same for both):
    All values from txt_A, then all values from txt_B, concatenated in order.
    The merged list is then split into groups of WEIGHTS_PER_ADDR.

Packing order (little-endian within each address):
    bits [3:0]   = merged[0]   (lowest bits)
    bits [7:4]   = merged[1]
    ...
    bits [N-1:N-4] = merged[-1] (highest bits)

Txt file format:
    One decimal int4 value [-8, 7] per non-empty line.
    Total lines of txt_A + txt_B must be divisible by WEIGHTS_PER_ADDR.

Usage:
    Edit the file path configuration below, then run:
        python txt_to_weight_coe_v2.py
"""

import os
import math

# =============================================================================
# Configuration — edit file paths to match your project
# =============================================================================

# --- 96-bit group (24 weights per address) ---
COE_96BIT = {
    "txt_a"          : "data/layer_4_weight.txt",
    "txt_b"          : "data/layer_5_weight.txt",
    "output"         : "weights_1D.coe",
    "weights_per_addr": 24,
    "addr_bits"      : 96,        # = 24 * 4
}

# --- 128-bit group (32 weights per address) ---
COE_128BIT = {
    "txt_a"          : "data/layer_6_weight.txt",
    "txt_b"          : "data/layer_7_weight.txt",
    "output"         : "weights_FC.coe",
    "weights_per_addr": 32,
    "addr_bits"      : 128,       # = 32 * 4
}

WEIGHT_BITS = 4   # signed int4 [-8, 7]

# =============================================================================
# Helpers
# =============================================================================

def read_txt(path: str) -> list:
    """Read a txt file and return a list of integers (one per non-empty line)."""
    if not os.path.exists(path):
        raise FileNotFoundError(
            f"File not found: {path}\n"
            f"Make sure the path is correct."
        )
    with open(path, "r") as f:
        lines = [l.strip() for l in f if l.strip()]
    return [int(x) for x in lines]


def int4_to_uint(val: int) -> int:
    """Map signed int4 [-8, 7] to unsigned 4-bit via two's complement."""
    assert -8 <= val <= 7, \
        f"Weight value {val} is out of int4 range [-8, 7]"
    return val & 0xF


def pack_group(group: list, weights_per_addr: int) -> int:
    """
    Pack a group of int4 values into one unsigned integer (little-endian).
    group[0]  -> bits [3:0]   (lowest)
    group[-1] -> bits [N-1:N-4] (highest)
    """
    assert len(group) == weights_per_addr, \
        f"Expected {weights_per_addr} weights per group, got {len(group)}"
    result = 0
    for i, val in enumerate(group):
        result |= int4_to_uint(val) << (i * WEIGHT_BITS)
    return result


def write_coe(path: str, entries: list, addr_bits: int):
    """Write a list of packed integers to a COE file in hex format."""
    hex_chars = math.ceil(addr_bits / 4)
    fmt       = f"{{:0{hex_chars}X}}"
    total     = len(entries)
    with open(path, "w") as f:
        f.write("memory_initialization_radix  = 16;\n")
        f.write("memory_initialization_vector =\n")
        for i, val in enumerate(entries):
            sep = ";" if i == total - 1 else ","
            f.write(fmt.format(val) + sep + "\n")
    print(f"  Written : {path}")
    print(f"  Entries : {total}  |  Width : {addr_bits} bit  |  Hex chars/addr : {hex_chars}")


# =============================================================================
# Core conversion
# =============================================================================

def convert(cfg: dict):
    txt_a            = cfg["txt_a"]
    txt_b            = cfg["txt_b"]
    output           = cfg["output"]
    weights_per_addr = cfg["weights_per_addr"]
    addr_bits        = cfg["addr_bits"]

    values_a = read_txt(txt_a)
    values_b = read_txt(txt_b)
    merged   = values_a + values_b          # txt_A all first, then txt_B

    total = len(merged)
    if total % weights_per_addr != 0:
        raise ValueError(
            f"Combined line count {total} (= {len(values_a)} + {len(values_b)}) "
            f"is not divisible by {weights_per_addr}.\n"
            f"  {txt_a}: {len(values_a)} lines\n"
            f"  {txt_b}: {len(values_b)} lines"
        )

    num_addrs = total // weights_per_addr
    print(f"  {txt_a} : {len(values_a)} values")
    print(f"  {txt_b} : {len(values_b)} values")
    print(f"  Merged  : {total} values  →  {num_addrs} addresses ({addr_bits}-bit each)")

    entries = []
    for g in range(num_addrs):
        group = merged[g * weights_per_addr : (g + 1) * weights_per_addr]
        entries.append(pack_group(group, weights_per_addr))

    write_coe(output, entries, addr_bits)
    return num_addrs


# =============================================================================
# Main
# =============================================================================

def main():
    print("=" * 55)
    print("--- 96-bit COE (24 weights/addr) ---")
    depth_96 = convert(COE_96BIT)

    print()
    print("--- 128-bit COE (32 weights/addr) ---")
    depth_128 = convert(COE_128BIT)

    print()
    print("=" * 55)
    print("Vivado BRAM settings:")
    print(f"  {COE_96BIT['output']}")
    print(f"    Port A Width = {COE_96BIT['addr_bits']},   Depth = {depth_96}")
    print(f"  {COE_128BIT['output']}")
    print(f"    Port A Width = {COE_128BIT['addr_bits']},  Depth = {depth_128}")


if __name__ == "__main__":
    print("Converting weight txt files to COE...\n")
    main()