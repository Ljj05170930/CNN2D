import os
import math
import numpy as np
from data_loader import read_ints, save_init

def process_scale_file(input_path, output_path):
    shift_values = []
    with open(input_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                val = float(line)
                n = round(-math.log2(val))
                shift_values.append(n)
            except Exception:
                continue
    with open(output_path, 'w', encoding='utf-8') as f:
        for n in shift_values:
            f.write(str(n) + '\n')

input_dir = "Inference_251021" 
output_dir = "data"              

if not os.path.exists(output_dir):
    os.makedirs(output_dir)
    print(f"创建输出文件夹: {output_dir}")

for filename in os.listdir(input_dir):
    if filename.endswith(".txt"):
        if "scale_parameter" in filename:
            print(f"跳过scale文件: {filename}")
            continue

        input_path = os.path.join(input_dir, filename)
        output_path = os.path.join(output_dir, filename)

        print(f"处理文件: {input_path} -> {output_path}")

        data = read_ints(input_path)
        if len(data) == 0:
            print(f"  警告: {filename} 中没有读取到有效整数，已跳过")
            continue
        save_init(data, output_path)

for filename in os.listdir(input_dir):
    if filename.endswith(".txt") and "scale_parameter" in filename:
        input_path = os.path.join(input_dir, filename)
        output_path = os.path.join(output_dir, filename)
        print(f"处理scale文件: {input_path} -> {output_path}")
        process_scale_file(input_path, output_path)

print("所有文件处理完毕!")
