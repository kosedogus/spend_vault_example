// === Scenario 2: Protocol-embedded cap (the keeper service) ===
//
// Story: a user lets a keeper protocol top up positions from the user's own
// vault. The user's vault owner stays in control the whole time: the grant's
// budget is raised mid-custody with set_allowance and the SAME embedded cap
// keeps working. Registration never has to be repeated, because owner-side
// updates mutate the ledger entry in place and never touch the cap object.
//
// Three tests:
//   1. the happy path (register → topup → owner raises budget → topup again)
//   2. the sender gate: anyone who is not the operator is rejected BEFORE
//      the library ever sees the cap (the bearer-instrument lesson)
//   3. the custody-boundary binding check: a cap bound to a different vault
//      is rejected at register time
#[test_only]
module spend_vault_example::defi_keeper_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap};
use spend_vault_example::defi_keeper::{Self, Service};
use spend_vault_example::usdc::USDC;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario::{Self, Scenario};

const USER: address = @0xACE; // owns the vault AND registers with the keeper
const OPERATOR: address = @0xCAFE; // runs the keeper service
const MALLORY: address = @0xBAD; // not the operator

const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

/// Shared setup: USER creates + funds a vault (keeping the OwnerCap),
/// OPERATOR creates a service pinned to it, USER mints a 300-budget cap and
/// hands it into custody. Returns the scenario, the vault's ID, and the
/// cap's ID.
fun setup(): (Scenario, ID, ID) {
    let mut ts = test_scenario::begin(USER);

    // Tx 1 (USER): create + fund + share the vault; keep the OwnerCap.
    let vault_id = {
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(1_700_000_000_000);

        let (mut vault, owner_cap) = spend_vault::new<USDC>(ts.ctx());
        let vault_id = object::id(&vault);
        spend_vault::deposit(&mut vault, coin::mint_for_testing<USDC>(1_000, ts.ctx()), ts.ctx());
        spend_vault::share(vault);
        transfer::public_transfer(owner_cap, USER);
        clock.share_for_testing();
        vault_id
    };

    // Tx 2 (OPERATOR): create the keeper service pinned to that vault.
    ts.next_tx(OPERATOR);
    {
        defi_keeper::create<USDC>(vault_id, ts.ctx());
    };

    // Tx 3 (USER): mint a cap by value and hand it straight into custody.
    // mint_cap (not mint_and_transfer) is the embedding path: the cap never
    // needs to touch the user's wallet.
    ts.next_tx(USER);
    let cap_id = {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let mut service = ts.take_shared<Service<USDC>>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let cap = spend_vault::mint_cap(&mut vault, &owner_cap, 300, NO_EXPIRY, &clock, ts.ctx());
        let cap_id = object::id(&cap);
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
fun keeper_spends_and_cap_survives_owner_update() {
    let (mut ts, _vault_id, cap_id) = setup();

    // Tx 4 (OPERATOR): top up 100 through the custodied cap and route the
    // funds to the user. The library only sees `&SpenderCap`; it neither
    // knows nor cares that a protocol, not the original grantee, presented it.
    ts.next_tx(OPERATOR);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let mut service = ts.take_shared<Service<USDC>>();
        let clock = ts.take_shared<Clock>();

        let funds = defi_keeper::execute_topup(
            &mut service, &mut vault, USER, 100, &clock, ts.ctx(),
        );
        transfer::public_transfer(funds.into_coin(ts.ctx()), USER);

        assert!(spend_vault::allowance(&vault, cap_id) == 200);
        assert!(spend_vault::balance_value(&vault) == 900);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(service);
        test_scenario::return_shared(clock);
    };

    // Tx 5 (USER, as vault owner): raise the budget to 1_000 while the cap
    // sits inside the service. The owner only needs the cap's ID, never the
    // cap object. The entry mutates in place; the embedded cap is untouched.
    ts.next_tx(USER);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let current = spend_vault::allowance(&vault, cap_id);
        spend_vault::set_allowance(
            &mut vault, &owner_cap, cap_id,
            1_000, NO_EXPIRY,
            option::some(current), // CAS on a read-derived update, always
            &clock, ts.ctx(),
        );

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    // Tx 6 (OPERATOR): spend again under the NEW budget with the SAME
    // embedded cap. No re-registration happened. This is the property that
    // makes cap custody composable: owner maintenance never breaks
    // integrations holding the cap.
    ts.next_tx(OPERATOR);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let mut service = ts.take_shared<Service<USDC>>();
        let clock = ts.take_shared<Clock>();

        let funds = defi_keeper::execute_topup(
            &mut service, &mut vault, USER, 600, &clock, ts.ctx(),
        );
        transfer::public_transfer(funds.into_coin(ts.ctx()), USER);

        assert!(spend_vault::allowance(&vault, cap_id) == 400);
        assert!(spend_vault::balance_value(&vault) == 300);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(service);
        test_scenario::return_shared(clock);
    };

    ts.end();
}

// Protects the integration's security boundary: a `SpenderCap` is a bearer
// instrument, so the custody layer's sender gate is the ONLY thing standing
// between a custodied cap and the world. Without this assert, execute_topup
// would be world-drainable authority.
#[test]
#[expected_failure(abort_code = defi_keeper::ENotOperator)]
fun topup_by_non_operator_is_rejected() {
    let (mut ts, _vault_id, _cap_id) = setup();

    // Tx 4 (MALLORY): tries to drive the keeper's custodied cap.
    ts.next_tx(MALLORY);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let mut service = ts.take_shared<Service<USDC>>();
        let clock = ts.take_shared<Clock>();

        let funds = defi_keeper::execute_topup(
            &mut service, &mut vault, USER, 100, &clock, ts.ctx(),
        );
        funds.destroy_for_testing(); // unreachable, the gate aborts first

        test_scenario::return_shared(vault);
        test_scenario::return_shared(service);
        test_scenario::return_shared(clock);
    };

    ts.end();
}

// Protects the custody boundary: a protocol must validate a cap's vault
// binding before accepting it. A cap minted against some OTHER vault is
// rejected at register time, not discovered at spend time.
#[test]
#[expected_failure(abort_code = defi_keeper::EWrongVaultForService)]
fun register_cap_from_wrong_vault_is_rejected() {
    let (mut ts, _vault_id, _cap_id) = setup();

    // Tx 4 (USER): create a SECOND vault, mint a cap against it, and try to
    // register that cap with the service pinned to the first vault.
    ts.next_tx(USER);
    {
        let mut service = ts.take_shared<Service<USDC>>();
        let clock = ts.take_shared<Clock>();

        let (mut other_vault, other_owner_cap) = spend_vault::new<USDC>(ts.ctx());
        let foreign_cap = spend_vault::mint_cap(
            &mut other_vault, &other_owner_cap, 300, NO_EXPIRY, &clock, ts.ctx(),
        );

        defi_keeper::register(&mut service, foreign_cap, ts.ctx()); // aborts here

        // Unreachable cleanup to keep the borrow checker satisfied.
        spend_vault::share(other_vault);
        transfer::public_transfer(other_owner_cap, USER);
        test_scenario::return_shared(service);
        test_scenario::return_shared(clock);
    };

    ts.end();
}
