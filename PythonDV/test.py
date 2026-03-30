import numpy as np
from data_compare import compare

# array1 = np.loadtxt('DUT/layer_0_mid.txt', dtype=int)
# array2 = np.loadtxt('data/layer_0_output_unscaled_unmaxpool.txt', dtype=int)

# array1 = np.loadtxt('DUT/layer_3_mid.txt', dtype=int)
# array3 = np.loadtxt('data/layer_3_output_unscaled_unmaxpool.txt', dtype=int)
# n = len(array1)
# array3 = array3[0:n]
# diff = compare(array1, array3)
# print(diff)

# array1 = np.loadtxt('DUT/layer_3_out.txt', dtype=int)
# array3 = np.loadtxt('data/layer_3_output.txt', dtype=int)
# n = len(array1)
# array3 = array3[0:n]
# diff = compare(array1, array3)
# print(diff)

array1 = [0,0,0,0,0,0,0,0,0,0,0,1,5,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,0,0,0,0]
array2 = np.loadtxt("data/layer_7_weight.txt", dtype=int).reshape(1,-1)

print(array1)
print(array2)

unscale_result = np.dot(array1, array2.T) - 28
print(unscale_result)
result = unscale_result // 8
print(result)

# array4 = np.loadtxt('data/layer_2_output.txt', dtype=int).reshape(256,7,6)
# with open("DUT/layer_2_output_reshape.txt", "w") as f:
#     for i, layer in enumerate(array4):  # layer shape: (7, 6)
#         f.write(f"# layer {i}\n")
#         np.savetxt(f, layer, fmt="%-4d")
#         f.write("\n")
