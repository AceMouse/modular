# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

import os
import platform

from lit.llvm import llvm_config

from modular.utils.subprocess import get_command_output

# Configuration file for the 'lit' test runner.


# name: The name of this test suite.
config.name = "Kernel benchmarks"

# suffixes: A list of file extensions to treat as test files.
config.suffixes = [".mojo"]

# test_source_root: The root path where tests are located.
config.test_source_root = os.path.dirname(__file__)

# test_exec_root: The root path where tests should be run.
config.test_exec_root = os.path.join(
    config.modular_obj_root, "Kernels", "benchmarks"
)

config.excludes.add("demos")
config.excludes.add("misc")
config.excludes.add("packages")


def has_gpu():
    if platform.system() != "Linux":
        return False

    try:
        get_command_output("cuda-query")
        return True
    except:
        return False


# Configuration file for the 'lit' test runner.
if has_gpu():
    config.available_features.add("has_cuda_device")


tool_dirs = [config.modular_tools_dir]
tools = ["mojo", "cuda-query"]

llvm_config.add_tool_substitutions(tools, tool_dirs)
