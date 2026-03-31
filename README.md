# CNN2D: FPGA-based CNN Accelerator with Motion Detection

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Vivado 2018.3](https://img.shields.io/badge/Vivado-2018.3-orange)
![FPGA: Xilinx Virtex-7](https://img.shields.io/badge/FPGA-Xilinx%20Virtex--7-green)
![Language: Verilog/SystemVerilog](https://img.shields.io/badge/Language-Verilog%2FSystemVerilog-purple)

## 概述

CNN2D 是一个基于 FPGA 的卷积神经网络硬件加速器，专门为实时图像处理和分类任务设计。该项目实现了一个完整的 7 层 CNN 架构，并集成了行为差异检测器（BDD）用于运动检测触发。

### 主要特性
- **7 层 CNN 架构**：包含 2D/1D 卷积、批归一化（BN）、ReLU 激活、池化层和全连接层
- **运动检测触发**：内置 BDD（行为差异检测器）模块，仅当检测到显著运动时启动 CNN 处理
- **硬件优化设计**：针对 FPGA 部署优化，支持 4 通道并行处理
- **完整的验证套件**：SystemVerilog 测试平台和 Python 数据验证脚本
- **量化精度**：8 位输入像素、4 位权重（int4 量化），各种内部精度优化

## 架构设计

### 系统框图
```
┌─────────────────────────────────────────────────────────────┐
│                        CNN_top (Top-Level)                  │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐ │
│  │   BDD       │    │   CNN2D     │    │   输出接口      │ │
│  │ (运动检测)  │───▶│ (8层CNN)    │───▶│ (dout/dout_valid)│ │
│  └─────────────┘    └─────────────┘    └─────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### CNN 层流水线
```
输入 → [BDD运动检测] → 触发信号
     ↓
LAYER0: 2D卷积(3×3,4通道)  → BN+ReLU → MaxPool(2×2)
LAYER1: 2D卷积(3×3,4通道)  → BN+ReLU → MaxPool(2×2)  
LAYER2: 2D卷积(3×3,16通道) → BN+ReLU → AvgPool(2×2)
LAYER3: 2D卷积(3×3,32通道) → BN+ReLU → AvgPool(2×2)
LAYER4：1D卷积(3×1,32通道) → BN+ReLU → AvgPool(1×2)
LAYER5：1D卷积(3×1,32通道) → BN+ReLU → AvgPool(1×2)
LAYER6,LAYER7: 全连接层(FC)(32x32) → 最终分类输出 
```

### 关键模块
- **CNN_top.v**：顶层模块，集成 BDD 运动检测器和 CNN2D
- **CNN2D.v**：主 CNN 模块，包含 8 层状态机和顶层控制
- **bdd.v**：行为差异检测器，检测输入流中的运动变化
- **conv_layer.v**：4 通道 2D 卷积层，3×3 内核
- **PE.v**：处理单元，执行 3×3 卷积运算
- **scale_relu_layer.v**：批归一化 + 缩放 + ReLU 激活层
- **maxpool_layer.v**：2×2 最大池化层，步长 2
- **avg_pool.v**：平均池化层
- **FC.v**：全连接层
- **CTRL.v**：主控制器，9 状态 FSM
- **DATA_FLOW.v**：数据路由交叉开关

### 内存架构
- **8 组 SRAM**：乒乓缓冲区设计，支持并行数据流
- **Block RAM IP 核**：权重、偏置、缩放参数的只读存储
- **COE 初始化文件**：预训练的模型参数

## 技术规格

### 数据精度
| 参数 | 位宽 | 描述 |
|------|------|------|
| `DIN_WIDTH` | 8 位 | 输入像素宽度 |
| `WEIGHT_WIDTH` | 4 位 | 权重位宽（int4 量化） |
| `DOUT_WIDTH` | 8 位 | 最终输出宽度 |
| `NUM` | 9 | 内核元素数（3×3=9） |
| `BIAS_WIDTH` | 12 位 | 偏置加法器位宽 |
| `SCALE_WIDTH` | 3 位 | 缩放移位位数 |

### 图像处理规格
- **输入图像尺寸**：50×62 像素（3100 像素）
- **处理通道**：4 通道并行处理
- **内核尺寸**：3×3（2D卷积），3×1（1D卷积）
- **池化方式**：2×2 最大池化/平均池化，步长 2

### 状态机（9 状态独热编码）
1. `IDLE` (9'b000000001) - 等待启动
2. `LAYER0` (9'b000000010) - 第一层 2D 卷积
3. `LAYER1` (9'b000000100) - 第二层 2D 卷积
4. `LAYER2` (9'b000001000) - 第三层 2D 卷积
5. `LAYER3` (9'b000010000) - 第四层 2D 卷积
6. `LAYER4` (9'b000100000) - 第五层 1D 卷积
7. `LAYER5` (9'b001000000) - 第六层 1D 卷积
8. `LAYER6` (9'b010000000) - 第七层全连接
9. `LAYER7` (9'b100000000) - 第八层全连接/输出

## 开始使用

### 先决条件
- **Vivado 2018.3** 或兼容版本
- **Python 3.x** 及以下库：
  - `numpy`（数据处理和验证）
- **FPGA 开发板**：兼容 Xilinx Virtex-7 xc7vx485tffg1157-1
- **内存**：建议 8GB RAM 以上

### 安装步骤
1. **克隆仓库**
   ```bash
   git clone <repository-url>
   cd CNN2D
   ```

2. **设置 Python 环境**
   ```bash
   # 创建虚拟环境（可选）
   python -m venv .venv
   
   # 激活虚拟环境
   # Windows:
   .venv\Scripts\activate
   # Linux/Mac:
   source .venv/bin/activate
   
   # 安装依赖
   pip install numpy
   ```

3. **准备测试数据**
   ```bash
   # 运行 Python 脚本生成 COE 文件
   cd PythonDV
   python weight_coe.py
   python bias_scale_coe.py
   ```

## 构建和仿真

### Vivado 项目设置
1. **打开项目**
   - 启动 Vivado 2018.3
   - 选择 "Open Project"
   - 导航到 `CNN2D/CNN2D.xpr`

2. **设置仿真**
   - 在 "Sources" 面板中，右键点击 `tb_CNN2D.sv`
   - 选择 "Set as Top"
   - 在 "Flow Navigator" 中点击 "Run Simulation" → "Run Behavioral Simulation"

3. **运行仿真**
   ```tcl
   # 在 Vivado Tcl 控制台中
   launch_simulation
   run 100us
   ```

## 使用示例

### 输入数据格式
- **图像尺寸**：50 像素宽 × 62 像素高
- **数据文件**：`data/layer_0_input.txt`
- **格式**：每行一个十进制像素值（0-255）
- **通道顺序**：4 通道交错存储

### 运行测试
1. **准备测试数据**
   ```bash
   # 确保所有 COE 文件已生成
   ls *.coe
   # 应该看到：weights_2D.coe, weights_1D.coe, weights_FC.coe, bias_all.coe, scale_all.coe, BN_all.coe
   ```

2. **启动仿真**
   - 在 Vivado 中运行 `tb_CNN2D.sv` 测试平台
   - 仿真将自动加载 `data/` 目录中的测试数据

3. **验证输出**
   - 输出存储在 `DUT/` 目录中
   - 使用 Python 脚本比较输出与预期结果

### 运动检测触发
BDD 模块持续监控输入数据流：
- **触发条件**：检测到显著的帧间差异
- **CNN 启动**：触发信号拉高时启动 CNN 处理
- **节能特性**：无运动时 CNN 保持空闲状态

## 项目结构

```
CNN2D/
├── CNN2D.xpr                    # Vivado 2018.3 项目文件
├── LICENSE                      # MIT 许可证
├── README.md                    # 本文档
├── CLAUDE.md                    # Claude AI 助手配置文件
├── .gitignore                   # Git 忽略规则
│
├── CNN2D.srcs/                  # 设计源文件
│   ├── sources_1/
│   │   ├── new/                 # Verilog 源文件
│   │   │   ├── CNN_top.v        # 顶层模块（含 BDD）
│   │   │   ├── CNN2D.v          # 主 CNN 模块
│   │   │   ├── bdd.v            # 行为差异检测器
│   │   │   ├── conv_layer.v     # 4 通道卷积层
│   │   │   ├── PE.v             # 处理单元
│   │   │   ├── scale_relu_layer.v # BN+缩放+ReLU
│   │   │   ├── maxpool_layer.v  # 最大池化层
│   │   │   ├── avg_pool.v       # 平均池化层
│   │   │   ├── FC.v             # 全连接层
│   │   │   ├── CTRL.v           # 主控制器
│   │   │   ├── DATA_FLOW.v      # 数据流控制
│   │   │   └── ...              # 其他支持模块
│   │   └── ip/                  # IP 核
│   │       ├── Weight_Rom       # 权重 ROM
│   │       ├── BN_Rom           # BN 参数 ROM
│   │       ├── CONV1D_RAM       # 1D 卷积 RAM
│   │       └── PINGPONG_RAM     # 8 组 SRAM
│   ├── sim_1/                   # 仿真文件
│   │   └── new/
│   │       ├── tb_CNN2D.sv      # 主测试平台
│   │       └── tb_bdd.v         # BDD 测试平台
│   └── constrs_1/               # 约束文件（空）
│
├── data/                        # 测试数据
│   ├── layer_0_input.txt        # 第 0 层输入数据
│   ├── layer_0_weight.txt       # 第 0 层权重
│   ├── layer_0_bias.txt         # 第 0 层偏置
│   ├── layer_0_output.txt       # 第 0 层期望输出
│   ├── layer_0_scale_parameters.txt # 缩放参数
│   └── ...                      # 其他层数据
│
├── PythonDV/                    # Python 数据验证脚本
│   ├── weight_coe.py            # 权重转 COE 格式
│   ├── bias_scale_coe.py        # 偏置/缩放转 COE 格式
│   ├── data_compare.py          # 数据比较工具
│   ├── data_loader.py           # 数据加载器
│   └── test.py                  # 综合测试脚本
│
├── DUT/                         # 设备测试输出文件
├── Inference_251021/            # 推理测试数据（旧版）
├── .venv/                       # Python 虚拟环境
│
└── *.coe                        # 内存初始化文件
    ├── weights_2D.coe           # 2D 卷积权重
    ├── weights_1D.coe           # 1D 卷积权重
    ├── weights_FC.coe           # 全连接层权重
    ├── bias_all.coe             # 所有偏置
    ├── scale_all.coe            # 所有缩放参数
    └── BN_all.coe               # 所有 BN 参数
```

## 许可证

本项目采用 **MIT 许可证** - 查看 [LICENSE](LICENSE) 文件了解详情。

```
MIT License

Copyright (c) 2026 Ljj05170930

Permission is hereby granted...
```

## 参考文献

1. **CNN 硬件加速器设计**
   - FPGA-based Convolutional Neural Network Accelerators: A Survey
   - Efficient Hardware Architectures for Deep Convolutional Neural Networks

2. **量化神经网络**
   - Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference
   - A Survey of Model Compression and Acceleration for Deep Neural Networks

3. **运动检测算法**
   - Background Subtraction for Moving Object Detection in RGB-D Data
   - Real-time Motion Detection and Tracking

4. **相关工具**
   - Xilinx Vivado Design Suite User Guide
   - SystemVerilog IEEE 1800-2017 Standard

---
*最后更新: 2026-03-31*  
*文档版本: 1.0*