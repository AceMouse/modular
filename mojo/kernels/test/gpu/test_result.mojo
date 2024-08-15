# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo %s

from gpu.host import Result
from testing import assert_equal


def test_result():
    assert_equal(str(Result.SUCCESS), "SUCCESS")
    assert_equal(str(Result.ALREADY_ACQUIRED), "ALREADY_ACQUIRED")
    assert_equal(str(Result(3333333)), "<UNKNOWN>")


def main():
    test_result()
