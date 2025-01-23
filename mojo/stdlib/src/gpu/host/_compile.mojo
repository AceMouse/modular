# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Implements CUDA compilation operations."""

import subprocess
import tempfile
from collections import Optional
from os import abort
from pathlib import Path
from sys.info import _get_arch

from compile import Info, compile_info, get_linkage_name

from .info import A100, DEFAULT_GPU_ARCH
from .info import Info as HardwareInfo
from .info import _get_info_from_target

# ===-----------------------------------------------------------------------===#
# Targets
# ===-----------------------------------------------------------------------===#


@always_inline
fn _get_gpu_target[
    # TODO: Ideally this is an Optional[StringLiteral] but blocked by MOCO-1039
    target_arch: StringLiteral = DEFAULT_GPU_ARCH,
]() -> __mlir_type.`!kgen.target`:
    alias info = HardwareInfo.from_name[target_arch]() if target_arch else A100
    return info.target()


# ===-----------------------------------------------------------------------===#
# Compilation
# ===-----------------------------------------------------------------------===#


@always_inline
fn _compile_code[
    func_type: AnyTrivialRegType, //,
    func: func_type,
    /,
    *,
    emission_kind: StringLiteral = "asm",
    target: __mlir_type.`!kgen.target` = _get_gpu_target(),
    compile_options: StringLiteral = HardwareInfo.from_target[
        target
    ]().compile_options,
]() -> Info[func_type, func]:
    return compile_info[
        func,
        emission_kind=emission_kind,
        compile_options=compile_options,
        target=target,
    ]()


@always_inline
fn _compile_code_asm[
    func_type: AnyTrivialRegType, //,
    func: func_type,
    /,
    *,
    emission_kind: StringLiteral = "asm",
    target: __mlir_type.`!kgen.target` = _get_gpu_target(),
    compile_options: StringLiteral = HardwareInfo.from_target[
        target
    ]().compile_options,
]() -> StringLiteral:
    var asm = compile_info[
        func,
        emission_kind=emission_kind,
        compile_options=compile_options,
        target=target,
    ]().asm
    return asm


# ===-----------------------------------------------------------------------===#
# _to_sass
# ===-----------------------------------------------------------------------===#


@no_inline
fn _to_sass[
    target: __mlir_type.`!kgen.target` = _get_gpu_target()
](asm: String, *, nvdisasm_opts: String = "") raises -> String:
    alias nvdisasm_path = Path("/usr/local/cuda/bin/nvdisasm")
    if not nvdisasm_path.exists():
        raise String(
            "the `nvdisasm` binary does not exist in '", nvdisasm_path, "'"
        )
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmpdir:
        var elf_file = Path(tmpdir) / "output.elf"
        _ = _ptxas_compile(
            asm,
            output_file=elf_file,
        )
        return subprocess.run(
            String(nvdisasm_path, " -ndf -c ", nvdisasm_opts, " ", elf_file)
        )
    return ""


# ===-----------------------------------------------------------------------===#
# _ptxas_compile
# ===-----------------------------------------------------------------------===#


@no_inline
fn _ptxas_compile[
    target: __mlir_type.`!kgen.target` = _get_gpu_target()
](
    asm: String, *, options: String = "", output_file: Optional[Path] = None
) raises -> String:
    alias ptxas_path = Path("/usr/local/cuda/bin/ptxas")
    if not ptxas_path.exists():
        raise String("the `ptxas` binary does not exist in '", ptxas_path, "'")
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmpdir:
        var ptx_file = Path(tmpdir) / "output.ptx"
        var elf_file = Path(tmpdir) / "output.elf"
        ptx_file.write_text(asm)
        return subprocess.run(
            String(
                ptxas_path,
                " --gpu-name ",
                _get_arch[target](),
                " -O3 ",
                ptx_file,
                " ",
                options,
                " -o ",
                output_file.or_else(elf_file),
            )
        )
    return ""
