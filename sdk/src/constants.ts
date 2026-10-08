/**
 * Constants of the escrow contract. Times are in seconds. `Day N` means `endAt + N days`.
 */

/**
 * Escrow version whose ABI and rules this SDK implements. Deployments with the same major
 * version are compatible.
 */
export const ESCROW_VERSION = "1.0.0";

/** Settlement opens on Day 5 (`MORCastEscrow.SETTLEMENT_OPENS_AFTER`). */
export const SETTLEMENT_OPENS_AFTER = 5n * 86_400n;

/** Settlement closes, and the full refund opens, on Day 10 (`SETTLEMENT_CLOSES_AFTER`). */
export const SETTLEMENT_CLOSES_AFTER = 10n * 86_400n;

/** Longest allowed campaign window `endAt − startAt`: 90 days (`MAX_CAMPAIGN_DURATION`). */
export const MAX_CAMPAIGN_DURATION = 90n * 86_400n;
