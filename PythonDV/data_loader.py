import numpy as np

def read_ints(filepath):
    rows = []
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:          
                continue
            try:
                row = int(line.split('.')[0])
                rows.append(row)
            except Exception:
                continue
    if rows:
        return np.array(rows, dtype=int)
    else:
        return np.array([])

def save_init(data, filename):

    if isinstance(data, np.ndarray):
        flat = data.flatten()
        np.savetxt(filename, flat.reshape(-1, 1), fmt='%d')
    else:
        flat = []
        def flatten(obj):
            if isinstance(obj, (list, tuple)):
                for item in obj:
                    flatten(item)
            else:
                flat.append(obj)
        flatten(data)                
        with open(filename, 'w') as f:
            for val in flat:
                f.write(str(val) + '\n')

