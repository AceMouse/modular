# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from math import iota
from sys import bitwidthof

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

    fn __str__(self) -> String:
        return String.write(self)

    fn write_to[W: Writer](self, mut writer: W):
        if self.status == 0:
            writer.write("not masked")
        elif self.status == 1:
            writer.write("partially masked")
        else:
            writer.write("fully masked")


# ===-----------------------------------------------------------------------===#
# MHAMask
# ===-----------------------------------------------------------------------===#


trait MHAMask:
    """The MHAMask trait describes masks for MHA kernels, such as the causal mask.
    """

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


@value
@register_passable("trivial")
struct CausalMask(MHAMask):
    """MHA causal mask ensures a token is only affected by previous tokens."""

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
        ).select(score_vec, -10000)

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
