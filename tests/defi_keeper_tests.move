// === Scenario 2: Protocol-embedded cap (the keeper service) ===
//
// A user lets a keeper protocol draw from the user's own vault to top up
// positions. The owner stays in control: they raise the budget mid-custody and
// the same embedded cap keeps working, with no re-registration. One untyped cap
// serves multiple coins via execute_topup<T>.
//
// Three tests:
//   1. happy path: register, top up USDC and SUIT, owner raises the USDC budget,
//      top up USDC again under the new budget, all on one cap
//   2. the sender gate rejects a non-operator before the library sees the cap
//   3. the binding check rejects a cap bound to a different vault at register time
#[test_only]
module spend_vault_example::defi_keeper_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap};
use spend_vault_example::coins::{USDC, SUIT};
use spend_vault_example::defi_keeper::{Self, Service};
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario::{Self, Scenario};

const USER: address = @0xACE; // owns the vault AND registers with the keeper
const OPERATOR: address = @0xCAFE; // runs the keeper service
const MALLORY: address = @0xBAD; // not the operator

const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

/// Shared setup: USER creates + funds a vault (USDC + SUIT) and keeps the
/// OwnerCap; OPERATOR creates a service pinned to it; USER mints one cap, grants
/// it a USDC and a SUIT budget, and hands it into custody. Returns the scenario,
/// the vault's ID, and the cap's ID.
fun setup(): (Scenario, ID, ID) {
    let mut ts = test_scenario::begin(USER);

    // Tx 1 (USER): create + fund (two coins) + share the vault; keep the OwnerCap.
    let vault_id = {
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(1_700_000_000_000);

        let (vault, owner_cap) = spend_vault::new(ts.ctx());
        let vault_id = object::id(&vault);
        spend_vault::deposit(&vault, coin::mint_for_testing<USDC>(1_000, ts.ctx()), ts.ctx());
        spend_vault::deposit(&vault, coin::mint_for_testing<SUIT>(500, ts.ctx()), ts.ctx());
        spend_vault::share(vault);
        transfer::public_transfer(owner_cap, USER);
        clock.share_for_testing();
        vault_id
    };

    // Tx 2 (OPERATOR): create the keeper service pinned to that vault.
    ts.next_tx(OPERATOR);
    {
        defi_keeper::create(vault_id, ts.ctx());
    };

    // Tx 3 (USER): mint a cap, grant two coin budgets, and hand it straight into
    // custody by value, so the cap never has to touch the user's wallet.
    ts.next_tx(USER);
    let cap_id = {
        let mut vault = ts.take_shared<Vault>();
        let mut service = ts.take_shared<Service>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let cap = spend_vault::mint_cap(&vault, &owner_cap, ts.ctx());
        let cap_id = object::id(&cap);
        spend_vault::set_allowance<USDC>(
            &mut vault, &owner_cap, cap_id, 300, NO_EXPIRY, option::none(), &clock, ts.ctx(),
        );
        spend_vault::set_allowance<SUIT>(
            &mut vault, &owner_cap, cap_id, 150, NO_EXPIRY, option::none(), &clock, ts.ctx(),
        );
        defi_keeper::register(&mut service, cap, ts.ctx());
        assert!(defi_keeper::is_registered(&service, USER));

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(service);
        test_scenario::return_shared(clock);
        cap_id
    };

    (ts, vault_id, cap_id)
}

