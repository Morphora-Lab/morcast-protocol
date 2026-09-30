export {
  type CanonicalValue,
  canonicalize,
  decimalString,
  hashCanonical,
  parseDecimalString,
} from "./canonical.js";
export {
  buildPayoutTree,
  EMPTY_ROOT,
  hashPair,
  PAYOUT_LEAF_ENCODING,
  type Payout,
  type PayoutLeaf,
  type PayoutTree,
  payoutLeafHash,
  verifyPayoutProof,
} from "./merkle.js";
export {
  integrationMetric,
  RETENTION_SCALE,
  type RetentionSample,
  retentionFactor,
  trunc6,
} from "./metrics.js";
export { allocatePayouts, type CreatorPayout, type CreatorScore } from "./payouts.js";
export {
  creatorScore,
  creatorThreshold,
  FEE_DIVISOR,
  recognizedTotal,
  type Split,
  split,
} from "./settlement.js";
export { assertUint256, MAX_UINT256 } from "./uint.js";
