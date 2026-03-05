import numpy as np
from data_loader import read_ints

def compare(data1, data2, verbose=True):
    def to_array(data):
        if isinstance(data, str):
            arr = read_ints(data)
            if verbose:
                print(f"从文件加载了 {len(arr)} 个整数：{data}")
            return arr
        elif isinstance(data, np.ndarray):
            return data.flatten()
        elif isinstance(data, (list, tuple)):
            return np.array(data, dtype=int).flatten()
        else:
            raise TypeError("输入必须是文件路径、列表或NumPy数组")

    arr1 = to_array(data1)
    arr2 = to_array(data2)

    if verbose:
        print(f"data1 包含 {len(arr1)} 个整数")
        print(f"data2 包含 {len(arr2)} 个整数")

    same_length = (len(arr1) == len(arr2))
    if not same_length and verbose:
        print(f"长度不匹配:data1 有 {len(arr1)} 个元素,data2 有 {len(arr2)} 个元素")

    min_len = min(len(arr1), len(arr2))
    differences = []
    for i in range(min_len):
        if arr1[i] != arr2[i]:
            differences.append((i, arr1[i], arr2[i]))

    if differences and verbose:
        print(f"在前 {min_len} 个位置中发现 {len(differences)} 处不同")
    elif not differences and same_length and verbose:
        print("两个数据集完全相同。")
    elif not differences and not same_length and verbose:
        print(f"前 {min_len} 个元素完全相同，但长度不同。")

    return differences