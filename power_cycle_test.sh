#!/usr/bin/env bash
# =============================================================================
#  艾德克斯（ITECH）电源自动上下电测试
#
#  设计思路：
#    电源的 USB 口在系统中枚举为“虚拟串口”（Windows 下 COMx，Linux 下
#    /dev/ttyUSBx 或 /dev/ttyACMx），本脚本通过该串口发送 SCPI 命令，
#    控制输出电压 / 电流 / 输出开关，实现“上电 - 保持 - 断电 - 间隔”的循环。
#
#    所有测试参数都在 config.yaml 中配置：
#      串口（可写 auto 自动识别）、电压、电流、上电时间、间隔时间、循环次数。
#
#  跨平台：Windows 的 Git Bash / Cygwin 与 Linux 使用同一份脚本，
#    脚本会自动把路径转换成对应平台可识别的格式（cygpath）。
#
#  用法：
#    ./power_cycle_test.sh                 # 按 config.yaml 正式执行
#    ./power_cycle_test.sh -n              # 干跑：只校验配置、打印计划
#    ./power_cycle_test.sh --cycles 20     # 临时覆盖循环次数
#    ./power_cycle_test.sh -c other.yaml   # 指定其它配置文件
# =============================================================================
# 严格模式：任一步出错立刻退出，避免“电源还带着电，脚本却继续往下跑”
#   -E           : ERR 陷阱在函数和子 shell 里同样生效
#   -e           : 任何命令返回非 0 立即退出
#   -u           : 使用未定义变量视为错误
#   -o pipefail  : 管道中任意一段失败，整条管道就算失败
set -Eeuo pipefail

# ------------------------------------------------------------ 全局变量
VERSION="1.0.0"        # 版本号，仅用于 --help 与日志展示
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
                       # 脚本自身所在目录。用 BASH_SOURCE 而不是 $0，
                       # 这样被 source 或被软链接调用时也能拿到真实路径
CONFIG_FILE="$SCRIPT_DIR/config.yaml"  # 默认配置文件，可被 -c/--config 覆盖
VENV_DIR="$SCRIPT_DIR/.venv"           # 自动创建的 Python 虚拟环境目录
DRY_RUN=0                              # 1 = 干跑：只校验配置，不碰电源
USE_VENV=1                             # 1 = 允许自动建虚拟环境；--no-venv 时置 0
CYCLES_OVERRIDE=""                     # --cycles 的临时值，空串表示未指定

# ---------------------------------------------------------------- 输出工具
# 颜色只在“输出是终端”时才启用（[[ -t 1 ]] 判断 stdout 是否连着终端），
# 这样把输出重定向到日志文件时不会混入一堆 ESC 转义序列。
C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
fi

# 用法：
#   info  "提示文字"    -> 打印到 stdout，正常流程信息
#   warn  "提示文字"    -> 打印到 stderr，警告（黄）
#   error "提示文字"    -> 打印到 stderr，错误（红），但不退出
#   die   "提示文字"    -> 打印错误后 exit 1（红），用于“无法继续”的致命错误
info()  { printf '%s[信息]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

# usage()：打印帮助文本。
# 调用时机：用户传了 -h / --help，或传了无法识别的参数（由 die 提示后手动执行）。
# 用法：usage   （无参数，输出后由调用方决定 exit 0）
usage() {
  cat <<EOF
艾德克斯（ITECH）电源自动上下电测试 v${VERSION}

用法: $(basename "$0") [选项]

选项:
  -c, --config <文件>   指定配置文件（默认: 脚本同目录下的 config.yaml）
  -n, --dry-run         干跑：只解析和校验配置并打印执行计划，不连接电源
      --cycles <N>      临时覆盖配置里的循环次数（0 表示无限循环）
      --no-venv         不创建虚拟环境，直接使用系统 Python（需已装依赖）
  -h, --help            显示本帮助

示例:
  ./power_cycle_test.sh
  ./power_cycle_test.sh -n --cycles 3
  ./power_cycle_test.sh -c ./config.yaml --no-venv

说明:
  首次运行会在脚本目录创建 .venv 并自动安装 PyYAML / pyserial（需要联网）。
  测试参数（串口、电压、电流、上电时间、间隔、循环次数）见 config.yaml。
EOF
}

# ---------------------------------------------------------------- 参数解析
# 逐个消费命令行参数（$# 是剩余参数个数，shift 表示丢弃已处理的参数）。
# 支持的选项见 usage()，解析结果只影响全局变量，真正的逻辑在后面的 Python 里。
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)                       # 指定配置文件路径
      [[ $# -ge 2 ]] || die "--config 需要一个文件路径"
      CONFIG_FILE="$2"; shift 2 ;;    # shift 2：一次吃掉 “-c” 和 “路径” 两个参数
    -n|--dry-run) DRY_RUN=1; shift ;;  # 干跑，不连电源
    --cycles)                          # 临时覆盖 config.yaml 里的循环次数
      [[ $# -ge 2 ]] || die "--cycles 需要一个整数"
      CYCLES_OVERRIDE="$2"; shift 2 ;;
    --no-venv) USE_VENV=0; shift ;;    # 不建虚拟环境，直接用系统 Python
    -h|--help) usage; exit 0 ;;        # 打印帮助并正常退出
    *) die "未知参数: $1（使用 --help 查看帮助）" ;;   # 兜底：拒绝未知参数
  esac
done

# 路径规范化：把用户给的路径统一成“当前系统能用的绝对路径”
if [[ "$CONFIG_FILE" =~ ^[A-Za-z]:[\\/] ]]; then
  # 情况 1：Windows 风格路径（例如从资源管理器复制来的 E:\xxx\config.yaml）
  # Git Bash 里必须用 POSIX 路径，所以先 cygpath -u 转成 /e/xxx/...
  command -v cygpath >/dev/null 2>&1 && CONFIG_FILE="$(cygpath -u "$CONFIG_FILE")"
