// === Scenario 1: Direct delegation, full lifecycle ===
//
// Story: a treasury delegates a budget to a contractor it knows by address.
// No integrator module is needed; for this pattern the library API *is*
// the integrator API. The walkthrough covers the whole life of a grant:
// create + fund + grant in one tx, spend, renew with the CAS idiom, drain
// to zero (entry stays, "lazy zero"), spender exit, owner teardown.
#[test_only]
module spend_vault_example::direct_delegation_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use spend_vault_example::usdc::USDC;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::event;
use sui::test_scenario;

const TREASURY: address = @0xACE;
const CONTRACTOR: address = @0xB0B;

const DAY_MS: u64 = 86_400_000;
const NOW_MS: u64 = 1_000 * DAY_MS; // arbitrary test "now"

#[test]
fun direct_delegation_full_lifecycle() {
    let mut ts = test_scenario::begin(TREASURY);

    // Tx 1 (TREASURY): create the vault, fund it with 1_000 USDC, grant the
    // contractor a 400 budget expiring in 30 days, share the vault, keep the
    // OwnerCap. One tx, the same shape as the canonical setup PTB: the Vault
    // has no `drop`, so the tx only succeeds because `share` consumes it.
    {
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.set_for_testing(NOW_MS);

        let (mut vault, owner_cap) = spend_vault::new<USDC>(ts.ctx());
        spend_vault::deposit(&mut vault, coin::mint_for_testing<USDC>(1_000, ts.ctx()), ts.ctx());
        spend_vault::mint_and_transfer(
            &mut vault,
            &owner_cap,
            400,
            NOW_MS + 30 * DAY_MS,
            CONTRACTOR,
            &clock,
            ts.ctx(),
        );
        spend_vault::share(vault);
        transfer::public_transfer(owner_cap, TREASURY);
        clock.share_for_testing();
    };

    // Tx 2 (CONTRACTOR): spend 150 against the cap. The returned
    // Balance<USDC> has no `drop`, so it MUST be routed somewhere; here it
    // becomes a Coin in the contractor's wallet.
    ts.next_tx(CONTRACTOR);
    let cap_id = {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();
        let cap_id = object::id(&cap);

        let funds = spend_vault::spend(&mut vault, &cap, 150, &clock, ts.ctx());
        transfer::public_transfer(funds.into_coin(ts.ctx()), CONTRACTOR);

        assert!(spend_vault::allowance(&vault, cap_id) == 250);
        assert!(spend_vault::balance_value(&vault) == 850);
        // Event check via the library's test constructor: amount drawn this
        // call + raw remaining after it, attributed to the tx sender.
        assert!(
            event::events_by_type<spend_vault::Spent<USDC>>() ==
                vector[spend_vault::test_new_spent<USDC>(
                    object::id(&vault), cap_id, 150, 250, CONTRACTOR,
                )],
        );

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
        cap_id
    };

    // Tx 3 (TREASURY): raise the budget to 500 and renew the expiry. Read
    // and write in ONE tx: the shared Vault is locked for the whole tx, so
    // passing the read result as `expected` can never hit a stale state.
    // This is the documented race-free CAS idiom; the failure mode it
    // prevents is Scenario 4's subject.
    ts.next_tx(TREASURY);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let current = spend_vault::allowance(&vault, cap_id);
        assert!(current == 250);
        spend_vault::set_allowance(
            &mut vault,
            &owner_cap,
            cap_id,
            500,
            NOW_MS + 60 * DAY_MS,
            option::some(current),
            &clock,
            ts.ctx(),
        );
        assert!(spend_vault::allowance(&vault, cap_id) == 500);

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    // Tx 4 (CONTRACTOR): drain the renewed budget exactly. The entry stays
    // in the ledger at zero ("lazy zero"): the cap is still valid and the
    // owner could resume it with another set_allowance. Drained and
    // suspended are the same observable state.
    ts.next_tx(CONTRACTOR);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let funds = spend_vault::spend(&mut vault, &cap, 500, &clock, ts.ctx());
        transfer::public_transfer(funds.into_coin(ts.ctx()), CONTRACTOR);

        assert!(spend_vault::allowance(&vault, cap_id) == 0);
        assert!(spend_vault::contains(&vault, cap_id)); // entry survives at zero
        assert!(spend_vault::balance_value(&vault) == 350);

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    // Tx 5 (CONTRACTOR): done with the engagement, renounce. This is the
    // one call that removes BOTH sides at once: the ledger entry and the cap
    // object. Nothing authority-shaped is left in the contractor's wallet.
    ts.next_tx(CONTRACTOR);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let cap = ts.take_from_sender<SpenderCap>();

        spend_vault::renounce(&mut vault, cap, ts.ctx());
        assert!(!spend_vault::contains(&vault, cap_id));

        test_scenario::return_shared(vault);
    };

    // Tx 6 (TREASURY): tear down. `destroy` consumes the Vault and the
    // OwnerCap and returns the leftover pool as a Coin. The ledger is
    // already empty, but destroy would drain it regardless: no spender
    // state can ever block the owner's exit.
    ts.next_tx(TREASURY);
    {
        let vault = ts.take_shared<Vault<USDC>>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let refund = spend_vault::destroy(vault, owner_cap, ts.ctx());
        assert!(refund.value() == 350);
        transfer::public_transfer(refund, TREASURY);
    };

    ts.end();
}
