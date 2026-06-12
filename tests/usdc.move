/// Test-only stand-in coin type shared by every scenario. Any `drop` type
/// works as the coin marker with `coin::mint_for_testing`; on a network this
/// would be a real coin type with a `TreasuryCap`-managed supply.
#[test_only]
module spend_vault_example::usdc;

public struct USDC has drop {}
