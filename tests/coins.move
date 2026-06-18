/// Test-only stand-in coin types for the scenarios. Any `drop` type works as a
/// coin marker with `coin::mint_for_testing`; on a network these would be real
/// coin types with `TreasuryCap`-managed supplies. Three of them so the examples
/// can show one cap carrying a separate budget per coin. `SUIT` stands in for a
/// SUI-like coin (named to avoid colliding with the real `sui::sui::SUI`).
#[test_only]
module spend_vault_example::coins;

public struct USDC has drop {}

public struct SUIT has drop {}

public struct DEEP has drop {}
