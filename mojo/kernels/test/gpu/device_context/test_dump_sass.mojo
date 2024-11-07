# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s

from pathlib import Path
from sys._assembly import inlined_assembly

from gpu.host import DeviceContext

alias ptxas_path = Path("/usr/local/cuda/bin/ptxas")
alias nvdisasm_path = Path("/usr/local/cuda/bin/nvdisasm")


def test__dump_sass():
    fn kernel_inlined_assembly():
        inlined_assembly["nanosleep.u32 $0;", NoneType, constraints="r"](
            UInt32(100)
        )

    # CHECK: NANOSLEEP 0x64
    with DeviceContext() as ctx:
        _ = ctx.compile_function[kernel_inlined_assembly, _dump_sass=True]()


def main():
    if ptxas_path.exists() and nvdisasm_path.exists():
        test__dump_sass()
