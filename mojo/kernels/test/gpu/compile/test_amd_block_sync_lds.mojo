# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug-no-assert %s | FileCheck %s
# RUN: %mojo-no-debug-no-assert -D USE_EXPERIMENTAL_AMD_BLOCK_SYNC_LDS_WITHOUT_SYNC_VMEM=True %s | FileCheck --check-prefix=CHECK-BLOCK-SYNC %s

from gpu import barrier
from gpu.host._compile import _compile_code_asm
from gpu.host.info import MI300X

alias MI300X_TARGET = MI300X.target()


# CHECK-LABEL: test_barrier
def test_barrier():
    print("== test_barrier")

    fn barrier_kernel():
        barrier()

    # CHECK: fence syncscope("workgroup") release
    # CHECK: tail call void @llvm.amdgcn.s.barrier()
    # CHECK: fence syncscope("workgroup") acquire

    # CHECK-BLOCK-SYNC: tail call void @llvm.amdgcn.s.waitcnt(i32 49279)
    # CHECK-BLOCK-SYNC: tail call void @llvm.amdgcn.s.barrier()
    print(
        _compile_code_asm[
            barrier_kernel, target=MI300X_TARGET, emission_kind="llvm-opt"
        ]()
    )


def main():
    test_barrier()
