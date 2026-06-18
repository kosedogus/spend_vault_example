// === Scenario 3: Suspension vs revocation, two aborts, two remedies ===
//
// A spend against a grant the owner shut off aborts with a DIFFERENT code
// depending on HOW the owner shut it off, and an integrator keys the remedy on
// the distinction:
//
//   set_allowance(.., 0, ..)  -> entry stays, cap stays valid
//                             -> spend aborts EAllowanceExceeded
//                             -> remedy: ask the owner to raise the budget
//
//   revoke<T>(cap_id)         -> entry removed, cap inert for this coin
//                             -> spend aborts ENoAllowance
//                             -> remedy: only a brand-new grant
//
// Retrying the wrong remedy is the classic integration bug. `contains<T>` is the
// read-side disambiguator: allowance<T>() reads 0 in BOTH states, but a suspended
// entry is still present and a revoked one is gone.
#[test_only]
module spend_vault_example::suspension_vs_revocation_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use spend_vault_example::coins::USDC;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario::{Self, Scenario};

const OWNER: address = @0xACE;
const SPENDER: address = @0xB0B;

const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

/// Shared setup: OWNER creates + funds a vault and grants SPENDER a live 400
/// USDC budget on a fresh cap. Returns the scenario and the cap's ID.
fun setup(): (Scenario, ID) {
    let mut ts = test_scenario::begin(OWNER);

    // Tx 1 (OWNER): create, fund, mint a cap, grant 400 USDC, share.
    let cap_id = {
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(1_700_000_000_000);

        let (mut vault, owner_cap) = spend_vault::new(ts.ctx());
        spend_vault::deposit(&vault, coin::mint_for_testing<USDC>(1_000, ts.ctx()), ts.ctx());
        let cap = spend_vault::mint_cap(&vault, &owner_cap, ts.ctx());
        let cap_id = object::id(&cap);
        spend_vault::set_allowance<USDC>(
            &mut vault, &owner_cap, cap_id, 400, NO_EXPIRY, option::none(), &clock, ts.ctx(),
        );
        transfer::public_transfer(cap, SPENDER);
        spend_vault::share(vault);
        transfer::public_transfer(owner_cap, OWNER);
        clock.share_for_testing();
        cap_id
    };

    (ts, cap_id)
}

// Suspended (budget set to 0): the entry and cap are still alive, so a spend
// aborts EAllowanceExceeded. Remedy is to raise the budget, not re-grant.
#[test]
#[expected_failure(abort_code = spend_vault::EAllowanceExceeded)]
fun spend_against_suspended_entry_aborts_exceeded() {
    let (mut ts, cap_id) = setup();

    // Tx 2 (OWNER): suspend. Zero the budget, keep entry + cap alive.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        spend_vault::set_allowance<USDC>(
            &mut vault, &owner_cap, cap_id,
            0, NO_EXPIRY, // 0 is the suspension idiom, deliberately legal here
            option::none(), &clock, ts.ctx(),
        );
        // Read-side picture of "suspended": present, but zero.
        assert!(spend_vault::contains<USDC>(&vault, cap_id));
        assert!(spend_vault::allowance<USDC>(&vault, cap_id) == 0);

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    // Tx 3 (SPENDER): any positive spend now aborts EAllowanceExceeded.
    ts.next_tx(SPENDER);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let funds = spend_vault::spend<USDC>(&mut vault, &cap, 1, &clock, ts.ctx()); // aborts
        funds.destroy_for_testing(); // unreachable

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}

// Revoked: the entry is gone, so a spend aborts ENoAllowance. The cap object
// survives in the spender's wallet but is inert for this coin.
#[test]
#[expected_failure(abort_code = spend_vault::ENoAllowance)]
fun spend_after_revoke_aborts_no_allowance() {
    let (mut ts, cap_id) = setup();

    // Tx 2 (OWNER): revoke the USDC entry outright.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let was_present = spend_vault::revoke<USDC>(&mut vault, &owner_cap, cap_id, ts.ctx());
        assert!(was_present); // honest return: something was actually removed
        assert!(!spend_vault::contains<USDC>(&vault, cap_id)); // absent now

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
    };

    // Tx 3 (SPENDER): the still-held cap is now inert for USDC. ENoAllowance.
    ts.next_tx(SPENDER);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let funds = spend_vault::spend<USDC>(&mut vault, &cap, 1, &clock, ts.ctx()); // aborts
        funds.destroy_for_testing(); // unreachable

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}
