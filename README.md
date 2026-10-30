# 艾德克斯（ITECH）电源自动上下电测试

读 `config.yaml` 里的参数，通过电源的 USB 虚拟串口发送 SCPI 命令，循环执行
「上电 → 保持 → 断电 → 间隔」，并把每轮的实测电压/电流写入 CSV。

```
┌────────────┐   USB 虚拟串口    ┌──────────────┐
│ 电脑        │ ◄───────────────► │ ITECH 电源    │
│ power_cycle │  SCPI ASCII       │ OUTP ON/OFF  │
│ _test.sh    │  VOLT / CURR      │ VOLT / CURR  │
└────────────┘                   └──────┬───────┘
                                        │
                                   被测设备 DUT
```

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `power_cycle_test.sh` | 主脚本。bash 入口负责环境/依赖/参数，内嵌 Python 负责 SCPI 通信、计时、测量、日志与安全断电 |
| `config.yaml` | 全部可调参数：串口、电压、电流、上电时间、间隔、循环次数等 |
| `requirements.txt` | Python 依赖（PyYAML、pyserial），首次运行自动安装 |
| `logs/` | 运行后自动生成：运行日志 + 测量 CSV |

## 环境准备

### Windows

1. 安装 Python 3.8 及以上（[python.org](https://www.python.org/downloads/)，安装时勾选 *Add python.exe to PATH*）。
2. 插上电源 USB 线，打开**设备管理器 → 端口 (COM 和 LPT)**，确认出现
   `USB Serial Port (COMx)`。
   - 没有 COM 口：先装 ITECH 官网的 USB 驱动；或电源用的是 FTDI 芯片，装
     [FTDI VCP 驱动](https://ftdichip.com/drivers/vcp-drivers/)（注意要 VCP 版，不是 D2XX 版）。
3. 用 **Git Bash**（或 WSL）运行脚本，不要在 cmd/PowerShell 里直接执行 `.sh`。
   脚本会自动用 `cygpath` 把路径转成 Windows 格式，COM 口号直接写 `COM5` 即可。

### Linux

```bash
sudo apt install python3 python3-venv   # Debian/Ubuntu
ls /dev/ttyUSB*                         # 插上电源后应出现，常见 ttyUSB0
sudo usermod -aG dialout "$USER"        # 加入串口组，重新登录后生效
```

## 快速开始

```bash
chmod +x power_cycle_test.sh

./power_cycle_test.sh -n      # 1. 干跑：只校验 config.yaml 并打印执行计划
./power_cycle_test.sh         # 2. 正式执行
```

首次运行会在脚本目录创建 `.venv` 并安装 PyYAML / pyserial（需要联网）。
若系统没有 venv 模块或创建失败，会自动回退安装到 `.deps/`，不污染系统 Python。

其他用法：

```bash
./power_cycle_test.sh -c other.yaml     # 指定其它配置文件
./power_cycle_test.sh --cycles 100      # 临时覆盖循环次数（0 = 无限）
./power_cycle_test.sh --no-venv         # 使用系统 Python（需已装依赖）
```

在 `config.yaml` 中把 `transport` 改成 `mock`，即可不接硬件完整演练一遍流程
（计时、日志、CSV 都会真实产生）。

## config.yaml 关键字段

### 串口

```yaml
serial:
  port: "auto"          # COM5 / /dev/ttyUSB0 / auto（自动识别 USB 串口）
  baudrate: 9600        # 与电源 Communication 菜单一致
  timeout: 2.0          # 读写超时（秒）
  write_terminator: "\r\n"
  read_terminator: "\n"
  command_delay: 0.05   # 命令间隔，避免电源处理不过来
```

`port: "auto"` 会枚举系统串口：只有一个就直接用，有多个时优先按
FTDI / CP210x / CH34x 等 USB 转串口芯片筛选。插拔后 COM 号变化也不怕。

### 测试参数

```yaml
test:
  voltage: 12.0     # 输出电压 V
  current: 2.0      # 限流点 A
  on_time: 10       # 上电保持时间 s
  off_time: 10      # 断电间隔 s
  cycles: 5         # 循环次数，0 = 无限
  settle_time: 0.5  # 上电后等多久再测量 s
```

单轮时序：

```
VOLT → CURR → OUTP ON → 等 settle_time → 测量 → 保持到 on_time
      → OUTP OFF → 等 off_time → 下一轮
```

### 安全与记录

```yaml
safety:
  max_voltage: 30     # 防止手误，0 = 不检查
  max_current: 5
  check_idn: true     # 校验 *IDN? 是否含 ITECH，防止连错串口
  idn_keyword: "ITECH"

measurement:
  enabled: true       # 回读 MEAS:VOLT? / MEAS:CURR?
  csv: true
  csv_file: ""        # 留空 = logs/measurements_时间戳.csv
```

### 换型号时只改 SCPI 段

不同固件命令可能略有差异，脚本不写死命令：

```yaml
scpi:
  set_voltage: "VOLT {voltage}"
  set_current: "CURR {current}"
  output_on: "OUTP ON"
  output_off: "OUTP OFF"
  measure_voltage: "MEAS:VOLT?"
  measure_current: "MEAS:CURR?"
```

例如某些型号输出命令写作 `OUTP:STAT ON`，或电压写作 `VOLT:LEV 12`，
只改这里即可，不用动脚本。

## 运行输出与退出码

- 日志：`logs/power_test_YYYYmmdd_HHMMSS.log`（每次运行一个）
- 数据：`logs/measurements_YYYYmmdd_HHMMSS.csv`（含循环序号、时间、电压、电流、功率）

| 退出码 | 含义 |
| --- | --- |
| 0 | 正常完成 |
| 1 | 参数 / 配置文件路径错误 |
| 2 | 配置内容错误、依赖安装失败 |
| 3 | 连接电源失败（串口打不开、IDN 不匹配、无应答） |
| 4 | 运行中通信错误，测试中止 |
| 130 | 被 Ctrl+C 中断 |

**安全兜底**：无论正常结束、异常退出还是 Ctrl+C，脚本都会执行
`OUTP OFF`、`SYST:LOC` 并关闭串口；连接成功时也会先确保输出处于关闭状态。

## 常见问题

| 现象 | 排查方向 |
| --- | --- |
| 设备管理器没有 COM 口 | 换数据线（非充电线）、换主板后置 USB 口、装 VCP 驱动；显示 "USB Serial Converter" 无 COM 号说明装成了 D2XX 驱动 |
| `没有检测到任何串口` | 电源是否开机、USB 线是否通、Linux 下 `dmesg \| tail` 看是否枚举 |
| 打开串口失败 / 权限不足 | 串口被厂商上位机或串口助手占用；Linux 用户加入 `dialout` 组 |
| 查询无应答 | 波特率不对（试 9600 / 115200）；结尾符换成 `\r\n` 或 `\n`；确认已发 `SYST:REM` 进入远程模式 |
| 返回答复是乱码 | 数据格式必须是 8N1，校验位改为 `N` |
| `*IDN?` 不含 ITECH | 串口号选错（连到了别的仪器）；或把 `safety.check_idn` 设为 `false` |
| 上电瞬间被测板复位 / 电压过冲 | 这是电源缓启动特性，可在 `settle_time` 内等待稳定；电流限值不要设得过大 |
| 长时间老化中途掉线 | 关闭 USB 根集线器的“允许计算机关闭此设备以节约电源”；避免 USB Hub；必要时缩短 `timeout` 让脚本更快报错重连 |

## 注意

- 正式跑之前先 `-n` 干跑，确认电压、电流、次数、串口都没填错。
- `max_voltage` / `max_current` 只是软件层面的防呆，不能替代硬件保护；
  被测设备的过压/过流保护仍应保留。
- 无人值守长时间循环时，请确认负载与接线可靠，并保证电脑不会休眠。
