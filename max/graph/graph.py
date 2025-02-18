# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Core graph primitives."""

from __future__ import annotations

import contextlib
import inspect
import traceback
from contextvars import ContextVar
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Optional

from max import mlir
from max._core import graph as _graph
from max.mlir.dialects import mo

from .type import (
    BufferType,
    DeviceKind,
    DeviceRef,
    Dim,
    SymbolicDim,
    TensorType,
    Type,
)
from .value import TensorValue, Value, _ChainValue
from .weight import Weight

CURRENT_GRAPH: ContextVar[Graph] = ContextVar("CURRENT_GRAPH")


class KernelLibrary:
    def __init__(self, context: mlir.Context, path: Path):
        self._analysis = _graph.Analysis(context, [path])
        self._kernels = set(self._analysis.symbol_names)

    def __getitem__(self, kernel: str):
        if kernel not in self._kernels:
            raise KeyError(kernel)
        return self._analysis.kernel(kernel)

    def __contains__(self, kernel: str):
        return kernel in self._kernels

    def __iter__(self):
        yield from sorted(self._kernels)


# From https://stackoverflow.com/a/76301341
class _classproperty:
    def __init__(self, func):
        self.fget = func

    def __get__(self, instance, owner):
        return self.fget(owner)


@dataclass(frozen=True)
class _GraphWeight:
    weight: Weight
    value: TensorValue


def _new_context() -> mlir.Context:
    registry = mlir.DialectRegistry()
    _graph.load_modular_dialects(registry)

    context = mlir.Context()
    context.append_dialect_registry(registry)
    context.load_all_available_dialects()

    return context


