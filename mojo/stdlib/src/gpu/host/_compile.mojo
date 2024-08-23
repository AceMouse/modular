# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Implements CUDA compilation operations."""

from os import abort
import subprocess
import tempfile
from pathlib import Path
from compile import Info, compile_info, get_linkage_name
from .info import _get_info_from_target

# ===----------------------------------------------------------------------===#
# Targets
# ===----------------------------------------------------------------------===#


@always_inline
fn _get_nvptx_target[
    # TODO: Ideally this is an Optional[StringLiteral] but blocked by MOCO-1039
    target_arch: StringLiteral = "sm_80",
]() -> __mlir_type.`!kgen.target`:
    alias info = _get_info_from_target[target_arch]()
    return info.target


# ===----------------------------------------------------------------------===#
# Compilation
# ===----------------------------------------------------------------------===#


@always_inline
fn _compile_code[
    func_type: AnyTrivialRegType, //,
    func: func_type,
    /,
    *,
    emission_kind: StringLiteral = "asm",
    is_failable: Bool = False,
    target: __mlir_type.`!kgen.target` = _get_nvptx_target(),
]() -> Info:
    return compile_info[
        func,
        emission_kind=emission_kind,
        is_failable=is_failable,
        target=target,
    ]()


fn _get_nvptx_fn_name[
    func_type: AnyTrivialRegType, //, func: func_type
]() -> StringLiteral:
    return get_linkage_name[_get_nvptx_target(), func]()


fn _get_arch[target: __mlir_type.`!kgen.target`]() -> String:
    return __mlir_attr[
        `#kgen.param.expr<target_get_field,`,
        target,
        `, "arch" : !kgen.string`,
        `> : !kgen.string`,
    ]


@no_inline
fn _to_sass[
    target: __mlir_type.`!kgen.target` = _get_nvptx_target()
](asm: String, *, nvdisasm_opts: String = "") raises -> String:
    alias ptxas_path = Path("/usr/local/cuda/bin/ptxas")
    alias nvdisasm_path = Path("/usr/local/cuda/bin/nvdisasm")
    if not ptxas_path.exists():
        raise "the `ptxas` binary does not exist in '" + str(ptxas_path) + "'"
    if not nvdisasm_path.exists():
        raise "the `nvdisasm` binary does not exist in '" + str(
            nvdisasm_path
        ) + "'"
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmpdir:
        var ptx_file = Path(tmpdir) / "output.ptx"
        var elf_file = Path(tmpdir) / "output.elf"
        ptx_file.write_text(asm)
        _ = subprocess.run(
            str(ptxas_path)
            + " --gpu-name "
            + _get_arch[target]()
            + " -O3 "
            + str(ptx_file)
            + " -o "
            + str(elf_file)
        )
        return subprocess.run(
            str(nvdisasm_path) + " -c " + nvdisasm_opts + " " + str(elf_file)
        )
    return ""
