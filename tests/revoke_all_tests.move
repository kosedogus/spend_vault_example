// === Scenario 5: revoke_all, the one-call kill for a leaked cap ===
//
// A bearer SpenderCap can span many coin budgets, so a leak exposes the sum
// across every coin. revoke_all kills them all in one call and emits one Revoked
// per coin.
//
// Emergency-stop ordering an integrator should follow: run revoke_all FIRST, in
// its own transaction. It never touches the pool, so a front-running spend cannot
// race it into failure. Drain the funds with withdraw_all<T> in a LATER tx; do
// NOT bundle the two in one PTB, or a pool-short in withdraw_all would revert the
// revoke_all with it. (withdraw_all needs an AccumulatorRoot the unit VM can't
// build, so the drain half lives in the testnet harness; the unraceable kill half
// is witnessed below.)
#[test_only]
module spend_vault_example::revoke_all_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use spend_vault_example::coins::{USDC, SUIT, DEEP};
use std::type_name;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::event;
use sui::test_scenario::{Self, Scenario};

const OWNER: address = @0xACE;
const SPENDER: address = @0xB0B;

const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

/// Shared setup: OWNER creates + funds a vault with three coins, mints one cap,
/// grants it a budget for all three (USDC, SUIT, DEEP, in that order), and hands
/// the cap to SPENDER. Returns the scenario, the vault's ID, and the cap's ID.
fun setup(): (Scenario, ID, ID) {
    let mut ts = test_scenario::begin(OWNER);

    let (vault_id, cap_id) = {
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(1_700_000_000_000);

        let (mut vault, owner_cap) = spend_vault::new(ts.ctx());
        let vault_id = object::id(&vault);
        spend_vault::deposit(&vault, coin::mint_for_testing<USDC>(1_000, ts.ctx()), ts.ctx());
        spend_vault::deposit(&vault, coin::mint_for_testing<SUIT>(1_000, ts.ctx()), ts.ctx());
        spend_vault::deposit(&vault, coin::mint_for_testing<DEEP>(1_000, ts.ctx()), ts.ctx());

        let cap = spend_vault::mint_cap(&vault, &owner_cap, ts.ctx());
        let cap_id = object::id(&cap);
        spend_vault::set_allowance<USDC>(&mut vault, &owner_cap, cap_id, 300, NO_EXPIRY, option::none(), &clock, ts.ctx());
        spend_vault::set_allowance<SUIT>(&mut vault, &owner_cap, cap_id, 200, NO_EXPIRY, option::none(), &clock, ts.ctx());
        spend_vault::set_allowance<DEEP>(&mut vault, &owner_cap, cap_id, 100, NO_EXPIRY, option::none(), &clock, ts.ctx());

        transfer::public_transfer(cap, SPENDER);
        spend_vault::share(vault);
        transfer::public_transfer(owner_cap, OWNER);
        clock.share_for_testing();
        (vault_id, cap_id)
    };

    (ts, vault_id, cap_id)
}

// Happy path: one call kills every coin budget the leaked cap holds, emitting one
// Revoked per removed coin in grant order.
#[test]
fun revoke_all_kills_every_coin_in_one_call() {
    let (mut ts, vault_id, cap_id) = setup();

    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        // Pre-state: all three budgets live. `granted_coin_types` is the read an
        // SDK uses to discover which coins a vault has granted.
        assert!(spend_vault::contains<USDC>(&vault, cap_id));
        assert!(spend_vault::contains<SUIT>(&vault, cap_id));
        assert!(spend_vault::contains<DEEP>(&vault, cap_id));
        assert!(spend_vault::granted_coin_types(&vault) == vector[
            type_name::with_defining_ids<USDC>(),
            type_name::with_defining_ids<SUIT>(),
            type_name::with_defining_ids<DEEP>(),
        ]);

        // One call kills the whole cap.
        spend_vault::revoke_all(&mut vault, &owner_cap, cap_id, ts.ctx());

        // Every coin is gone.
        assert!(!spend_vault::contains<USDC>(&vault, cap_id));
        assert!(!spend_vault::contains<SUIT>(&vault, cap_id));
        assert!(!spend_vault::contains<DEEP>(&vault, cap_id));

        // One Revoked event per removed coin, in grant order.
        assert!(
            event::events_by_type<spend_vault::Revoked>() == vector[
                spend_vault::test_new_revoked(vault_id, cap_id, type_name::with_defining_ids<USDC>(), true, OWNER),
                spend_vault::test_new_revoked(vault_id, cap_id, type_name::with_defining_ids<SUIT>(), true, OWNER),
                spend_vault::test_new_revoked(vault_id, cap_id, type_name::with_defining_ids<DEEP>(), true, OWNER),
            ],
        );

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
    };

    ts.end();
}

