# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from math import iota
from sys import bitwidthof
from buffer import NDBuffer, DimList
from collections import OptionalReg

from builtin.dtype import _int_type_of_width, _uint_type_of_width

from utils.index import IndexList
from utils.numerics import min_or_neg_inf

# ===-----------------------------------------------------------------------===#
# TileMaskStatus
# ===-----------------------------------------------------------------------===#


@value
@register_passable("trivial")
struct TileMaskStatus(Stringable, Writable):
    """A tile's masking status."""

    var status: UInt8

    # No element is masked.
    alias NO_MASK = Self(0)

    # Some elements in the tile are masked.
    alias PARTIAL_MASK = Self(1)

    # All elements in the tile are masked.
    alias FULL_MASK = Self(3)

    fn __eq__(self, rhs: Self) -> Bool:
        return self.status == rhs.status

    fn __ne__(self, rhs: Self) -> Bool:
        return self.status != rhs.status

    fn __is__(self, rhs: Self) -> Bool:
        return self.status == rhs.status

    fn __is_not__(self, rhs: Self) -> Bool:
        return self.status != rhs.status

    fn __str__(self) -> String:
        return String.write(self)

    fn __and__(self, rhs: Self) -> Self:
        return Self(self.status & rhs.status)

    fn __or__(self, rhs: Self) -> Self:
        return Self(self.status | rhs.status)

    fn write_to[W: Writer](self, mut writer: W):
        if self is Self.NO_MASK:
            return writer.write("not masked")
        if self is Self.PARTIAL_MASK:
            return writer.write("partially masked")
        writer.write("fully masked")


# ===-----------------------------------------------------------------------===#
# MHAMask
# ===-----------------------------------------------------------------------===#


