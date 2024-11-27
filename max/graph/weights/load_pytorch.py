# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Function for importing a PyTorch checkpoint into a MAX Graph."""

from __future__ import annotations

import pickle
from dataclasses import dataclass
from io import BytesIO
from os import PathLike
from typing import Any, Optional, Tuple

import numpy as np
import numpy.typing as npt

try:
    import torch  # type: ignore
except ImportError:
    torch = None

from max.dtype import DType

from ..quantization import QuantizationEncoding
from ..type import ShapeLike
from ..weight import Weight


def _dtype_from_torch(dtype) -> DType:
    torch_to_dtype = {
        torch.bool: DType.bool,
        torch.int8: DType.int8,
        torch.int16: DType.int16,
        torch.int32: DType.int32,
        torch.int64: DType.int64,
        torch.uint8: DType.uint8,
        # torch.uint16: DType.uint16,  # Pytorch doesn't support these uint dtypes.
        # torch.uint32: DType.uint32,
        # torch.uint64: DType.uint64,
        torch.float16: DType.float16,
        torch.float32: DType.float32,
        torch.float64: DType.float64,
        torch.bfloat16: DType.bfloat16,
    }

    return torch_to_dtype[dtype]


@dataclass
class TensorInfo:
    dtype: Any  # torch.dtype
    offset: int
    shape: Tuple[int, ...]


class WeightUnpickler(pickle.Unpickler):
    def __init__(self, pkl_file, zip_file):
        super().__init__(pkl_file)
        self.zip_file = zip_file

    def build_tensor(
        self,
        zip_info,
        unused_storage_offset,
        size,
        *unused_args,
        **unused_kwargs,
    ):
        zip_info.shape = size
        return zip_info

    def find_class(self, module, name):
        if module == "torch._utils" and name == "_rebuild_tensor_v2":
            return self.build_tensor
        return super().find_class(module, name)

    def persistent_load(self, pid):
        data = pid[1:]
        storage_type, key, unused_location, unused_num_elements = data

        if storage_type is torch.UntypedStorage:
            dtype = torch.uint8
        else:
            dtype = storage_type.dtype

        name = f"data/{key}"
        offset = self.zip_file.get_record_offset(name)
        return TensorInfo(dtype=dtype, offset=offset, shape=())


class PytorchWeights:
    _filepath: PathLike
    _tensor_infos: dict[str, Any]
    _prefix: str
    _allocated: dict[str, np.ndarray]

    def __init__(
        self,
        filepath: PathLike,
        tensor_infos: Optional[dict[str, Any]] = None,
        prefix: str = "",
        allocated=None,
    ):
        if torch is None:
            raise ImportError(
                "Unable to import torch. Please make sure that PyTorch is"
                " installed on your system."
            )
        self._filepath = filepath
        if tensor_infos is not None:
            self._tensor_infos = tensor_infos
        else:
            zip_file = torch._C.PyTorchFileReader(str(filepath))
            with BytesIO(zip_file.get_record("data.pkl")) as pkl_file:
                unpickler = WeightUnpickler(pkl_file, zip_file)
                self._tensor_infos = unpickler.load()
        self._prefix = prefix
        self._allocated = {} if allocated is None else allocated

    @property
    def name(self) -> str:
        """The current weight name or prefix."""
        return self._prefix

    def items(self):
        """Iterate through allocable weights that start with the weight name."""
        for name in self._tensor_infos:
            if name.startswith(self._prefix):
                yield name, PytorchWeights(
                    self._filepath,
                    tensor_infos=self._tensor_infos,
                    prefix=name,
                    allocated=self._allocated,
                )

    def __getattr__(self, attr) -> PytorchWeights:
        if self._prefix:
            full_path = f"{self._prefix}.{attr}"
        else:
            full_path = str(attr)
        if not any(name.startswith(full_path) for name in self._tensor_infos):
            raise AttributeError(f"No weight {full_path} found")
        return PytorchWeights(
            self._filepath,
            tensor_infos=self._tensor_infos,
            prefix=full_path,
            allocated=self._allocated,
        )

    def __getitem__(self, idx: int | str) -> PytorchWeights:
        return self.__getattr__(str(idx))

    def raw_tensors(self):
        for name, tensor_info in self._tensor_infos.items():
            if name.startswith(self._prefix):
                yield tensor_info

    def raw_tensor(self) -> Any:
        """Returns the GGUF tensor corresponding to this weights object.

        Raises:
            KeyError if this weights object isn't a tensor.
        """
        if self._prefix not in self._tensor_infos:
            raise KeyError(
                f"Could not find weight named {self._prefix}. Please check that"
                " the name is correct."
            )

        return self._tensor_infos[self._prefix]

    def allocate(
        self,
        dtype: Optional[DType] = None,
        shape: Optional[ShapeLike] = None,
        quantization_encoding: Optional[QuantizationEncoding] = None,
    ) -> Weight:
        """Creates and optionally validates a new Weight."""
        if quantization_encoding:
            raise ValueError(
                f"Could not load quantized weight {self._prefix} from pytorch"
                " checkpoint:"
            )

        tensor_info = self.raw_tensor()
        weight = Weight(
            self._prefix,
            _dtype_from_torch(tensor_info.dtype),
            tensor_info.shape,
        )
        self._allocated[self._prefix] = np.memmap(
            self._filepath, mode="r", dtype=np.uint8, offset=tensor_info.offset
        )

        # Validate the loaded weight.
        shape_match = True
        dtype_match = True
        if shape is not None:
            expected_shape = tuple(shape)
            weight_unpacked_shape = tuple(dim for dim in weight.shape)
            shape_match = weight_unpacked_shape == expected_shape
        if dtype is not None:
            dtype_match = dtype == weight.dtype

        if not (shape_match and dtype_match):
            raise ValueError(
                "Did not get expected weight shape and/or dtype.\n\tExpected"
                f" dtype: {dtype}, got: {weight.dtype}\n\tExpected shape:"
                f" {expected_shape}, got: {weight_unpacked_shape}"
            )

        return weight

    @property
    def allocated_weights(self) -> dict[str, npt.NDArray]:
        """Gets the values of all weights that were allocated previously."""
        return self._allocated