class Graph:
    """Represents a single MAX graph.

    A `Graph` is a callable routine in [MAX Engine](/max/engine). Like
    functions, graphs have a name and signature. Unlike a function, which
    follows an imperative programming model, a `Graph` follows a
    [dataflow](https://en.wikipedia.org/wiki/Dataflow_programming) programming
    model, using lazily-executed, parallel operations instead of sequential
    instructions.

    When you instantiate a graph, you must specify the input shapes
    as one or more :obj:`TensorType` values. Then, build a
    sequence of ops and set the graph output with :obj:`output()`. For
    example:

    .. code-block:: python

        from dataclasses import dataclass

        import numpy as np
        from max.dtype import DType
        from max.graph import Graph, TensorType, TensorValue, ops

        @dataclass
        class Linear:
            weight: np.ndarray
            bias: np.ndarray

            def __call__(self, x: TensorValue) -> TensorValue:
                weight_tensor = ops.constant(self.weight, dtype=DType.float32)
                bias_tensor = ops.constant(self.bias, dtype=DType.float32)
                return ops.matmul(x, weight_tensor) + bias_tensor

        linear_graph = Graph(
            "linear",
            Linear(np.ones((2, 2)), np.ones((2,))),
            input_types=[TensorType(DType.float32, (2,))]
        )

    You can't call a `Graph` directly from Python. You must compile it and
    execute it with MAX Engine. For more detail, see the tutorial about how to
    [build a graph with MAX Graph](/max/tutorials/get-started-with-max-graph).

    When creating a graph, a global sequence of chains is initialized and stored
    in Graph._current_chain. Every side-effecting op, e.g. buffer_load,
    store_buffer, load_slice_buffer, store_slice_buffer, will use the current
    chain to perform the op and and update Graph._current_chain with a new
    chain. Currently, the input/output chains for mutable ops can be used at
    most once. The goal of this design choice is to prevent data races.
    """

    _input_types: list[Type]
    # Use a dict rather than a set to keep params ordered.
    # This is to make IR generation deterministic for model IR cache hits.
    # Note that insertion order in built-in dict has been guaranteed since
    # Python 3.7.
    _params: dict[str, None]
    _mlir_op: mlir.Operation | mlir.OpView
    _context: mlir.Context
    _module: mlir.Module
    _unique_symbolic_dim_counter: int
    _context_state: list
    inputs: tuple[Value, ...]
    _weights: dict[str, _GraphWeight]
    # A global sequence of chains that is updated by side-effecting ops.
    _current_chain: _ChainValue

    def __init__(
        self,
        name: str,
        forward: Optional[Callable] = None,
        input_types: Iterable[Type] = (),
        path: Optional[Path] = None,
        *args,
        context: Optional[mlir.Context] = None,
        **kwargs,
    ) -> None:
        self.name = name
        if path is not None:
            self._load_mlir(path)
            return

        self._input_types = list(input_types)
        self._params = dict.fromkeys(
            dim.name
            for t in input_types
            if isinstance(t, (TensorType, BufferType))
            for dim in t.shape
            if isinstance(dim, SymbolicDim)
        )
        self._unique_symbolic_dim_counter = 0
        self._context_state = []
        self._context = context or _new_context()

        with self._context, self._location() as loc:
            # Create the top level module op.
            self._module = mlir.Module.create()

            with mlir.InsertionPoint(self._module.body):
                # Initially create the function type with blank output types --
                # we'll fill it out later when output() is called.
                function_type = mlir.FunctionType.get(
                    [t.to_mlir() for t in input_types], []
                )
                # Call the C++ builder to build the MO graph op.
                self._mlir_op = _graph.graph(
                    self._module, loc, name, function_type
                )
        param_decl = _graph.dim_param_decl_array_attr(
            self._context,
            [
                _graph.dim_param_decl_attr(self._context, p)
                for p in self._params
            ],
        )
        self._mlir_op.attributes["inputParams"] = param_decl

        self.inputs = tuple(Value(arg) for arg in self._body.arguments)  # type: ignore
        self._weights = {}

        initial_chain = self._add_op(mo.chain_create, [])[0]
        assert isinstance(initial_chain, _ChainValue)
        self._current_chain = initial_chain

        if forward is not None:
            # If the forward method was passed stage the graph directly in the
            # constructor.
            with self:
                result = forward(*self.inputs, *args, **kwargs)
                # Account for forward methods that return None, a single
                # output, or multiple outputs.
                outputs = (
                    ()
                    if result is None
                    else (result,)
                    if not isinstance(result, Iterable)
                    else result
                )
                self.output(*outputs)

    def _update_chain(self, new_chain: _ChainValue) -> None:
        self._current_chain = new_chain

    def __enter__(self) -> Graph:
        self._context_state.append(state := self._enter())
        return state.__enter__()

    def __exit__(self, *exc):
        self._context_state.pop().__exit__(*exc)

    @contextlib.contextmanager
    def _enter(self):
        token = CURRENT_GRAPH.set(self)
        try:
            with self._context:
                yield self
        finally:
            CURRENT_GRAPH.reset(token)

    @contextlib.contextmanager
    def _capturing_mlir_diagnostics(self):
        diagnostics = []

        def handler(d):
            diagnostics.append(str(d))
            return True

        # Temporarily hookup a handler to record diagnostics from mlir.
        # These are used to generate a better error message on failure.
        handle = self._context.attach_diagnostic_handler(handler)
        try:
            yield None
        except (mlir.MLIRError, ValueError) as e:  # type: ignore
            # MLIRError is raised from the MLIR Python bindings on MLIR
            # errors, however so is ValueError when operation create fails.
            # So catch both exception types and report diagnostics here.
            diags = "\n  ".join(diagnostics)
            raise ValueError(f"Diagnostics:\n    {diags}\n{e}") from None
        finally:
            handle.detach()

    @_classproperty
    def current(cls) -> Graph:
        try:
            current = CURRENT_GRAPH.get()
        except LookupError as exc:
            raise LookupError("No graph found") from exc
        assert current
        return current

    @property
    def _body(self) -> mlir.Block:
        return self._mlir_op.regions[0].blocks[0]

    def _add_op(self, op, *args, **kwargs) -> list[Value]:
        """Wrapper for clients that only require the op results."""
        results, _ = self._add_op_get_op_with_results(op, *args, **kwargs)
        return results

    def _add_op_get_op_with_results(
        self, op, *args, **kwargs
    ) -> tuple[list[Value], mlir.OpView]:
        # Convert args from instances of Python graph-api Value() to mlir.Value
        def unwrap(arg):
            if isinstance(arg, Value):
                return arg._mlir_value
            if isinstance(arg, list):
                return [unwrap(elem) for elem in arg]
            else:
                return arg

        unwrapped_args = tuple(unwrap(arg) for arg in args)
        unwrapped_kwargs = {k: unwrap(arg) for k, arg in kwargs.items()}

        # Construct and insert an op in the body of the graph
        # Insertion point is where the op is to be created in the IR structure
        # location contains info about the source of the op (e.g. file, line)
        with mlir.InsertionPoint(self._body), self._location():
            try:
                with self._capturing_mlir_diagnostics():
                    # Insert op at the end of self._body, location set up by
                    # the context manager.
                    results = op(*unwrapped_args, **unwrapped_kwargs)
            except (mlir.MLIRError, ValueError) as e:  # type: ignore
                # MLIRError is raised from the MLIR Python bindings on MLIR
                # errors, however so is ValueError when operation create faile.
                # So catch both exception types here.
                mapped_args: dict[str, Any]
                try:
                    mapped_args = (
                        inspect.signature(op).bind(*args, **kwargs).arguments
                    )
                except TypeError:
                    mapped_args = {"args": list(args), **kwargs}
                raise ValueError(
                    f"Failed to create op '{op.__qualname__}':\nInputs:\n"
                    + "".join(
                        f"    {k} = {v!r}\n" for k, v in mapped_args.items()
                    )
                    + f"\n{e}"
                    # Intentionally suppress extra stack traces from max._mlir.
                ) from None

        # Get the op we just staged, which is the last op in the body block.
        ops = self._body.operations
        staged_op = ops[len(ops) - 1]

        if isinstance(results, (mlir.Operation, mlir.OpView)):
            return [], staged_op

        # Convert op results from  mlir.Value to instances of Value graph-api
        if isinstance(results, mlir.Value):
            results = [Value(results)]
        else:
            results = [Value(result) for result in results]

        # Add symbolic dims of tensor results to the list of graph params and
        # declared output params of the op
        # Use a dict as an ordered set for new param decls. Maps keys to None.
        new_params: dict[str, None] = dict()
        for result in results:
            t = result._mlir_value.type
            if not _graph.type_is_tensor(t):
                continue

            rank = _graph.tensor_type_get_rank(t)
            for i in range(rank):
                try:
                    dim = Dim.from_mlir(_graph.tensor_type_get_dim(t, i))
                    if isinstance(dim, SymbolicDim):
                        new_params[dim.name] = None
                except:
                    continue

        # Track any newly declared parameters.
        new_params = dict.fromkeys(new_params.keys() - self._params.keys())
        self._params.update(new_params)
        if new_params:
            # Add the output params to the op we just created.
            param_decl = _graph.dim_param_decl_array_attr(
                self._context,
                [
                    _graph.dim_param_decl_attr(self._context, p)
                    for p in new_params
                ],
            )
            staged_op.attributes["outputParamDecls"] = param_decl

        return results, staged_op

    def output(self, *outputs: Value) -> None:
        """Sets the output nodes of the :obj:`Graph`."""
        # mo.output doesn't support infer_type
        mlir_values = [o._mlir_value for o in outputs]
        self._add_op(mo.output, mlir_values)
        # We have a type mismatch now, these are MLIR types
        output_types = [value.type for value in mlir_values]
        # Need to set some more stuff.
        function_type = mlir.FunctionType.get(
            [t.to_mlir() for t in self._input_types],
            output_types,
        )
        signature = mlir.Type.parse(f"!kgen.generator<{function_type}>")
        self._mlir_op.attributes["signature"] = mlir.TypeAttr.get(signature)
        self._mlir_op.attributes["functionType"] = mlir.TypeAttr.get(
            function_type
        )

        # Set the result_names metadata on the staged op, which is needed by
        # the engine for execution.
        # Note that result_names here needs to match kMgpModelResultNames.
        output_names = [f'"output{i}"' for i in range(len(output_types))]
        self._mlir_op.attributes["result_names"] = mlir.Attribute.parse(
            f"[{', '.join(output_names)}]"
        )

        # Outputting means the graph is complete. Verify the entire graph.
        try:
            with self._capturing_mlir_diagnostics():
                assert self._mlir_op.verify()
        except Exception as e:
            raise ValueError(
                "Graph failed to verify. Please file an issue. This should be"
                " impossible." + f"\n{e}"
            ) from None

    def _load_mlir(self, path: Path):
        self._unique_symbolic_dim_counter = 0
        self._context_state = []
        with open(path) as f:
            registry = mlir.DialectRegistry()
            _graph.load_modular_dialects(registry)

            self._context = mlir.Context()
            self._context.append_dialect_registry(registry)
            self._context.load_all_available_dialects()

            with self._context, self._location() as loc:
                # Create the top level module op.
                self._module = mlir.Module.create()
                with mlir.InsertionPoint(self._module.body):
                    self._module = self._module.parse(f.read(), self._context)
                    # Set the mo.graph op, which is the first operation in the
                    # module body block.
                    self._mlir_op = self._module.body.operations[0]

    def add_weight(
        self, weight: Weight, device: DeviceRef | None = None
    ) -> TensorValue:
        """Adds a weight to the graph.

        If the weight is in the graph already, return the existing value.

        Args:
            weight: The weight to add to the graph.
            device: The device that the weight is placed on before passing the
                weight to the graph.

        Returns:
            A :obj:`TensorValue` that contains this weight.

        Raises:
            ValueError: If a weight with the same name already exists in the graph.
        """
        if graph_weight := self._weights.get(weight.name):
            if graph_weight.weight is weight:
                return graph_weight.value
            else:
                raise ValueError(
                    f"Weight '{weight.name}' already exists in Graph {self}"
                )

        tensor_type = TensorType(
            weight.dtype, weight.shape, device=device
        ).to_mlir()
        weight_tensor = Graph.current._add_op(
            mo.constant_external,
            result=tensor_type,
            name=weight.name,
            align=(
                # Default to dtype alignment unless otherwise specified, for
                # example by checkpoint metadata.
                weight.align if weight.align is not None else weight.dtype.align
            ),
        )[0]

        # Set the constant external op's device explicitly to the passed device.
        # This is needed to prevent AssignDevices from automatically assigning
        # mo.constant.external to the default device, which could differ from
        # the passed device (for example default is GPU, passed weights on CPU).
        const_external_op = weight_tensor._mlir_value.owner
        const_external_op.attributes["device"] = (
            device if device is not None else DeviceRef(DeviceKind.CPU, 0)
        ).to_mlir()

        self._weights[weight.name] = _GraphWeight(weight, weight_tensor)
        return weight_tensor

    def __repr__(self) -> str:
        return str(self._mlir_op)

    def unique_symbolic_dim(self, tag: str) -> SymbolicDim:
        """Create a new symbolic dim with a different name from any other.

        Args:
            tag: An additional identifier to help identify the dimension for debugging purposes.

        Returns:
            The dimension.
        """
        while True:
            name = f"unique_{tag}_{self._unique_symbolic_dim_counter}"
            self._unique_symbolic_dim_counter += 1
            if name not in self._params:
                break
        return SymbolicDim(name)

    def _location(self):
        """Creates an MLIR Location with the current Python call stack."""
        if not mlir.Context.current:
            raise RuntimeError("Can't create location: No MLIR context active")

        # Originally this was capturing the current stack frame. It was really
        # fast, but lead to some major issues due to the current frame keeping
        # local variables alive. Instead we extract the stack into summaries.
        # This is a bit slower, but still plenty fast (3s llama3 graph build
        # time vs 2s with current frame). It also avoids any references cycles
        # and is cleaned up properly.

        # Remove the last 2 elements from the stack to get rid of `_location()`
        # and `_add_op()`.
        tb = traceback.extract_stack()[:-2]
        if not tb:
            return mlir.Location.unknown()

        return _graph.frame_loc(mlir.Context.current, tb)

    def import_kernels(self, path: Path) -> KernelLibrary:
        return KernelLibrary(self._context, path)
