// === Failing case: a cap only spends the coins it was budgeted for ===
//
// A `SpenderCap` is untyped; the coin is chosen at the `spend<T>` call site and
// checked against that cap's per-coin budget. So a cap budgeted for USDC cannot
// draw SUIT: `spend<SUIT>` aborts ENoAllowance. This is a budget decision, not a
// pool one: the test funds the SUIT pool in full and the spend still aborts. It
// is the behavior an integrator most needs to internalize before trusting a cap.
#[test_only]
module spend_vault_example::coin_type_gate_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, SpenderCap};
use spend_vault_example::coins::{USDC, SUIT};
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario::{Self, Scenario};

const OWNER: address = @0xACE;
const ALICE: address = @0xB0B;

const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

/// Shared setup: OWNER funds BOTH USDC and SUIT pools, but grants the cap a
/// budget for USDC ONLY, then hands the cap to ALICE. Returns the scenario and
/// the cap's ID.
fun setup(): (Scenario, ID) {
    let mut ts = test_scenario::begin(OWNER);

    let cap_id = {
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(1_700_000_000_000);

        let (mut vault, owner_cap) = spend_vault::new(ts.ctx());
        // Both pools funded, so a later SUIT abort is provably about the budget,
        // not an empty pool.
        spend_vault::deposit(&vault, coin::mint_for_testing<USDC>(1_000, ts.ctx()), ts.ctx());
        spend_vault::deposit(&vault, coin::mint_for_testing<SUIT>(1_000, ts.ctx()), ts.ctx());

        let cap = spend_vault::mint_cap(&vault, &owner_cap, ts.ctx());
        let cap_id = object::id(&cap);
        // USDC budget only; no SUIT budget is ever granted.
        spend_vault::set_allowance<USDC>(
            &mut vault, &owner_cap, cap_id, 300, NO_EXPIRY, option::none(), &clock, ts.ctx(),
        );

        transfer::public_transfer(cap, ALICE);
        spend_vault::share(vault);
        transfer::public_transfer(owner_cap, OWNER);
        clock.share_for_testing();
        cap_id
    };

    (ts, cap_id)
}

// Positive control: the cap spends the coin it WAS budgeted for, fine.
#[test]
fun budgeted_coin_spends_fine() {
    let (mut ts, cap_id) = setup();

    ts.next_tx(ALICE);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let usdc = spend_vault::spend<USDC>(&mut vault, &cap, 100, &clock, ts.ctx());
        assert!(usdc.value() == 100);
        usdc.into_coin(ts.ctx()).burn_for_testing();
        assert!(spend_vault::allowance<USDC>(&vault, cap_id) == 200);

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}

// The gate: the same cap cannot draw a coin it was never budgeted for, even with
// the SUIT pool full. Aborts ENoAllowance.
#[test]
#[expected_failure(abort_code = spend_vault::ENoAllowance)]
fun unbudgeted_coin_is_gated() {
    let (mut ts, _cap_id) = setup();

    ts.next_tx(ALICE);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let funds = spend_vault::spend<SUIT>(&mut vault, &cap, 100, &clock, ts.ctx()); // aborts
        funds.destroy_for_testing(); // unreachable

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}