elif [[ "$CONFIG_FILE" != /* ]]; then
  # 情况 2：相对路径（如 ./config.yaml），补全成 当前目录/xxx 的绝对路径
  CONFIG_FILE="$PWD/$CONFIG_FILE"
fi

# 收尾校验：配置文件必须真实存在；--cycles 必须是非负整数（0 表示无限循环）
[[ -f "$CONFIG_FILE" ]] || die "找不到配置文件: $CONFIG_FILE"
if [[ -n "$CYCLES_OVERRIDE" && ! "$CYCLES_OVERRIDE" =~ ^[0-9]+$ ]]; then
  die "--cycles 必须是非负整数，当前为: $CYCLES_OVERRIDE"
fi

# ---------------------------------------------------------------- 平台适配
# Git Bash / Cygwin 下 bash 用的是 POSIX 路径（/e/xxx），而 Windows 版 Python
# 只认 C:\xxx，因此把传给 Python 的路径做一次转换；Linux 下原样返回。
#
# 用法：
#   NATIVE="$(to_native_path "/e/proj/logs")"   # Windows -> E:\proj\logs
#                                               # Linux   -> /e/proj/logs（不变）
# 用途：凡是要通过环境变量 / 命令行传给 Windows 版 Python 的路径，都必须过一遍它。
to_native_path() {
  if command -v cygpath >/dev/null 2>&1 &&
     { [[ "${OSTYPE:-}" == cygwin* ]] || [[ "${OSTYPE:-}" == msys* ]]; }; then
    cygpath -w -- "$1"
  else
    printf '%s' "$1"
  fi
}

# ---------------------------------------------------------------- Python 环境
# PY_CMD 是“最终用来跑执行器的 Python 命令”，用数组保存，
# 这样可以同时容纳 "py" "-3" 这种带参数的写法（"${PY_CMD[@]}" 展开不会串味）。
PY_CMD=()

# pick_python()：挑一个可用的 Python 3.8+ 解释器。
# 用法：pick_python || die "..."        （成功返回 0，失败返回 1）
#   优先级：① 环境变量 $PYTHON 指定的解释器  ② python3  ③ python  ④ py -3
#   每个候选都用 `python -c 'import sys; ...'` 实测版本号，够 3.8 才录用。
#   命中后写入全局 PY_CMD。
pick_python() {
  local cand parts
  if [[ -n "${PYTHON:-}" ]]; then
    if "${PYTHON}" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
      PY_CMD=("${PYTHON}")
      return 0
    fi
  fi
  for cand in "python3" "python" "py -3"; do
    read -r -a parts <<< "$cand"          # 把 "py -3" 拆成数组 (py -3)
    command -v "${parts[0]}" >/dev/null 2>&1 || continue   # 命令不存在就换下一个
    if "${parts[@]}" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
      PY_CMD=("${parts[@]}")
      return 0
    fi
  done
  return 1
}

# check_modules()：检查当前 PY_CMD 能否导入指定的模块。
# 用法：check_modules yaml serial        （全部可导入返回 0，任一失败返回 1）
#   在“装依赖”之前判断是否需要装，装完之后再调一次做终检。
check_modules() {
  local mod
  for mod in "$@"; do
    "${PY_CMD[@]}" -c "import ${mod}" >/dev/null 2>&1 || return 1
  done
  return 0
}

# venv_python()：返回 .venv 里解释器的路径（优先 Windows 的 Scripts/python.exe，
#                 再试 Linux 的 bin/python）；虚拟环境不存在则返回 1。
# 用法：VP="$(venv_python 2>/dev/null || true)"     （取不到就拿到空串，不中断脚本）
venv_python() {
  if [[ -x "$VENV_DIR/Scripts/python.exe" ]]; then
    printf '%s' "$VENV_DIR/Scripts/python.exe"
  elif [[ -x "$VENV_DIR/bin/python" ]]; then
    printf '%s' "$VENV_DIR/bin/python"
  else
    return 1
  fi
}

# ① 选出解释器；找不到就 die（退出码 1）
pick_python || die "未找到 Python 3.8+。请先安装 Python 3，或设置 PYTHON 环境变量指向解释器。"
# 备份“系统 Python”，后面若虚拟环境方案失败要回退用它
ORIG_PY_CMD=("${PY_CMD[@]}")
PY_VER="$("${PY_CMD[@]}" -c 'import sys; print(sys.version.split()[0])' 2>/dev/null || printf '?')"
info "Python: ${PY_CMD[*]} (${PY_VER})"

# ② 确定本次需要哪些依赖：
#    yaml     —— 解析 config.yaml，任何时候都要
#    serial   —— 串口通信，只有真实跑测试（非干跑）才需要
MODULES=(yaml)
PKGS=("pyyaml>=6.0")
if [[ $DRY_RUN -eq 0 ]]; then
  MODULES+=(serial)
  PKGS+=("pyserial>=3.5")
fi

# ③ 之前若已回退安装到 .deps，这里把 .deps 加进 PYTHONPATH 直接复用。
#    注意路径必须转成 Windows 版 Python 认得的形式。
DEPS_DIR="$SCRIPT_DIR/.deps"
if [[ -d "$DEPS_DIR" ]]; then
  export PYTHONPATH="$(to_native_path "$DEPS_DIR")"
fi

# ④ 已存在可用的虚拟环境就直接用（快），省得每次启动都去检查/动系统 Python。
#    用户显式指定了 $PYTHON 时不抢，尊重用户选择。
if [[ $USE_VENV -eq 1 && -z "${PYTHON:-}" ]]; then
  VPE="$(venv_python 2>/dev/null || true)"
  if [[ -n "$VPE" ]] && "$VPE" -c "import sys" >/dev/null 2>&1; then
    PY_CMD=("$VPE")
  fi
fi

# ⑤ 依赖缺失时的三级降级策略：venv → 修 venv → .deps --target 安装
if ! check_modules "${MODULES[@]}"; then
  # 5.1 用户明确说 --no-venv：不许自动装，给出手动安装提示并退出（码 2）
  if [[ $USE_VENV -eq 0 ]]; then
    error "当前 Python 缺少依赖，且指定了 --no-venv。"
    error "请先安装: ${PY_CMD[*]} -m pip install -r \"$(to_native_path "$SCRIPT_DIR/requirements.txt")\""
    exit 2
  fi

  # 5.2 虚拟环境存在但解释器坏了 → 删掉重建（避免留下半残的 .venv）
  VPY=""
  if [[ -d "$VENV_DIR" ]]; then
    VPY="$(venv_python 2>/dev/null || true)"
    if [[ -z "$VPY" ]]; then
      rm -rf -- "$VENV_DIR"
    fi
  fi
  # 5.3 没有虚拟环境就新建一个（首次运行会联网，稍慢）
  if [[ -z "$VPY" ]]; then
    info "创建虚拟环境: $VENV_DIR（首次运行需要联网安装依赖）"
    "${PY_CMD[@]}" -m venv "$VENV_DIR" 2>/dev/null || true
    VPY="$(venv_python 2>/dev/null || true)"
  fi

  # 5.4 有些发行版建出来的 venv 没有 pip，用 ensurepip 补上
  if [[ -n "$VPY" ]]; then
    if ! "$VPY" -m pip --version >/dev/null 2>&1; then
      "$VPY" -m ensurepip --upgrade >/dev/null 2>&1 || true
    fi
  fi

  # 5.5 用 venv 里的 pip 装依赖（--disable-pip-version-check -q：安静模式）
  if [[ -n "$VPY" ]] && "$VPY" -m pip --version >/dev/null 2>&1; then
    info "安装依赖: ${PKGS[*]}"
    if "$VPY" -m pip install --disable-pip-version-check -q "${PKGS[@]}"; then
      PY_CMD=("$VPY")          # 成功：后续统一用 venv 里的 Python
    else
      warn "虚拟环境安装依赖失败，改用本地 .deps 目录"
      VPY=""                   # 失败：清空 VPY，走下面的兜底分支
    fi
  fi

  # 5.6 兜底：venv 完全不可用（缺 venv 模块 / 被组策略限制 / 无网络权限装 pip），
  #     改用 `pip install --target .deps` 装到项目目录，不污染系统 Python。
  if [[ -z "$VPY" ]]; then
    warn "虚拟环境不可用，改为安装到 $DEPS_DIR（不修改系统 Python）"
    PY_CMD=("${ORIG_PY_CMD[@]}")   # 回退到一开始选中的系统 Python
    if ! "${PY_CMD[@]}" -m pip install --disable-pip-version-check -q \
         --target "$DEPS_DIR" "${PKGS[@]}"; then
      error "依赖安装失败，请检查网络 / 代理，或手动执行:"
      error "  ${PY_CMD[*]} -m pip install pyyaml pyserial"
      exit 2
    fi
    export PYTHONPATH="$(to_native_path "$DEPS_DIR")"
  fi

  # 5.7 终检：装完还导不进来就说明环境有问题，直接死
  check_modules "${MODULES[@]}" || die "依赖安装后仍无法导入，请检查 Python 环境。"
fi

# ---------------------------------------------------------------- 调用执行器
# 把 shell 侧解析好的信息通过环境变量交给下面的 Python 代码
# （Python 代码是内联 heredoc，没有独立文件，只能靠环境变量传参）
export PT_CONFIG="$(to_native_path "$CONFIG_FILE")"        # 配置文件绝对路径
export PT_SCRIPT_DIR="$(to_native_path "$SCRIPT_DIR")"     # 脚本目录（日志/CSV 基准）
export PT_DRY_RUN="$DRY_RUN"                               # "1" = 干跑
export PT_CYCLES="$CYCLES_OVERRIDE"                        # 循环次数覆盖值（可为空）
export PYTHONIOENCODING="utf-8"                            # 保证中文输出不乱码
export PYTHONDONTWRITEBYTECODE=1                           # 不生成 __pycache__

if [[ $DRY_RUN -eq 1 ]]; then
  info "干跑模式：只校验配置，不打开串口、不操作电源"
fi

"${PY_CMD[@]}" - <<'PYCODE'
# -*- coding: utf-8 -*-
"""ITECH 电源自动上下电测试执行器（由 power_cycle_test.sh 调用）。

实现方式：这段 Python 代码以内联 heredoc（<<'PYCODE'）的形式嵌在 shell 脚本里，
通过 `python - <<'PYCODE'` 从标准输入执行，因此：
  · 没有独立的 .py 文件，参数只能靠 shell 导出的环境变量（PT_*）传递；
  · 加引号的 'PYCODE' 表示内容原样传入，shell 不做任何变量替换。
"""

from __future__ import annotations

import csv      # 写测量数据 CSV
import os       # 路径拼接、目录创建、读环境变量
import re       # 用正则从 SCPI 应答里抠出数字
import signal   # 捕获 Ctrl+C / kill，实现“优雅停机”
import sys      # 退出码
import time     # 计时、sleep、monotonic 时钟
from datetime import datetime   # 日志/CSV 时间戳

import yaml     # 解析 config.yaml（由 shell 侧自动安装）

# 进程退出码：shell 侧可据此判断失败原因
EXIT_OK = 0            # 正常完成
EXIT_CONFIG = 2        # 配置错误
EXIT_CONNECT = 3       # 连不上电源
EXIT_RUNTIME = 4       # 运行中出错（掉线、命令失败等）
EXIT_INTERRUPTED = 130 # 被 Ctrl+C 中断（沿用 shell 的 128+SIGINT 约定）

# 默认配置：config.yaml 里没写的项就用这里的兜底值。
# 读取时通过 deep_merge 与用户配置合并，所以用户只需写自己关心的那几项。
DEFAULT_CONFIG = {
    "transport": "serial",   # "serial" = 真实电源；"mock" = 模拟电源（自测用）
    "serial": {
        "port": "auto",            # 串口号；"auto" 表示自动扫描识别
        "baudrate": 9600,          # 波特率
        "bytesize": 8,             # 数据位
        "parity": "N",             # 校验位 N/E/O
        "stopbits": 1,             # 停止位 1/1.5/2
        "timeout": 2.0,            # 读超时（秒），也是写超时
        "write_terminator": "\r\n",  # 发送时追加在命令末尾
        "read_terminator": "\n",     # 读到它就认为一帧结束
        "command_delay": 0.05,     # 每条命令后等待的秒数（给电源反应时间）
        "xonxoff": False,          # 软件流控
        "rtscts": False,           # 硬件流控
        "dsrdtr": False,           # 硬件流控
    },
    "test": {
        "voltage": 12.0,     # 输出电压（V）
        "current": 2.0,      # 限流值（A）
        "on_time": 10.0,     # 每次上电保持的秒数
        "off_time": 10.0,    # 两次上电之间断电间隔的秒数
        "cycles": 5,         # 循环次数；0 表示无限循环
        "settle_time": 0.5,  # 上电后等这么久再测量（等输出稳定）
    },
    "measurement": {"enabled": True, "csv": True, "csv_file": ""},
    #                                              ↑ 留空则自动生成带时间戳的文件名
    "safety": {
        "max_voltage": 0.0,   # 电压硬上限，0 = 不限制（超过则拒绝启动）
        "max_current": 0.0,   # 电流硬上限，0 = 不限制
        "check_idn": True,    # 是否校验设备标识，防止连错串口
        "idn_keyword": "ITECH",  # *IDN? 应答里必须包含的关键字
    },
    "scpi": {   # SCPI 命令模板；换型号只需改这里，不用动代码
        "identify": "*IDN?",           # 查询设备标识
        "reset": "*CLS",               # 清错误队列
        "remote_enable": "SYST:REM",   # 切远程模式
        "local_enable": "SYST:LOC",    # 退出前切回本地（面板可操作）
        "set_voltage": "VOLT {voltage}",   # {voltage} 会被真实电压替换
        "set_current": "CURR {current}",
        "output_on": "OUTP ON",
        "output_off": "OUTP OFF",
        "measure_voltage": "MEAS:VOLT?",
        "measure_current": "MEAS:CURR?",
    },
    "logging": {"file": True, "dir": "logs"},  # dir 为相对路径时相对配置文件所在目录
    "retry": {"connect_attempts": 3, "connect_interval": 2.0, "command_attempts": 2},
    #          连接重试次数        每次重试间隔（秒）        单条命令重试次数
}

# USB 转串口芯片常见 VID：FTDI、Silicon Labs、WCH、Prolific。
# auto 识别时优先挑这些芯片的口，避免选到主板上无关的串口。
KNOWN_USB_VIDS = {0x0403, 0x10C4, 0x1A86, 0x067B}

# 从 SCPI 应答文本中抓取第一个数字（支持正负号、小数、科学计数法）
NUM_RE = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")

# 全局停机标志：由信号处理函数置 True，所有等待/循环都会检查它
_STOP = False


# 信号处理回调：收到 Ctrl+C(SIGINT) / SIGTERM 时置位 _STOP。
# 用法：signal.signal(signal.SIGINT, request_stop)
# 注意：这里不直接退出，而是让主循环自己走到“安全断电”逻辑，避免电源一直带电。
def request_stop(_signum=None, _frame=None):
    global _STOP
    _STOP = True


# 三种自定义异常，用于在主流程里区分失败类型、返回不同退出码
class ConfigError(Exception):
    """config.yaml 内容不合法。"""


class ConnectError(RuntimeError):
    """无法与电源建立通信。"""


class ScpiError(RuntimeError):
    """SCPI 命令发送 / 应答异常。"""


# --------------------------------------------------------------------- 日志
class Logger:
    """同时输出到屏幕和日志文件的记录器。

    用法：
        log = Logger("logs/power_test_20250101_120000.log")
        log("连接电源…")                 # level 默认 INFO
        log("测量失败（已忽略）", "WARN")  # 也支持 ERROR / WARN / INFO
        log.close()                      # 用完记得关文件句柄
    设计要点：
      · 用 __call__ 让实例可以像函数一样调用，代码里 log(...) 比 log.write(...) 简洁；
      · 每次写完立刻 flush，程序被强杀时日志也不会丢。
    """

    def __init__(self, path=None):
        self.fh = None
        if path:
            ensure_dir(os.path.dirname(path))
            self.fh = open(path, "a", encoding="utf-8")   # 追加模式，多次运行不覆盖

    def __call__(self, message, level="INFO"):
        line = f"{datetime.now():%Y-%m-%d %H:%M:%S} [{level:5s}] {message}"
        print(line, flush=True)
        if self.fh:
            self.fh.write(line + "\n")
            self.fh.flush()

    def close(self):
        if self.fh:
            self.fh.close()
            self.fh = None


def ensure_dir(path):
    """确保目录存在（不存在就创建，已存在也不报错）。

    用法：ensure_dir("/path/to/logs")
    """
    if path:
        os.makedirs(path, exist_ok=True)


def fmt_duration(seconds):
    """把秒数格式化成中文可读时长。

    用法：fmt_duration(3725) -> '1 小时 2 分 5 秒'
    用途：干跑时估算总耗时、结束时汇报实际耗时。
    """
    seconds = max(0, int(round(seconds)))
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return f"{hours} 小时 {minutes} 分 {secs} 秒"
    if minutes:
        return f"{minutes} 分 {secs} 秒"
    return f"{secs} 秒"


# --------------------------------------------------------------------- 配置
def deep_merge(base, override):
    """递归合并两个字典：override 覆盖 base，两边都是 dict 时继续往下合并。

    用法：cfg = deep_merge(DEFAULT_CONFIG, 用户配置)
    目的：用户 config.yaml 只写 test.voltage，其余 test.* 仍能保留默认值。
    """
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


# 兼容常见别名写法，避免用户照着口语去命名（写 com_port 也能当 port 用）
ALIASES = {
    "serial": {"com_port": "port", "baud": "baudrate", "com": "port"},
    "test": {
        "power_on_time": "on_time",
        "power_off_time": "off_time",
        "interval": "off_time",
        "voltage_v": "voltage",
        "current_a": "current",
    },
}


def apply_aliases(raw):
    """把别名键改写成标准键名（标准键已存在时以标准键为准）。

    用法：raw = apply_aliases(yaml 解析出来的原始字典)
    注意：直接原地修改 raw，返回同一个对象。
    """
    for section, mapping in ALIASES.items():
        data = raw.get(section)
        if not isinstance(data, dict):
            continue
        for old, new in mapping.items():
            if old in data:
                if new not in data:
                    data[new] = data[old]
                data.pop(old, None)
    return raw


def as_float(value, name, minimum=None, exclusive=False):
    """把配置值转成 float，顺便做范围校验。

    用法：
        as_float("12.5", "test.voltage")                    -> 12.5
        as_float("12.5", "test.voltage", 0.0)               -> 必须 >= 0
        as_float("12.5", "test.voltage", 0.0, exclusive=True) -> 必须 > 0
    校验失败抛 ConfigError（带配置项名字，方便定位）。
    """
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise ConfigError(f"{name} 必须是数字，当前值: {value!r}") from None
    if exclusive and number <= (minimum or 0.0):
        raise ConfigError(f"{name} 必须大于 {minimum}，当前值: {number}")
    if minimum is not None and number < minimum:
        raise ConfigError(f"{name} 不能小于 {minimum}，当前值: {number}")
    return number


def as_int(value, name, minimum=None):
    """转成 int（先走 as_float，再检查是否真的是整数）。

    用法：as_int("9600", "serial.baudrate", 300)  -> 9600，且必须 >= 300
    """
    number = as_float(value, name)
    if number != int(number):
        raise ConfigError(f"{name} 必须是整数，当前值: {value!r}")
    number = int(number)
    if minimum is not None and number < minimum:
        raise ConfigError(f"{name} 不能小于 {minimum}，当前值: {number}")
    return number


def unescape(value):
    """把配置里手写的 \\r\\n 字面量转换成真正的控制字符。

    用法：unescape("\\r\\n") -> "\r\n"（回车换行）
    原因：YAML 里写 "\r\n" 会被解析成真实换行，写 '\\r\\n' 才是字面量，
          这里统一兜住两种写法。
    """
    if "\\" not in value:
        return value
    return value.replace("\\r", "\r").replace("\\n", "\n").replace("\\t", "\t")


def as_bool(value, name):
    """把配置值转成 bool，支持 true/false、1/0、yes/no、on/off 等写法。

    用法：as_bool("yes", "logging.file") -> True
    """
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        text = value.strip().lower()
        if text in ("1", "true", "yes", "on"):
            return True
        if text in ("0", "false", "no", "off", ""):
            return False
    raise ConfigError(f"{name} 必须是 true/false，当前值: {value!r}")


def load_config(path):
    """读取并校验配置文件，返回最终生效的配置字典。

    用法：cfg = load_config(os.environ["PT_CONFIG"])
    流程：读文件 → yaml 解析 → 别名归一 → 与默认值合并 → validate 校验
    出错抛 ConfigError，由 main() 转成退出码 2。
    """
    if not os.path.isfile(path):
        raise ConfigError(f"配置文件不存在: {path}")
    try:
        # utf-8-sig：自动吃掉 Windows 记事本加的 BOM
        with open(path, "r", encoding="utf-8-sig") as fh:
            raw = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        raise ConfigError(f"YAML 语法错误: {exc}") from exc
    except OSError as exc:
        raise ConfigError(f"无法读取配置文件: {exc}") from exc
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise ConfigError("配置文件根节点必须是键值映射（key: value）")
    cfg = deep_merge(DEFAULT_CONFIG, apply_aliases(raw))
    validate(cfg)
    return cfg


def validate(cfg):
    """逐项校验配置，并把值就地转换成正确类型（str→int/float/bool 等）。

    用法：validate(cfg)   # 由 load_config 调用，无需手动调
    设计意图：把“类型 + 范围 + 逻辑一致性”全部拦在执行之前，
              避免跑了一半才发现电压超标、时间写成负数。
    所有问题都抛 ConfigError。
    """
    if cfg["transport"] not in ("serial", "mock"):
        raise ConfigError("transport 只能是 serial（真实电源）或 mock（模拟自测）")

    ser = cfg["serial"]
    if not isinstance(ser, dict):
        raise ConfigError("serial 必须是键值映射")
    ser["port"] = str(ser["port"] or "").strip()
    if not ser["port"]:
        raise ConfigError('serial.port 不能为空，例如 "COM5"、"/dev/ttyUSB0"，或写 "auto" 自动识别')
    ser["baudrate"] = as_int(ser["baudrate"], "serial.baudrate", 300)
    if not 300 <= ser["baudrate"] <= 921600:
        raise ConfigError(f"serial.baudrate 超出范围: {ser['baudrate']}")
    ser["bytesize"] = as_int(ser["bytesize"], "serial.bytesize")
    if ser["bytesize"] not in (5, 6, 7, 8):
        raise ConfigError(f"serial.bytesize 只能是 5/6/7/8，当前: {ser['bytesize']}")
    ser["parity"] = str(ser["parity"]).strip().upper()
    if ser["parity"] not in ("N", "E", "O", "M", "S"):
        raise ConfigError(f"serial.parity 只能是 N/E/O/M/S，当前: {ser['parity']}")
    ser["stopbits"] = as_float(ser["stopbits"], "serial.stopbits")
    if ser["stopbits"] not in (1.0, 1.5, 2.0):
        raise ConfigError(f"serial.stopbits 只能是 1/1.5/2，当前: {ser['stopbits']}")
    ser["timeout"] = as_float(ser["timeout"], "serial.timeout", 0.1)
    ser["command_delay"] = as_float(ser["command_delay"], "serial.command_delay", 0.0)
    for key in ("write_terminator", "read_terminator"):
        if not isinstance(ser[key], str) or not ser[key]:
            raise ConfigError(f"serial.{key} 必须是非空字符串，例如 \"\\r\\n\"")
        ser[key] = unescape(ser[key])
    for key in ("xonxoff", "rtscts", "dsrdtr"):
        ser[key] = as_bool(ser[key], f"serial.{key}")

    # 测试参数：电压/电流/上电时间必须 > 0；间隔可为 0（连续快切）；
    # cycles = 0 表示无限循环；settle_time 不能超过 on_time，否则永远测不到
    test = cfg["test"]
    test["voltage"] = as_float(test["voltage"], "test.voltage", 0.0, exclusive=True)
    test["current"] = as_float(test["current"], "test.current", 0.0, exclusive=True)
    test["on_time"] = as_float(test["on_time"], "test.on_time", 0.0, exclusive=True)
    test["off_time"] = as_float(test["off_time"], "test.off_time", 0.0)
    test["cycles"] = as_int(test["cycles"], "test.cycles", 0)
    test["settle_time"] = as_float(test["settle_time"], "test.settle_time", 0.0)
    if test["settle_time"] > test["on_time"]:
        raise ConfigError(
            f"test.settle_time（{test['settle_time']}）不能大于 test.on_time（{test['on_time']}）"
        )

    # 安全上限：设了就检查，没设（0）表示不限制
    safety = cfg["safety"]
    safety["max_voltage"] = as_float(safety["max_voltage"], "safety.max_voltage", 0.0)
    safety["max_current"] = as_float(safety["max_current"], "safety.max_current", 0.0)
    safety["check_idn"] = as_bool(safety["check_idn"], "safety.check_idn")
    safety["idn_keyword"] = str(safety["idn_keyword"] or "").strip()
    if safety["max_voltage"] > 0 and test["voltage"] > safety["max_voltage"]:
        raise ConfigError(
            f"电压 {test['voltage']} V 超过 safety.max_voltage = {safety['max_voltage']} V"
        )
    if safety["max_current"] > 0 and test["current"] > safety["max_current"]:
        raise ConfigError(
            f"电流 {test['current']} A 超过 safety.max_current = {safety['max_current']} A"
        )

    measurement = cfg["measurement"]
    measurement["enabled"] = as_bool(measurement["enabled"], "measurement.enabled")
    measurement["csv"] = as_bool(measurement["csv"], "measurement.csv")
    measurement["csv_file"] = str(measurement["csv_file"] or "").strip()

    # 预检 SCPI 模板：先用假数据 format 一次，占位符写错（比如 {volt}）当场就暴露
    for key in ("set_voltage", "set_current"):
        template = cfg["scpi"][key]
        if not isinstance(template, str) or not template:
            raise ConfigError(f"scpi.{key} 必须是非空字符串")
        try:
            template.format(voltage="12.000", current="2.000")
        except (KeyError, IndexError, ValueError) as exc:
            raise ConfigError(f"scpi.{key} 模板写法有误: {exc}") from None

    cfg["logging"]["file"] = as_bool(cfg["logging"]["file"], "logging.file")
    cfg["logging"]["dir"] = str(cfg["logging"]["dir"] or "logs")

    # 重试策略：连接失败重试次数/间隔，单条命令失败重试次数
    retry = cfg["retry"]
    retry["connect_attempts"] = as_int(retry["connect_attempts"], "retry.connect_attempts", 1)
    retry["connect_interval"] = as_float(retry["connect_interval"], "retry.connect_interval", 0.0)
    retry["command_attempts"] = as_int(retry["command_attempts"], "retry.command_attempts", 1)


# ---------------------------------------------------------------- 通信封装
def resolve_port(cfg, log):
    """确定要打开哪个串口。

    用法：device = resolve_port(cfg, log)
    逻辑：
      · serial.port 不是 "auto" → 原样返回用户指定的端口（COM5 / /dev/ttyUSB0）
      · 是 "auto" → 用 pyserial 枚举所有串口：
          - 优先挑 USB 转串口芯片（KNOWN_USB_VIDS）；
          - 候选恰好 1 个 → 选它；
          - 候选 0 个或多个 → 抛 ConnectError，提示用户手动指定（绝不瞎猜）。
    """
    configured = cfg["serial"]["port"]
    if configured.lower() != "auto":
        return configured
    try:
        from serial.tools import list_ports
    except ImportError as exc:
        raise ConfigError('serial.port 设为 "auto" 时需要 pyserial 才能枚举串口') from exc
    ports = sorted(list_ports.comports(), key=lambda item: item.device)
    if not ports:
        raise ConnectError("没有检测到任何串口。请检查 USB 线、驱动，以及电源是否已开机。")
    preferred = [p for p in ports if p.vid in KNOWN_USB_VIDS]
    candidates = preferred or ports
    if len(candidates) == 1:
        chosen = candidates[0]
        log(f"自动识别串口: {chosen.device}（{chosen.description}）")
        return chosen.device
    detail = "；".join(f"{p.device}（{p.description}）" for p in candidates)
    raise ConnectError(
        f"检测到多个候选串口，无法自动确定，请在 config.yaml 的 serial.port 中指定一个：{detail}"
    )


class Transport:
    """通信层抽象基类：定义 open / write / read / close 四个动作。

    作用：让上层 PowerSupply 只依赖这个接口，从而可以在
          真实串口（SerialTransport）和模拟电源（MockTransport）之间自由切换。
    """

    def open(self, log):
        raise NotImplementedError

    def write(self, text):
        raise NotImplementedError

    def read(self):
        raise NotImplementedError

    def close(self):
        raise NotImplementedError


class SerialTransport(Transport):
    """真实串口通信实现，基于 pyserial。

    用法：
        t = SerialTransport(cfg)
        t.open(log); t.write("OUTP ON"); resp = t.read(); t.close()
    """

    def __init__(self, cfg):
        self.cfg = cfg["serial"]
        self.ser = None

    def open(self, log):
        try:
            import serial
        except ImportError as exc:
            raise ConfigError("缺少 pyserial，请执行: python -m pip install pyserial") from exc
        device = resolve_port({"serial": self.cfg}, log)
        log(f"打开串口 {device}（{self.cfg['baudrate']} 波特率）...")
        try:
            self.ser = serial.Serial(
                port=device,
                baudrate=int(self.cfg["baudrate"]),
                bytesize=int(self.cfg["bytesize"]),
                parity=str(self.cfg["parity"]),
                stopbits=float(self.cfg["stopbits"]),
                timeout=float(self.cfg["timeout"]),
                write_timeout=float(self.cfg["timeout"]),
                xonxoff=bool(self.cfg["xonxoff"]),
                rtscts=bool(self.cfg["rtscts"]),
                dsrdtr=bool(self.cfg["dsrdtr"]),
            )
        except Exception as exc:
            raise ConnectError(
                f"打开串口 {device} 失败: {exc}\n"
                "  排查：\n"
                "  1) 设备管理器 / ls /dev/ttyUSB* 确认端口号是否正确；\n"
                "  2) 串口是否被厂商上位机、串口助手等程序占用；\n"
                "  3) Linux 下当前用户是否在 dialout 组（sudo usermod -aG dialout $USER）；\n"
                "  4) 是否装了正确的 USB 转串口驱动（ITECH 多用 FTDI 芯片）。"
            ) from exc
        # 刚打开时线路上可能有残留数据（电源上电自检输出等），等一下再清空缓冲区
        time.sleep(0.2)
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()

    def write(self, text):
        # 自动补上配置的结束符（多数仪器要 \r\n 才认），然后立即 flush 保证发出去
        self.ser.write((text + self.cfg["write_terminator"]).encode("ascii"))
        self.ser.flush()

    def read(self):
        # 一直读到出现 read_terminator 或超时；errors="replace" 防止乱码导致抛异常
        raw = self.ser.read_until(self.cfg["read_terminator"].encode("ascii"))
        return raw.decode("ascii", "replace")

    def close(self):
        if self.ser is not None:
            try:
                self.ser.close()
            except Exception:
                pass
            self.ser = None


class MockTransport(Transport):
    """模拟电源：不需要硬件，用于验证脚本流程 / 计时 / 记录。

    用法：在 config.yaml 里写 `transport: mock` 即可启用，
          此时不会打开任何串口，但整条上下电流程、日志、CSV 都会照常执行。
    实现：内部用几个变量记住“设定电压/电流/输出状态”，
          收到查询命令时把值拼成字符串塞进 self.pending，read() 时返回。
    """

    def __init__(self):
        self.opened = False
        self.pending = ""
        self.voltage = 0.0
        self.current = 0.0
        self.output = False

    def open(self, log):
        log("使用 mock 模拟电源（不会操作真实硬件）")
        self.opened = True

    def write(self, text):
        if not self.opened:
            raise ScpiError("mock 串口未打开")
        command = text.strip()
        upper = command.upper()
        if upper == "*IDN?":
            self.pending = "ITECH,MOCK,000000000000,1.0.0"
        elif upper.startswith("VOLT"):
            self.voltage = float(command.split()[-1])
        elif upper.startswith("CURR"):
            self.current = float(command.split()[-1])
        elif upper.startswith("OUTP"):
            self.output = upper.endswith(("ON", "1"))
        elif upper.startswith("MEAS:VOLT"):
            self.pending = f"{self.voltage if self.output else 0.0:.4f}"
        elif upper.startswith("MEAS:CURR"):
            self.pending = f"{self.current if self.output else 0.0:.4f}"
        else:
            self.pending = "0"

    def read(self):
        response, self.pending = self.pending, ""
        return response + "\n"

    def close(self):
        self.opened = False


class PowerSupply:
    """电源门面类：把“SCPI 命令”和“底层传输”隔离开。

    用法：
        ps = PowerSupply(cfg, log)
        ps.connect()                 # 连设备、确认身份、确保输出关闭
        ps.set_voltage(12.0)         # 下发 VOLT 12.000
        ps.set_current(2.0)          # 下发 CURR 2.000
        ps.output(True)              # OUTP ON
        v, a = ps.measure()          # MEAS:VOLT? / MEAS:CURR?
        ps.output(False)             # OUTP OFF
        ps.close()                   # 关串口
    上层 run_test() 只调用这些方法，不关心底层是串口还是 mock。
    """

    def __init__(self, cfg, log):
        self.cfg = cfg
        self.log = log
        self.scpi = cfg["scpi"]
        # 根据 transport 配置选择真实串口或模拟实现（策略模式的体现）
        self.transport = MockTransport() if cfg["transport"] == "mock" else SerialTransport(cfg)
        self.connected = False
        self.identity = ""

    def connect(self):
        """建立连接并完成“开机准备”。

        流程：
          1) 按 retry.connect_attempts 重试打开串口（每次失败间隔 connect_interval 秒）；
          2) 发 *CLS 清状态、SYST:REM 切远程（critical=False，老型号不支持也不致命）；
          3) 查 *IDN? 拿到设备标识，并校验里面含 ITECH（防止连错串口）；
          4) 先强制 OUTP OFF，保证测试从一个确定的“断电”状态开始。
        全部失败抛 ConnectError。
        """
        attempts = int(self.cfg["retry"]["connect_attempts"])
        interval = float(self.cfg["retry"]["connect_interval"])
        last_error = None
        for attempt in range(1, attempts + 1):
            try:
                self.log(f"连接电源（第 {attempt}/{attempts} 次）...")
                self.transport.open(self.log)
                self.connected = True
                # 先清状态并切远程模式：部分型号在本地模式下不响应 SCPI 命令
                if self.scpi.get("reset"):
                    self.send(self.scpi["reset"], critical=False)
                if self.scpi.get("remote_enable"):
                    self.send(self.scpi["remote_enable"], critical=False)
                self.identity = self.query(self.scpi["identify"])
                self.log(f"设备标识: {self.identity}")
                self._check_identity()
                self.output(False)
                self.log("通信正常，输出已确认为关闭状态")
                return
            except Exception as exc:  # noqa: BLE001 - 需要把任何异常转成连接失败
                last_error = exc
                self.log(f"连接失败: {exc}", "WARN")
                self.close()
                if attempt < attempts:
                    time.sleep(interval)
        raise ConnectError(f"连接电源失败（已尝试 {attempts} 次）: {last_error}")

    def close(self):
        self.connected = False
        self.transport.close()

    def _check_identity(self):
        """校验 *IDN? 应答里是否含预期关键字（默认 ITECH）。

        目的：连错串口时（比如连到条码枪）立刻叫停，而不是对陌生设备下 OUTP ON。
        可通过 safety.check_idn: false 关闭，关键字用 safety.idn_keyword 改。
        """
        safety = self.cfg["safety"]
        if not safety["check_idn"]:
            return
        keyword = safety["idn_keyword"]
        if keyword and keyword.upper() not in self.identity.upper():
            raise ConnectError(
                f"设备标识 {self.identity!r} 中未包含 {keyword!r}，可能连到了错误的串口。"
                "请核对 serial.port，或修改 safety.idn_keyword"
            )

    def send(self, command, critical=True):
        if not command:
            return
        attempts = max(1, int(self.cfg["retry"]["command_attempts"]))
        last_error = None
        for _ in range(attempts):
            try:
                self.transport.write(command)
                time.sleep(float(self.cfg["serial"]["command_delay"]))
                return
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                time.sleep(0.2)
        self.log(f"命令发送失败: {command!r}（{last_error}）", "ERROR")
        # critical=True  : 关键命令（上电/断电/设电压），失败必须中断测试
        # critical=False : 可选命令（*CLS/SYST:REM/退出前切本地），失败只记日志
        if critical:
            raise ScpiError(f"发送命令 {command!r} 失败: {last_error}")

    def query(self, command):
        self.send(command)
        try:
            raw = self.transport.read()
        except Exception as exc:  # noqa: BLE001
            raise ScpiError(f"读取 {command!r} 的应答失败: {exc}") from exc
        text = raw.strip().strip("\r\n")
        if not text:
            raise ScpiError(
                f"查询 {command!r} 无应答（超时 {self.cfg['serial']['timeout']} 秒）。"
                "请确认波特率、结尾符，以及电源处于远程控制模式。"
            )
        return text

    # 下面 4 个是给上层用的语义化接口，内部只负责套用 SCPI 模板
    def set_voltage(self, volts):
        # 固定 3 位小数，避免浮点产生 12.000000000000002 这种让仪器不认的字符串
        self.send(self.scpi["set_voltage"].format(voltage=f"{volts:.3f}"))

    def set_current(self, amps):
        self.send(self.scpi["set_current"].format(current=f"{amps:.3f}"))

    def output(self, on):
        """打开/关闭输出。用法：ps.output(True) 上电，ps.output(False) 断电。"""
        self.send(self.scpi["output_on"] if on else self.scpi["output_off"])

    def measure(self):
        """查询实际输出电压电流。返回 (伏特, 安培)。

        用法：volts, amps = ps.measure()
        """
        volts = parse_number(self.query(self.scpi["measure_voltage"]), "电压")
        amps = parse_number(self.query(self.scpi["measure_current"]), "电流")
        return volts, amps


def parse_number(text, what):
    """从仪器应答文本里抓出第一个数字。

    用法：parse_number("+12.0034\\n", "电压") -> 12.0034
    原因：不同型号应答格式不一（有的带单位、有的带前缀），用正则最稳。
    """
    match = NUM_RE.search(text or "")
    if not match:
        raise ScpiError(f"无法从应答中解析{what}: {text!r}")
    return float(match.group(0))


# ------------------------------------------------------------------- CSV
class MeasurementCsv:
    """把每次循环的测量值追加写进 CSV。

    用法：
        w = MeasurementCsv("logs/measurements_20250101_120000.csv")
        w.add(1, 12.003, 1.998)   # 第 1 次循环
        w.close()
    细节：
      · append 模式打开，若文件已存在（tell() != 0）就不再写表头，方便续跑；
      · utf-8-sig 编码，Excel 双击打开中文不乱码；
      · 每行写完 flush，进程被杀也不丢最近的数据。
    """

    HEADER = ["循环", "时间", "电压(V)", "电流(A)", "功率(W)"]

    def __init__(self, path):
        ensure_dir(os.path.dirname(path))
        self.fh = open(path, "a", newline="", encoding="utf-8-sig")
        self.writer = csv.writer(self.fh)
        if self.fh.tell() == 0:
            self.writer.writerow(self.HEADER)

    def add(self, cycle, volts, amps):
        self.writer.writerow(
            [
                cycle,
                datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                f"{volts:.4f}",
                f"{amps:.4f}",
                f"{volts * amps:.4f}",
            ]
        )
        self.fh.flush()

    def close(self):
        self.fh.close()


# ------------------------------------------------------------------ 主流程
def sleep_interruptible(seconds):
    """可中断的 sleep：把长等待切成 0.2 秒的小片，随时响应 Ctrl+C。

    用法：
        if not sleep_interruptible(10):   # 返回 False = 等待期间被中断
            break
    为什么不用 time.sleep(10)：那样 Ctrl+C 会被延迟到整段睡完才生效，
    而这里最多 0.2 秒就能停下，方便及时断电。
    用 time.monotonic() 而不是 time.time()，避免系统时钟被调整导致计时错乱。
    """
    deadline = time.monotonic() + max(0.0, seconds)
    while True:
        if _STOP:
            return False
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return True
        time.sleep(min(0.2, remaining))


def default_csv_path(cfg):
    """生成默认 CSV 路径：_logs_dir/measurements_年月日_时分秒.csv

    用法：path = default_csv_path(cfg)   # 用户没指定 measurement.csv_file 时用
    """
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return os.path.join(cfg["_logs_dir"], f"measurements_{stamp}.csv")


def print_plan(cfg, config_path):
    """干跑模式下打印一份“执行计划”，让人先确认参数再真跑。

    用法：print_plan(cfg, "E:/xxx/config.yaml")   # 无返回值，直接打印
    """
    test = cfg["test"]
    ser = cfg["serial"]
    cycles = test["cycles"]
    port = ser["port"]
    print()
    print("=" * 68)
    print("执行计划（干跑模式：不连接电源，仅校验配置）")
    print("=" * 68)
    print(f"配置文件    : {config_path}")
    print(f"传输方式    : {cfg['transport']}")
    print(f"串口        : {port} @ {ser['baudrate']} {ser['bytesize']}{ser['parity']}"
          f"{int(ser['stopbits']) if float(ser['stopbits']).is_integer() else ser['stopbits']}")
    print(f"电压 / 电流 : {test['voltage']:g} V / {test['current']:g} A")
    print(f"上电保持    : {test['on_time']:g} 秒")
    print(f"断电间隔    : {test['off_time']:g} 秒")
    print(f"循环次数    : {cycles if cycles else '无限（Ctrl+C 结束）'}")
    if test["settle_time"]:
        print(f"稳定等待    : {test['settle_time']:g} 秒后测量")
    if cycles:
        estimate = cycles * test["on_time"] + max(0, cycles - 1) * test["off_time"]
        print(f"预计耗时    : {fmt_duration(estimate)}（不含测量与通信开销）")
    if cfg["measurement"]["enabled"]:
        print(f"测量记录    : 开启，CSV = {default_csv_path(cfg)}")
    else:
        print("测量记录    : 关闭")
    safety = cfg["safety"]
    limits = []
    if safety["max_voltage"] > 0:
        limits.append(f"电压 ≤ {safety['max_voltage']:g} V")
    if safety["max_current"] > 0:
        limits.append(f"电流 ≤ {safety['max_current']:g} A")
    print(f"安全上限    : {'，'.join(limits) if limits else '未设置（safety 中可配置）'}")
    print("=" * 68)
    print()


def run_test(ps, cfg, log):
    """核心循环：反复执行「设电压电流 → 上电 → 等待 → 测量 → 断电 → 间隔」。

    用法：rc = run_test(ps, cfg, log)   # 返回 EXIT_OK / EXIT_RUNTIME / EXIT_INTERRUPTED
    单次循环时间线（以 on_time=10、settle=0.5、off_time=10 为例）：
        0.0s  设 VOLT/CURR → OUTP ON
        0.5s  测量（等 settle_time 让输出稳定）
        10.0s OUTP OFF
        20.0s 进入下一次循环
    容错设计：
      · 上电失败 → 立即中止（不敢在不确定状态下继续）；
      · 测量失败 → 只告警，不影响循环继续；
      · 断电失败 → 中止并输出醒目告警，提示人工检查（防止被测设备一直带电）；
      · 任意时刻 Ctrl+C → 走 shutdown() 安全断电后退出。
    """
    test = cfg["test"]
    total = int(test["cycles"])
    volts = float(test["voltage"])
    amps = float(test["current"])
    on_time = float(test["on_time"])
    off_time = float(test["off_time"])
    settle = float(test["settle_time"])
    measure_enabled = bool(cfg["measurement"]["enabled"])

    # 需要记录测量数据时，打开 CSV（用户指定了 csv_file 就用它，否则自动命名）
    csv_writer = None
    if measure_enabled and cfg["measurement"]["csv"]:
        path = cfg["measurement"]["csv_file"] or default_csv_path(cfg)
        csv_writer = MeasurementCsv(path)
        log(f"测量数据写入: {path}")

    done = 0
    started = time.monotonic()   # 用单调时钟统计总耗时
    aborted = False

    # total == 0 表示无限循环，靠 Ctrl+C（_STOP）结束
    while total == 0 or done < total:
        if _STOP:
            break
        cycle = done + 1
        label = f"{cycle}/{total}" if total else f"{cycle}/∞"
        log("")
        log(f"----- 第 {label} 次循环：上电 {volts:g} V / {amps:g} A -----")

        # 阶段 1：设定参数并上电。失败即中止，不做任何重试冒险
        try:
            ps.set_voltage(volts)
            ps.set_current(amps)
            ps.output(True)
        except ScpiError as exc:
            log(f"上电失败，测试中止: {exc}", "ERROR")
            aborted = True
            break

        # 阶段 2：等输出稳定后测量（settle 不会超过 on_time，已在 validate 里保证）
        powered_at = time.monotonic()
        if settle > 0:
            sleep_interruptible(min(settle, on_time))

        measurement = None
        if measure_enabled and not _STOP:
            try:
                measurement = ps.measure()
                log(
                    f"测量: {measurement[0]:.3f} V, {measurement[1]:.3f} A, "
                    f"{measurement[0] * measurement[1]:.3f} W"
                )
            except Exception as exc:  # noqa: BLE001 - 测量失败不应中断测试
                log(f"测量失败（已忽略）: {exc}", "WARN")

        # 阶段 3：补足剩余的上电保持时间（扣掉设定参数和测量花掉的时间，
        #         保证“实际带电时长”尽量贴近 on_time）
        remaining = on_time - (time.monotonic() - powered_at)
        if remaining > 0:
            sleep_interruptible(remaining)

        # 阶段 4：断电。这是最关键的一步，失败要大声告警
        off_failed = False
        try:
            ps.output(False)
            if total == 0 or cycle < total:
                log(f"已断电，间隔 {off_time:g} 秒")
            else:
                log("已断电")
        except ScpiError as exc:
            log(f"断电命令失败: {exc}，请立即人工检查电源！", "ERROR")
            off_failed = True

        if csv_writer and measurement:
            try:
                csv_writer.add(cycle, *measurement)
            except OSError as exc:
                log(f"写入 CSV 失败: {exc}", "WARN")

        # 阶段 5：写 CSV、计数、判断是否继续
        done += 1
        if off_failed:          # 断电都没成功，绝不能继续下一轮
            aborted = True
            break
        if total and done >= total:   # 达到指定循环次数，正常收尾
            break
        if _STOP:
            break
        if not sleep_interruptible(off_time):   # 最后一轮不需要再等间隔
            break

    elapsed = time.monotonic() - started
    if csv_writer:
        csv_writer.close()

    # 三种退出结果对应不同退出码，方便外部脚本判断
    if _STOP:
        log(f"测试被中断，已执行 {done} 次上电循环，耗时 {fmt_duration(elapsed)}", "WARN")
        return EXIT_INTERRUPTED
    if aborted or (total and done < total):
        log(f"测试异常结束：完成 {done}/{total if total else '∞'} 次循环", "ERROR")
        return EXIT_RUNTIME
    log(f"测试完成：共 {done} 次循环，耗时 {fmt_duration(elapsed)}", "INFO")
    return EXIT_OK


def shutdown(ps, log):
    """收尾：无论测试成功还是异常，都保证「先断电，再切本地，最后放串口」。

    用法：在主流程的 finally 里调用 shutdown(ps, log)
    这是整个脚本最重要的安全兜底——就算中途抛异常、用户 Ctrl+C，
    也会走到这里把输出关掉，避免被测设备长时间带电。
    每一步都单独 try/except，保证某个动作失败不影响后续清理。
    """
    try:
        if ps.connected:
            try:
                ps.output(False)
                log("已确认输出关闭")
            except Exception as exc:  # noqa: BLE001
                log(f"关闭输出失败，请人工确认电源状态！({exc})", "ERROR")
            if ps.scpi.get("local_enable"):
                try:
                    ps.send(ps.scpi["local_enable"], critical=False)
                except Exception:  # noqa: BLE001
                    pass
    finally:
        try:
            ps.close()
        except Exception:  # noqa: BLE001
            pass
        log("串口已释放")


def main():
    """程序总入口：读配置 → 准备日志 → 干跑/真跑 → 收尾。

    返回值直接作为进程退出码（sys.exit(main())）。
    """
    # 从 shell 侧导出的环境变量里取参数（内联脚本没有 argv）
    config_path = os.environ.get("PT_CONFIG", "config.yaml")
    dry_run = os.environ.get("PT_DRY_RUN", "0") == "1"
    cycles_override = os.environ.get("PT_CYCLES", "").strip()
    config_dir = os.path.dirname(os.path.abspath(config_path))

    # 步骤 1：加载并校验配置（出错退出码 2）
    try:
        cfg = load_config(config_path)
    except ConfigError as exc:
        print(f"[错误] 配置有误: {exc}", file=sys.stderr)
        return EXIT_CONFIG

    # 步骤 2：命令行 --cycles 覆盖配置里的循环次数（0 = 无限）
    if cycles_override:
        try:
            cycles = int(cycles_override)
        except ValueError:
            print("[错误] --cycles 必须是整数", file=sys.stderr)
            return EXIT_CONFIG
        if cycles < 0:
            print("[错误] --cycles 不能为负数", file=sys.stderr)
            return EXIT_CONFIG
        cfg["test"]["cycles"] = cycles

    # 步骤 3：确定日志目录（相对路径时以配置文件所在目录为基准，而不是当前工作目录）
    logs_dir = cfg["logging"]["dir"]
    if not os.path.isabs(logs_dir):
        logs_dir = os.path.join(config_dir, logs_dir)
    cfg["_logs_dir"] = logs_dir   # 存进 cfg，供 default_csv_path() 复用

    # 干跑不写日志文件，保持干净
    log_path = None
    if cfg["logging"]["file"] and not dry_run:
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        log_path = os.path.join(logs_dir, f"power_test_{stamp}.log")
    log = Logger(log_path)

    try:
        log("=" * 68)
        log(f"艾德克斯（ITECH）电源自动上下电测试 v1.0.0"
            f"{'   [干跑]' if dry_run else ''}")
        log(f"配置文件: {config_path}")

        # 干跑分支：打印计划后直接结束（不建通信对象、不开串口）
        if dry_run:
            print_plan(cfg, config_path)
            return EXIT_OK

        # 注册信号：Ctrl+C → SIGINT，`kill <pid>` → SIGTERM，都只是置 _STOP，
        # 由主循环自己安全退出（Windows 没有 SIGTERM，所以包了 try）
        signal.signal(signal.SIGINT, request_stop)
        try:
            signal.signal(signal.SIGTERM, request_stop)
        except (AttributeError, ValueError):
            pass

        ps = PowerSupply(cfg, log)
        rc = EXIT_OK
        try:
            ps.connect()
            rc = run_test(ps, cfg, log)
        # 按异常类型映射退出码，外部脚本可据此区分“配置错/连不上/运行错”
        except ConfigError as exc:
            log(f"配置错误: {exc}", "ERROR")
            rc = EXIT_CONFIG
        except ConnectError as exc:
            log(f"连接失败: {exc}", "ERROR")
            rc = EXIT_CONNECT
        except ScpiError as exc:
            log(f"通信错误: {exc}", "ERROR")
            rc = EXIT_RUNTIME
        except KeyboardInterrupt:
            log("收到 Ctrl+C，正在安全断电...", "WARN")
            rc = EXIT_INTERRUPTED
        except Exception as exc:  # noqa: BLE001
            log(f"未预期的错误: {exc}", "ERROR")
            rc = EXIT_RUNTIME
        finally:
            # 无论上面走哪条分支，都要执行安全收尾（断电 + 释放串口）
            shutdown(ps, log)
        return rc
    finally:
        log.close()   # 关闭日志文件句柄


# 入口：main() 的返回值就是进程退出码
if __name__ == "__main__":
    sys.exit(main())
PYCODE
# ↑ heredoc 结束标记（必须顶格写，前面不能有空格）。
#   执行完这段 Python 后，脚本的退出码就是 Python 的退出码，
#   由 shell 的 `set -e` 直接透传给调用方。