trait MHAMask:
    """The MHAMask trait describes masks for MHA kernels, such as the causal mask.
    """

    alias apply_log2e_after_mask: Bool

    fn mask[
        type: DType,
        width: Int, //,
        *,
        element_bitwidth: Int = bitwidthof[UInt32](),
        unsigned: Bool = True,
    ](
        self,
        coord: IndexList[
            4, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        score_vec: SIMD[type, width],
    ) -> SIMD[type, width]:
        """Return mask vector at given coordinates.

        Arguments:
          coord is (seq_id, head, q_idx, k_idx)
          score_vec is at `coord` of the score matrix

        The functor could capture an mask tensor and add to the score e.g. Replit.
        """
        ...

    fn status[
        *, element_bitwidth: Int = bitwidthof[UInt32](), unsigned: Bool = True
    ](
        self,
        tile_offset: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        tile_size: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
    ) -> TileMaskStatus:
        """Given a tile's index range, return its masking status."""
        ...


# ===-----------------------------------------------------------------------===#
# CausalMask
# ===-----------------------------------------------------------------------===#

alias MASK_VALUE = -10_000


@value
@register_passable("trivial")
struct CausalMask(MHAMask):
    """MHA causal mask ensures a token is only affected by previous tokens."""

    alias apply_log2e_after_mask: Bool = False

    @always_inline
    fn mask[
        type: DType,
        width: Int, //,
        *,
        element_bitwidth: Int = bitwidthof[UInt32](),
        unsigned: Bool = True,
    ](
        self,
        coord: IndexList[
            4, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        score_vec: SIMD[type, width],
    ) -> SIMD[type, width]:
        alias index_type = coord.element_type

        var masked_score_vec = score_vec

        # coord[2] and coord[3] are the token index in query and key respectively.
        var q_idx = SIMD[index_type, width](coord[2])
        var k_idx = SIMD[index_type, width](coord[3])

        # coords[2] >= coords[3] ensures the current tokens is only affected by
        # itself and previous tokens.
        # TODO(KERN-782): -10000 should be -inf but softmax saturates with NaNs.
        masked_score_vec = (
            q_idx >= (k_idx + iota[index_type, width]())
        ).select(score_vec, MASK_VALUE)

        return masked_score_vec

    @always_inline
    fn status[
        *, element_bitwidth: Int = bitwidthof[UInt32](), unsigned: Bool = True
    ](
        self,
        tile_offset: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        tile_size: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
    ) -> TileMaskStatus:
        # Consider tile corners
        #
        # 1
        # ^
        # C--------------D        A: (offset0,         offset1)
        # |              |        B: (offset0 + size0, offset1)
        # |              |        C: (offset0,         offset1 + size1)
        # |              |        D: (offset0 + size0, offset1 + size1)
        # A--------------B --> 0
        #
        # Key Points:
        #   * A is inside the tile but B, C, D are not.
        #   * If B is on or above the diagonal i.e. offset0 + size0 <= offset1
        #     the tile is fully masked.
        #   * If C is on or below the diagonal i.e. offset0 >= offset1 + size1
        #     the tile is not masked at all.

        # If false, the tile is not masked.
        var min_q_lt_max_k = (
            tile_offset.data[0] < (tile_offset.data[1] + tile_size.data[1])
        ).cast[DType.uint8]()

        # If true, the tile is fully masked
        var max_q_lt_min_k = (
            tile_offset.data[0] + tile_size.data[0] <= tile_offset.data[1]
        ).cast[DType.uint8]()

        # Use 2 bits to represent:
        # (F, F) -> no mask
        # (T, F) -> partial mask
        # (T, T) -> full mask
        return TileMaskStatus(min_q_lt_max_k + (max_q_lt_min_k << 1))


# ===-----------------------------------------------------------------------===#
# NullMask
# ===-----------------------------------------------------------------------===#


@value
@register_passable("trivial")
struct NullMask(MHAMask):
    """Mask that's effectively a noop."""

    alias apply_log2e_after_mask: Bool = False

    @always_inline
    fn mask[
        type: DType,
        width: Int, //,
        *,
        element_bitwidth: Int = bitwidthof[UInt32](),
        unsigned: Bool = False,
    ](
        self,
        coord: IndexList[
            4, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        score_vec: SIMD[type, width],
    ) -> SIMD[type, width]:
        return score_vec

    @always_inline
    fn status[
        *, element_bitwidth: Int = bitwidthof[UInt32](), unsigned: Bool = False
    ](
        self,
        tile_offset: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        tile_size: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
    ) -> TileMaskStatus:
        # no mask
        return TileMaskStatus(0)


# ===-----------------------------------------------------------------------===#
# ChunkedLocalMask
# ===-----------------------------------------------------------------------===#


@value
@register_passable("trivial")
struct ChunkedMask[local_window_size: Int](MHAMask):
    """Mask implementing Chunked attention.

    This groups the mask into chunks of size `local_window_size`.
    Considering the following case:
    - Q_len = 7
    - K_len = 10
    - local_window_size = 4

    The mask will be applied as follows:
        K > 0 1 2 3 4 5 6 7 8 9
        Q v x--------------------x
        0 | 1 1 1 1 0 0 0 0 0 0
        1 | 0 0 0 0 1 1 1 1 0 0
        2 | 0 0 0 0 1 1 1 1 0 0
        3 | 0 0 0 0 1 1 1 1 0 0
        4 | 0 0 0 0 1 1 1 1 0 0
        5 | 0 0 0 0 0 0 0 0 1 1
        6 | 0 0 0 0 0 0 0 0 1 1
    """

    alias apply_log2e_after_mask: Bool = False

    @always_inline
    fn mask[
        type: DType,
        width: Int, //,
        *,
        element_bitwidth: Int = bitwidthof[UInt32](),
        unsigned: Bool = False,
    ](
        self,
        coord: IndexList[
            4, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        score_vec: SIMD[type, width],
    ) -> SIMD[type, width]:
        constrained[
            width <= local_window_size,
            "SIMD width of chunked mask must be <= local window size",
        ]()

        var k_start_idx = coord.data[3]
        var k_end_idx = k_start_idx + width - 1

        q_chunk_idx = Int(coord.data[2] // local_window_size)
        k_start_chunk_idx = Int(k_start_idx) // local_window_size
        k_end_chunk_idx = Int(k_end_idx) // local_window_size

        if q_chunk_idx == k_start_chunk_idx == k_end_chunk_idx:
            # fully unmasked, return the value
            return score_vec

        elif q_chunk_idx == k_start_chunk_idx or q_chunk_idx == k_end_chunk_idx:
            # partial mask
            var retval = score_vec
            var boundary = UInt32(
                (k_start_idx + local_window_size - 1) // local_window_size
            ) * local_window_size

            var mask_val = SIMD[DType.bool, width](False)
            var k_indices = k_start_idx.cast[DType.uint32]() + iota[
                DType.uint32, width
            ]()
            if q_chunk_idx == k_start_chunk_idx:
                mask_val = k_indices >= boundary
            elif q_chunk_idx == k_end_chunk_idx:
                mask_val = k_indices < boundary

            return mask_val.select(MASK_VALUE, retval)

        # fully masked
        return SIMD[type, width](MASK_VALUE)

    @always_inline
    fn status[
        *, element_bitwidth: Int = bitwidthof[UInt32](), unsigned: Bool = False
    ](
        self,
        tile_offset: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        tile_size: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
    ) -> TileMaskStatus:
        q_start_window = tile_offset[0] // local_window_size
        q_end_window = (tile_offset[0] + tile_size[0] - 1) // local_window_size
        k_start_window = tile_offset[1] // local_window_size
        k_end_window = (tile_offset[1] + tile_size[1] - 1) // local_window_size

        var overlapping_windows = k_end_window >= q_start_window and q_end_window >= k_start_window

        if q_start_window == k_start_window == k_end_window == q_end_window:
            return TileMaskStatus.NO_MASK
        elif overlapping_windows:
            return TileMaskStatus.PARTIAL_MASK
        else:
            return TileMaskStatus.FULL_MASK


# ===-----------------------------------------------------------------------===#
# MaterializedMask
# ===-----------------------------------------------------------------------===#


@value
@register_passable("trivial")
struct MaterializedMask[type_: DType, rank_: Int, shape_: DimList](MHAMask):
    """Mask that's backed by a materialized tensor."""

    alias apply_log2e_after_mask: Bool = True
    alias MaskType = NDBuffer[type_, rank_, MutableAnyOrigin, shape_]
    var mask_tensor: Self.MaskType
    var start_pos: OptionalReg[NDBuffer[DType.uint32, 1, MutableAnyOrigin]]
    var is_multiple_of_2: Bool

    fn __init__(
        out self,
        mask_tensor: Self.MaskType,
        start_pos: OptionalReg[
            NDBuffer[DType.uint32, 1, MutableAnyOrigin]
        ] = None,
    ):
        constrained[rank_ in (3, 4), "Expected rank 3 or 4 for mask tensor"]()
        self.mask_tensor = mask_tensor
        self.start_pos = start_pos
        self.is_multiple_of_2 = self.mask_tensor.dim[rank_ - 1]() % 2 == 0

    @always_inline
    fn get_start_pos(self, batch_idx: Int) -> Int:
        if self.start_pos:
            return Int(self.start_pos.value()[batch_idx])
        else:
            return (
                self.mask_tensor.dim[rank_ - 1]()
                - self.mask_tensor.dim[rank_ - 2]()
            )

    @always_inline
    fn mask[
        type: DType,
        width: Int, //,
        *,
        element_bitwidth: Int = bitwidthof[UInt32](),
        unsigned: Bool = False,
    ](
        self,
        coord: IndexList[
            4, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        score_vec: SIMD[type, width],
    ) -> SIMD[type, width]:
        alias IndexListType = IndexList[
            rank_, element_bitwidth=element_bitwidth, unsigned=unsigned
        ]
        var adjusted_coord: IndexListType

        var start_pos = self.get_start_pos(coord[0])

        @parameter
        if rank_ == 3:
            adjusted_coord = IndexListType(
                coord[0], coord[2] - start_pos, coord[3]
            )
        else:
            adjusted_coord = IndexListType(
                coord[0], coord[1], coord[2] - start_pos, coord[3]
            )

        var retval = SIMD[type, width](min_or_neg_inf[type]())
        if adjusted_coord[rank_ - 2] < self.mask_tensor.dim[rank_ - 2]():
            if (
                adjusted_coord[rank_ - 1] + width
                <= self.mask_tensor.dim[rank_ - 1]()
                and self.is_multiple_of_2
            ):
                retval = self.mask_tensor.load[width=width](
                    adjusted_coord
                ).cast[type]()
            elif adjusted_coord[rank_ - 1] < self.mask_tensor.dim[rank_ - 1]():
                for i in range(
                    min(width, self.mask_tensor.dim[rank_ - 1]() - coord[3])
                ):
                    adjusted_coord[rank_ - 1] = coord[3] + i
                    retval[i] = self.mask_tensor.load[width=1](
                        adjusted_coord
                    ).cast[type]()

        return score_vec + retval

    @always_inline
    fn status[
        *, element_bitwidth: Int = bitwidthof[UInt32](), unsigned: Bool = False
    ](
        self,
        tile_offset: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        tile_size: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
    ) -> TileMaskStatus:
        # This is counter-intuitive but setting to `partial` ensures we
        # always read the values for the tensor.
        return TileMaskStatus.PARTIAL_MASK


# ===-----------------------------------------------------------------------===#
# AndMask
# ===-----------------------------------------------------------------------===#


@value
@register_passable("trivial")
struct AndMask[T: MHAMask, S: MHAMask, //, lhs: T, rhs: S](MHAMask):
    """Mask that's the AND of two masks."""

    alias apply_log2e_after_mask: Bool = T.apply_log2e_after_mask or S.apply_log2e_after_mask

    @always_inline
    fn mask[
        type: DType,
        width: Int, //,
        *,
        element_bitwidth: Int = bitwidthof[UInt32](),
        unsigned: Bool = False,
    ](
        self,
        coord: IndexList[
            4, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        score_vec: SIMD[type, width],
    ) -> SIMD[type, width]:
        @parameter
        if type is DType.bool or type.is_integral():
            return self.lhs.mask(coord, score_vec) & self.rhs.mask(
                coord, score_vec
            )

        else:
            return min(
                self.lhs.mask(coord, score_vec),
                self.rhs.mask(coord, score_vec),
            )

    @always_inline
    fn status[
        *, element_bitwidth: Int = bitwidthof[UInt32](), unsigned: Bool = False
    ](
        self,
        tile_offset: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        tile_size: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
    ) -> TileMaskStatus:
        var lhs_status = self.lhs.status(tile_offset, tile_size)
        var rhs_status = self.rhs.status(tile_offset, tile_size)

        return lhs_status & rhs_status


# ===-----------------------------------------------------------------------===#
# OrMask
# ===-----------------------------------------------------------------------===#


@value
@register_passable("trivial")
struct OrMask[T: MHAMask, S: MHAMask, //, lhs: T, rhs: S](MHAMask):
    """Mask that's the OR of two masks."""

    alias apply_log2e_after_mask: Bool = T.apply_log2e_after_mask or S.apply_log2e_after_mask

    @always_inline
    fn mask[
        type: DType,
        width: Int, //,
        *,
        element_bitwidth: Int = bitwidthof[UInt32](),
        unsigned: Bool = False,
    ](
        self,
        coord: IndexList[
            4, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        score_vec: SIMD[type, width],
    ) -> SIMD[type, width]:
        @parameter
        if type is DType.bool or type.is_integral():
            return self.lhs.mask(coord, score_vec) | self.rhs.mask(
                coord, score_vec
            )
        else:
            return min(
                self.lhs.mask(coord, score_vec),
                self.rhs.mask(coord, score_vec),
            )

    @always_inline
    fn status[
        *, element_bitwidth: Int = bitwidthof[UInt32](), unsigned: Bool = False
    ](
        self,
        tile_offset: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
        tile_size: IndexList[
            2, element_bitwidth=element_bitwidth, unsigned=unsigned
        ],
    ) -> TileMaskStatus:
        var lhs_status = self.lhs.status(tile_offset, tile_size)
        var rhs_status = self.rhs.status(tile_offset, tile_size)
        return lhs_status | rhs_status


# ===-----------------------------------------------------------------------===#
# ChunkedLocalMask
# ===-----------------------------------------------------------------------===#


@always_inline
fn chunked_causal_mask[
    local_window_size: Int
](out res: OrMask[CausalMask(), ChunkedMask[local_window_size]()]):
    """Mask implementing Chunked Causal attention for Llama4 models.

    This groups the mask into chunks of size `local_window_size` and performs causal
    attention within each local chunk. Considering the following case:
    - Q_len = 7
    - K_len = 10
    - start_pos = 3
    - local_window_size = 4

    The mask will be applied as follows:
        K > 0 1 2 3 4 5 6 7 8 9
        Q v x--------------------x
        0 | 1 1 1 1 0 0 0 0 0 0
        1 | 0 0 0 0 1 0 0 0 0 0
        2 | 0 0 0 0 1 1 0 0 0 0
        3 | 0 0 0 0 1 1 1 0 0 0
        4 | 0 0 0 0 1 1 1 1 0 0
        5 | 0 0 0 0 0 0 0 0 1 0
        6 | 0 0 0 0 0 0 0 0 1 1
    """
    res = __type_of(res)()
