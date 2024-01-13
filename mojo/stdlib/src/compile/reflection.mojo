# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #


fn get_linkage_name[
    target: __mlir_type.`!kgen.target`, func_type: AnyRegType, func: func_type
]() -> StringLiteral:
    """Returns `func` symbol name.

    Parameters:
        target: The compilation target.
        func_type: Type of func.
        func: A mojo function.

    Returns:
        Symbol name.
    """
    return __mlir_attr[
        `#kgen.param.expr<get_linkage_name,`,
        target,
        `,`,
        func,
        `> : !kgen.string`,
    ]
