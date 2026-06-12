// === Scenario 3: Suspension vs revocation, two aborts, two remedies ===
//
// Story: the same spender action (`spend` against a grant the owner shut
// off) aborts with DIFFERENT codes depending on HOW the owner shut it off,
// and integrators key their remedies on the distinction:
//
//   set_allowance(…, 0, …)  → entry stays, cap stays valid
//                           → spend aborts EAllowanceExceeded (code 4)
//                           → remedy: ask the owner to raise the budget
//
//   revoke(cap_id)          → entry removed, cap is inert
//                           → spend aborts ENoAllowance (code 2)
//                           → remedy: only a brand-new grant
//
// Conflating the two is the classic integration bug: retrying the wrong
// remedy. `contains(vault, cap_id)` is the read-side disambiguator
// (allowance() returns 0 in both states).
#[test_only]
module spend_vault_example::suspension_vs_revocation_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use spend_vault_example::usdc::USDC;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario::{Self, Scenario};

const OWNER: address = @0xACE;
const SPENDER: address = @0xB0B;

const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

/// Shared setup: OWNER creates + funds a vault and grants SPENDER a live
/// 400 budget. Returns the scenario and the cap's ID.
fun setup(): (Scenario, ID) {
    let mut ts = test_scenario::begin(OWNER);

    // Tx 1 (OWNER): create, fund, grant, share.
    {
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(1_700_000_000_000);

        let (mut vault, owner_cap) = spend_vault::new<USDC>(ts.ctx());
        spend_vault::deposit(&mut vault, coin::mint_for_testing<USDC>(1_000, ts.ctx()), ts.ctx());
        spend_vault::mint_and_transfer(
            &mut vault, &owner_cap, 400, NO_EXPIRY, SPENDER, &clock, ts.ctx(),
        );
        spend_vault::share(vault);
        transfer::public_transfer(owner_cap, OWNER);
        clock.share_for_testing();
    };

    // Capture the cap's ID from the spender's side.
    ts.next_tx(SPENDER);
    let cap_id = {
        let cap = ts.take_from_sender<SpenderCap>();
        let cap_id = object::id(&cap);
        ts.return_to_sender(cap);
        cap_id
    };

    (ts, cap_id)
}

// Protects the suspension idiom and its half of the abort-code distinction:
// a suspended entry is LIVE-but-paused. Code 4, not code 2.
#[test]
#[expected_failure(abort_code = spend_vault::EAllowanceExceeded)]
fun spend_against_suspended_entry_aborts_exceeded() {
    let (mut ts, cap_id) = setup();

    // Tx 2 (OWNER): suspend. Zero the budget, keep entry + cap alive.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        spend_vault::set_allowance(
            &mut vault, &owner_cap, cap_id,
            0, NO_EXPIRY, // 0 is the suspension idiom, deliberately legal here
            option::none(), &clock, ts.ctx(),
        );
        // The read-side picture of "suspended": present, but zero.
        assert!(spend_vault::contains(&vault, cap_id));
        assert!(spend_vault::allowance(&vault, cap_id) == 0);

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    // Tx 3 (SPENDER): any positive spend now aborts with code 4.
    ts.next_tx(SPENDER);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let funds = spend_vault::spend(&mut vault, &cap, 1, &clock, ts.ctx()); // aborts
        funds.destroy_for_testing(); // unreachable

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}

// Protects the revocation semantics: a revoked entry is GONE (code 2, the
// "absent" code), while the cap object survives in the spender's wallet as
// inert non-authority.
#[test]
#[expected_failure(abort_code = spend_vault::ENoAllowance)]
fun spend_after_revoke_aborts_no_allowance() {
    let (mut ts, cap_id) = setup();

    // Tx 2 (OWNER): revoke. Remove the entry outright.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let was_present = spend_vault::revoke(&mut vault, &owner_cap, cap_id, ts.ctx());
        assert!(was_present); // honest return: something was actually removed
        // The read-side picture of "revoked": absent.
        assert!(!spend_vault::contains(&vault, cap_id));

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
    };

    // Tx 3 (SPENDER): the still-held cap is now inert. Code 2.
    ts.next_tx(SPENDER);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let funds = spend_vault::spend(&mut vault, &cap, 1, &clock, ts.ctx()); // aborts
        funds.destroy_for_testing(); // unreachable

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}
