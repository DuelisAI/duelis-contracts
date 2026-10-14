// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ================================================================================================
//  DUELIS . $DUEL . BOUT SHEET No. 3 . THE FIGHTER'S BRAIN
//  site: (to be set)   x: (to be set)
// ================================================================================================
//
//  ENTRANT
//      The forward pass every Guard and every Shadow runs: 8 inputs, 9 hidden units, 1 output,
//      91 signed bytes kept in three storage words. Taken unchanged from the Quantum.md network.
//
//  RULES
//      Integer arithmetic only. Weights [0..72) inputs to hidden, row-major by hidden unit; [72..81)
//      hidden biases; [81..90) hidden to output; [90] output bias. Each unit is
//      clamp(sum(w x) / 128 + b x 1e6 / 128) to [-1e6, 1e6]. Division truncates toward zero, exactly as
//      the model in econ_duelis.js computes it.
//
//  SCORING
//      About 20,000 gas a pass (measured on the Quantum.md fork suite).
//
//  OFF THE CARD
//      A hard clamp saturates: many weight sets give the same edge signal.
// ------------------------------------------------------------------------------------------------

/// @title  AgentNet
/// @notice the forward pass of Guards and Shadows.
library AgentNet {
    uint256 internal constant F = 8; // inputs
    uint256 internal constant H = 9; // hidden
    uint256 internal constant WEIGHTS = 91; // 72 + 9 + 9 + 1
    int256 internal constant UNIT = 1e6; // fixed-point 1.0

    /// @notice the signal for feature vector `x` under packed weights `w`. Result in [-UNIT, UNIT].
    function forward(bytes memory w, int256[8] memory x) internal pure returns (int256) {
        require(w.length >= WEIGHTS, "weights");
        bytes32 w0;
        bytes32 w1;
        bytes32 w2;
        assembly ("memory-safe") {
            w0 := mload(add(w, 0x20))
            w1 := mload(add(w, 0x40))
            w2 := mload(add(w, 0x60))
        }
        return forward3(w0, w1, w2, x);
    }

    /// @notice The same forward pass on the three packed storage words. Each weight is one
    ///         sign-extended byte; the arithmetic cannot overflow (a row is at most 9 x 128 x 1e6), so it is unchecked.
    ///         Division truncates toward zero, as Solidity's signed division does, so the result is unchanged.
    function forward3(bytes32 w0, bytes32 w1, bytes32 w2, int256[8] memory x) internal pure returns (int256 o) {
        unchecked {
            int256[9] memory h;
            for (uint256 j; j < H; ++j) {
                int256 acc;
                uint256 row = j * F;
                for (uint256 i; i < F; ++i) acc += _b(w0, w1, w2, row + i) * x[i];
                acc = acc / 128 + (_b(w0, w1, w2, 72 + j) * UNIT) / 128;
                h[j] = acc > UNIT ? UNIT : acc < -UNIT ? -UNIT : acc;
            }
            for (uint256 j; j < H; ++j) o += _b(w0, w1, w2, 81 + j) * h[j];
            o = o / 128 + (_b(w0, w1, w2, 90) * UNIT) / 128;
            if (o > UNIT) o = UNIT;
            else if (o < -UNIT) o = -UNIT;
        }
    }

    /// @dev The signed weight at index k of the 96 packed bytes (k < 96).
    function _b(bytes32 w0, bytes32 w1, bytes32 w2, uint256 k) private pure returns (int256 v) {
        assembly ("memory-safe") {
            let w := w0
            if gt(k, 31) {
                w := w1
                if gt(k, 63) { w := w2 }
            }
            v := signextend(0, byte(mod(k, 32), w))
        }
    }
}
