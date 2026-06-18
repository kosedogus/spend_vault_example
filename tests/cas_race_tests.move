// === Scenario 4: Safe owner updates under a concurrent spend (CAS) ===
//
// An owner reads a grant's remaining budget, decides on a new value, and writes
// it, but a spend lands in between. Without a guard this silently inflates the
// budget: owner reads 400, spender draws 150, owner's "reduce to 50" hands the
// spender 50 on top of the 150 already drawn.
//
// The integration rule: on a read-then-write across transactions, pass the value
// you read as `expected`. The write then aborts EUnexpectedAllowance if the entry
// changed since; the remedy is to re-read and retry. (Reading and writing in one
// tx, as in Scenario 1 Tx 3, can never hit this; CAS is for the cross-tx case
// shown here.)
#[test_only]
module spend_vault_example::cas_race_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use spend_vault_example::coins::USDC;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario::{Self, Scenario};

const OWNER: address = @0xACE;
const SPENDER: address = @0xB0B;

const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

/// Shared setup that stages the race: a vault with a 400 USDC grant to SPENDER,
/// the owner reads `remaining == 400` (Tx 2), then a 150 spend is sequenced after
/// the read (Tx 3). Returns the scenario, the cap's ID, and the now-stale read.
fun setup_race(): (Scenario, ID, u64) {
    let mut ts = test_scenario::begin(OWNER);

    // Tx 1 (OWNER): create, fund, grant 400 USDC on a cap, share.
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

    // Tx 2 (OWNER): read the budget. Across transactions this is just a quote, and
    // it is stale the moment any later tx touches the vault.
    ts.next_tx(OWNER);
    let stale_read = {
        let vault = ts.take_shared<Vault>();
        let stale_read = spend_vault::allowance<USDC>(&vault, cap_id);
        assert!(stale_read == 400);
        test_scenario::return_shared(vault);
        stale_read
    };

    // Tx 3 (SPENDER): a 150 spend is sequenced between the read and the owner's
    // upcoming write. remaining is now 250.
    ts.next_tx(SPENDER);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let funds = spend_vault::spend<USDC>(&mut vault, &cap, 150, &clock, ts.ctx());
        transfer::public_transfer(funds.into_coin(ts.ctx()), SPENDER);

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    (ts, cap_id, stale_read)
}

// The guard fires: a write keyed to the stale read is blocked, not applied.
#[test]
#[expected_failure(abort_code = spend_vault::EUnexpectedAllowance)]
fun stale_write_aborts() {
    let (mut ts, cap_id, stale_read) = setup_race();

    // Tx 4 (OWNER): "reduce to 50" guarded by the Tx-2 read of 400. The entry now
    // holds 250, so the guard fires and nothing is written.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        spend_vault::set_allowance<USDC>(
            &mut vault, &owner_cap, cap_id,
            50, NO_EXPIRY,
            option::some(stale_read), // 400, stale: the write aborts
            &clock, ts.ctx(),
        );

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}

// The remedy: re-read and retry. The fresh guard matches and the reduction lands
// on the state the owner has actually seen.
#[test]
fun reread_and_retry_succeeds() {
    let (mut ts, cap_id, _stale_read) = setup_race();

    // Tx 4 (OWNER): re-read and write in the same tx. The fresh read (250)
    // matches, the guard passes, and the budget becomes 50.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let fresh_read = spend_vault::allowance<USDC>(&vault, cap_id);
        assert!(fresh_read == 250);
        spend_vault::set_allowance<USDC>(
            &mut vault, &owner_cap, cap_id,
            50, NO_EXPIRY,
            option::some(fresh_read),
            &clock, ts.ctx(),
        );
        assert!(spend_vault::allowance<USDC>(&vault, cap_id) == 50);

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}
