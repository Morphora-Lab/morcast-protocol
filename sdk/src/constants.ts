/**
 * Timing constants of the escrow contract, in seconds. `Day N` means `endAt + N days`.
 */

/** Settlement opens on Day 5 (`MORCastEscrow.SETTLEMENT_OPENS_AFTER`). */
export const SETTLEMENT_OPENS_AFTER = 5n * 86_400n;

/** Settlement closes, and the full refund opens, on Day 10 (`SETTLEMENT_CLOSES_AFTER`). */
export const SETTLEMENT_CLOSES_AFTER = 10n * 86_400n;

/** Longest allowed campaign window `endAt − startAt`: 90 days (`MAX_CAMPAIGN_DURATION`). */
export const MAX_CAMPAIGN_DURATION = 90n * 86_400n;
