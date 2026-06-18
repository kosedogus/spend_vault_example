// === Scenario 1: Direct multi-coin delegation, full lifecycle ===
//
// A treasury delegates a spending budget to a contractor it knows by address.
// This pattern needs no wrapper module: the library API is the integration. The
// walkthrough is the whole life of a grant: create + fund two coins, mint a cap
// and grant a budget per coin, spend both coins through the one cap, renew with
// the CAS idiom, drain to zero, the spender exits with renounce, and the owner
// tears the vault down.
#[test_only]
module spend_vault_example::direct_delegation_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use spend_vault_example::coins::{USDC, SUIT};
use std::type_name;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::event;
use sui::test_scenario;

const TREASURY: address = @0xACE;
const CONTRACTOR: address = @0xB0B;
const MERCHANT: address = @0xBEEF;

const DAY_MS: u64 = 86_400_000;
const NOW_MS: u64 = 1_000 * DAY_MS; // arbitrary test "now"
const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

#[test]
fun direct_delegation_full_lifecycle() {
    let mut ts = test_scenario::begin(TREASURY);

    // Tx 1 (TREASURY): create the vault, fund two coins, mint a cap, grant a
    // budget per coin, hand the cap to the contractor, share the vault, keep the
    // OwnerCap. The vault must be shared (or destroyed) in this same tx.
    let cap_id = {
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(NOW_MS);

        let (mut vault, owner_cap) = spend_vault::new(ts.ctx());

        spend_vault::deposit(&vault, coin::mint_for_testing<USDC>(1_000, ts.ctx()), ts.ctx());
        spend_vault::deposit(&vault, coin::mint_for_testing<SUIT>(800, ts.ctx()), ts.ctx());

        // Mint the cap, then grant each coin's budget separately.
        let cap = spend_vault::mint_cap(&vault, &owner_cap, ts.ctx());
        let cap_id = object::id(&cap);
        spend_vault::set_allowance<USDC>(
            &mut vault, &owner_cap, cap_id,
            400, NOW_MS + 30 * DAY_MS, option::none(), &clock, ts.ctx(),
        );
        spend_vault::set_allowance<SUIT>(
            &mut vault, &owner_cap, cap_id,
            300, NO_EXPIRY, option::none(), &clock, ts.ctx(),
        );

        transfer::public_transfer(cap, CONTRACTOR);
        spend_vault::share(vault);
        transfer::public_transfer(owner_cap, TREASURY);
        clock.share_for_testing();
        cap_id
    };

    // Tx 2 (CONTRACTOR): spend both coins through the one cap in a single tx and
    // pay a merchant. Each spend returns a Balance the caller must route onward.
    ts.next_tx(CONTRACTOR);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();
        let vault_id = object::id(&vault);

        let usdc = spend_vault::spend<USDC>(&mut vault, &cap, 150, &clock, ts.ctx());
        let suit = spend_vault::spend<SUIT>(&mut vault, &cap, 100, &clock, ts.ctx());
        assert!(usdc.value() == 150);
        assert!(suit.value() == 100);
        transfer::public_transfer(usdc.into_coin(ts.ctx()), MERCHANT);
        transfer::public_transfer(suit.into_coin(ts.ctx()), MERCHANT);

        // The two coin budgets decrement independently.
        assert!(spend_vault::allowance<USDC>(&vault, cap_id) == 250);
        assert!(spend_vault::allowance<SUIT>(&vault, cap_id) == 200);

        // Spends are observable off-chain via the Spent event (one per coin).
        assert!(
            event::events_by_type<spend_vault::Spent>() == vector[
                spend_vault::test_new_spent(
                    vault_id, cap_id, type_name::with_defining_ids<USDC>(), 150, 250, CONTRACTOR,
                ),
                spend_vault::test_new_spent(
                    vault_id, cap_id, type_name::with_defining_ids<SUIT>(), 100, 200, CONTRACTOR,
                ),
            ],
        );

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    // Tx 3 (TREASURY): raise the USDC budget and renew its expiry. On any
    // read-then-write, pass the value you read as `expected` (the CAS guard);
    // within a single tx it always matches. The owner uses only the cap's ID, so
    // the cap stays untouched in the contractor's wallet, and a USDC update does
    // not affect the SUIT budget.
    ts.next_tx(TREASURY);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let current = spend_vault::allowance<USDC>(&vault, cap_id);
        assert!(current == 250);
        spend_vault::set_allowance<USDC>(
            &mut vault, &owner_cap, cap_id,
            500, NOW_MS + 60 * DAY_MS, option::some(current), &clock, ts.ctx(),
        );
        assert!(spend_vault::allowance<USDC>(&vault, cap_id) == 500);
        assert!(spend_vault::allowance<SUIT>(&vault, cap_id) == 200); // untouched

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    // Tx 4 (CONTRACTOR): drain both budgets. The entries stay at zero, so the cap
    // is still valid and the owner could resume either coin later.
    ts.next_tx(CONTRACTOR);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let usdc = spend_vault::spend<USDC>(&mut vault, &cap, 500, &clock, ts.ctx());
        let suit = spend_vault::spend<SUIT>(&mut vault, &cap, 200, &clock, ts.ctx());
        transfer::public_transfer(usdc.into_coin(ts.ctx()), MERCHANT);
        transfer::public_transfer(suit.into_coin(ts.ctx()), MERCHANT);

        assert!(spend_vault::allowance<USDC>(&vault, cap_id) == 0);
        assert!(spend_vault::allowance<SUIT>(&vault, cap_id) == 0);
        assert!(spend_vault::contains<USDC>(&vault, cap_id)); // entry still present
        assert!(spend_vault::contains<SUIT>(&vault, cap_id));

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    // Tx 5 (CONTRACTOR): done, renounce. One call removes the cap object and all
    // its grants, leaving nothing spendable behind.
    ts.next_tx(CONTRACTOR);
    {
        let mut vault = ts.take_shared<Vault>();
        let cap = ts.take_from_sender<SpenderCap>();

        spend_vault::renounce(&mut vault, cap, ts.ctx());
        assert!(!spend_vault::contains<USDC>(&vault, cap_id));
        assert!(!spend_vault::contains<SUIT>(&vault, cap_id));

        test_scenario::return_shared(vault);
    };

    // Tx 6 (TREASURY): tear down. The real ritual: enumerate coin types off-chain
    // via getAllBalances, drain each with withdraw_all<T>, then wait a checkpoint
    // and re-check before destroy (a same-checkpoint deposit is invisible to
    // withdraw_all's settled read, and withdraw_all is only retry-safe across
    // checkpoints). withdraw_all needs an AccumulatorRoot the unit VM cannot
    // build, so here each coin is drained with the root-free partial withdraw<T>.
    // Pool after the spends: USDC 1_000 - (150 + 500) = 350; SUIT 800 - (100 + 200) = 500.
    // destroy then tears down the vault and returns nothing.
    ts.next_tx(TREASURY);
    {
        let mut vault = ts.take_shared<Vault>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let usdc = spend_vault::withdraw<USDC>(&mut vault, &owner_cap, 350, ts.ctx());
        let suit = spend_vault::withdraw<SUIT>(&mut vault, &owner_cap, 500, ts.ctx());
        assert!(usdc.value() == 350);
        assert!(suit.value() == 500);
        transfer::public_transfer(usdc.into_coin(ts.ctx()), TREASURY);
        transfer::public_transfer(suit.into_coin(ts.ctx()), TREASURY);

        spend_vault::destroy(vault, owner_cap, ts.ctx());
    };

    ts.end();
}