// After revoke_all, the leaked cap is inert for every coin: a spend on any of
// them aborts ENoAllowance.
#[test]
#[expected_failure(abort_code = spend_vault::ENoAllowance)]
fun spend_after_revoke_all_aborts_no_allowance() {
    let (mut ts, _vault_id, cap_id) = setup();

    // Tx 2 (OWNER): kill the whole cap.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault>();
        let owner_cap = ts.take_from_sender<OwnerCap>();
        spend_vault::revoke_all(&mut vault, &owner_cap, cap_id, ts.ctx());
        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
    };

    // Tx 3 (SPENDER): the leaked cap can no longer draw DEEP (or anything).
    ts.next_tx(SPENDER);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let funds = spend_vault::spend<DEEP>(&mut vault, &cap, 1, &clock, ts.ctx()); // aborts
        funds.destroy_for_testing(); // unreachable

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}

// revoke_all on a cap with no budgets still succeeds and emits nothing, so the
// kill is safe to call without first checking what the cap holds.
#[test]
fun revoke_all_on_bare_cap_is_total() {
    let mut ts = test_scenario::begin(OWNER);

    // Tx 1 (OWNER): create a vault and a cap with NO budgets at all.
    let cap_id = {
        let (vault, owner_cap) = spend_vault::new(ts.ctx());
        let cap = spend_vault::mint_cap(&vault, &owner_cap, ts.ctx());
        let cap_id = object::id(&cap);
        spend_vault::delete_orphaned_cap(cap); // we only needed its id here
        spend_vault::share(vault);
        transfer::public_transfer(owner_cap, OWNER);
        cap_id
    };

    // Tx 2 (OWNER): revoke_all over an empty grant set is a no-op success.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        spend_vault::revoke_all(&mut vault, &owner_cap, cap_id, ts.ctx()); // no abort
        assert!(event::events_by_type<spend_vault::Revoked>().is_empty()); // nothing removed

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
    };

    ts.end();
}

// Why revoke_all goes first in an emergency: it is pool-independent, so a
// front-running spend by the leaked-cap holder cannot race it into failure. The
// spend succeeds (revoke is not retroactive), yet revoke_all still removes every
// budget in the same incident. Bundling withdraw_all into one PTB would surrender
// this immunity, since a pool-short there reverts the revoke_all too.
#[test]
fun revoke_all_is_not_raced_by_a_front_running_spend() {
    let (mut ts, _vault_id, cap_id) = setup();

    // Tx 2 (SPENDER): front-run the owner's response with a spend.
    ts.next_tx(SPENDER);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let funds = spend_vault::spend<USDC>(&mut vault, &cap, 100, &clock, ts.ctx());
        funds.destroy_for_testing();

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    // Tx 3 (OWNER): revoke_all still succeeds and removes every budget.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        spend_vault::revoke_all(&mut vault, &owner_cap, cap_id, ts.ctx());
        assert!(!spend_vault::contains<USDC>(&vault, cap_id));
        assert!(!spend_vault::contains<SUIT>(&vault, cap_id));
        assert!(!spend_vault::contains<DEEP>(&vault, cap_id));

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
    };

    ts.end();
}