#[test]
fun keeper_spends_multi_coin_and_cap_survives_owner_update() {
    let (mut ts, _vault_id, cap_id) = setup();

    // Tx 4 (OPERATOR): top up two different coins through the one custodied cap
    // and route the funds to the user.
    ts.next_tx(OPERATOR);
    {
        let mut vault = ts.take_shared<Vault>();
        let mut service = ts.take_shared<Service>();
        let clock = ts.take_shared<Clock>();

        let usdc = defi_keeper::execute_topup<USDC>(&mut service, &mut vault, USER, 100, &clock, ts.ctx());
        let suit = defi_keeper::execute_topup<SUIT>(&mut service, &mut vault, USER, 50, &clock, ts.ctx());
        transfer::public_transfer(usdc.into_coin(ts.ctx()), USER);
        transfer::public_transfer(suit.into_coin(ts.ctx()), USER);

        assert!(spend_vault::allowance<USDC>(&vault, cap_id) == 200);
        assert!(spend_vault::allowance<SUIT>(&vault, cap_id) == 100);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(service);
        test_scenario::return_shared(clock);
    };

    // Tx 5 (USER, as vault owner): raise the USDC budget using only the cap's ID
    // while the cap sits inside the service. The embedded cap is untouched.
    ts.next_tx(USER);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let current = spend_vault::allowance<USDC>(&vault, cap_id);
        spend_vault::set_allowance<USDC>(
            &mut vault, &owner_cap, cap_id,
            1_000, NO_EXPIRY,
            option::some(current), // CAS on a read-derived update, always
            &clock, ts.ctx(),
        );

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    // Tx 6 (OPERATOR): spend USDC again under the new budget with the same
    // embedded cap. No re-registration needed: owner maintenance never breaks an
    // integration holding the cap.
    ts.next_tx(OPERATOR);
    {
        let mut vault = ts.take_shared<Vault>();
        let mut service = ts.take_shared<Service>();
        let clock = ts.take_shared<Clock>();

        let usdc = defi_keeper::execute_topup<USDC>(&mut service, &mut vault, USER, 600, &clock, ts.ctx());
        transfer::public_transfer(usdc.into_coin(ts.ctx()), USER);

        assert!(spend_vault::allowance<USDC>(&vault, cap_id) == 400);
        assert!(spend_vault::allowance<SUIT>(&vault, cap_id) == 100); // SUIT untouched

        test_scenario::return_shared(vault);
        test_scenario::return_shared(service);
        test_scenario::return_shared(clock);
    };

    ts.end();
}

// The sender gate is the integration's security boundary: a `SpenderCap` is a
// bearer instrument, so without this operator check execute_topup would be
// world-drainable across every coin the cap is budgeted for.
#[test]
#[expected_failure(abort_code = defi_keeper::ENotOperator)]
fun topup_by_non_operator_is_rejected() {
    let (mut ts, _vault_id, _cap_id) = setup();

    // Tx 4 (MALLORY): tries to drive the keeper's custodied cap.
    ts.next_tx(MALLORY);
    {
        let mut vault = ts.take_shared<Vault>();
        let mut service = ts.take_shared<Service>();
        let clock = ts.take_shared<Clock>();

        let funds = defi_keeper::execute_topup<USDC>(&mut service, &mut vault, USER, 100, &clock, ts.ctx());
        funds.destroy_for_testing(); // unreachable, the gate aborts first

        test_scenario::return_shared(vault);
        test_scenario::return_shared(service);
        test_scenario::return_shared(clock);
    };

    ts.end();
}

// The custody boundary: validate a cap's vault binding before accepting it. A cap
// minted against some other vault is rejected at register time, not discovered at
// spend time.
#[test]
#[expected_failure(abort_code = defi_keeper::EWrongVaultForService)]
fun register_cap_from_wrong_vault_is_rejected() {
    let (mut ts, _vault_id, _cap_id) = setup();

    // Tx 4 (USER): create a SECOND vault, mint a cap against it, and try to
    // register that cap with the service pinned to the first vault.
    ts.next_tx(USER);
    {
        let mut service = ts.take_shared<Service>();

        let (other_vault, other_owner_cap) = spend_vault::new(ts.ctx());
        let foreign_cap = spend_vault::mint_cap(&other_vault, &other_owner_cap, ts.ctx());

        defi_keeper::register(&mut service, foreign_cap, ts.ctx()); // aborts here

        // Unreachable cleanup to keep the type checker satisfied.
        spend_vault::share(other_vault);
        transfer::public_transfer(other_owner_cap, USER);
        test_scenario::return_shared(service);
    };

    ts.end();
}
