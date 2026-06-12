// === Scenario 4: The CAS race, stale write blocked, re-read retry lands ===
//
// Story: an owner reads a grant's remaining budget, decides on a new value,
// and writes it, but a spend lands in between. Without protection this is
// silent budget inflation: owner reads 400, spender draws 150, owner's
// "reduce to 50" hands the spender 50 ON TOP of the 150 already drawn.
//
// The library's answer is opt-in compare-and-set on set_allowance: pass the
// value you read as `expected`, and the write aborts EUnexpectedAllowance
// (code 8) if the entry changed since. The remedy is mechanical: re-read,
// re-decide, retry. (When the read and write share one tx, as in Scenario 1
// Tx 3, the vault is locked in between and CAS can never fire; CAS exists
// for exactly the cross-tx flow shown here.)
#[test_only]
module spend_vault_example::cas_race_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use spend_vault_example::usdc::USDC;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario::{Self, Scenario};

const OWNER: address = @0xACE;
const SPENDER: address = @0xB0B;

const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

/// Shared setup: a vault with 1_000 pool and a live 400 grant to SPENDER,
/// then the race itself: the owner reads `remaining == 400` (Tx 2), and a
/// 150 spend is sequenced after the read (Tx 3). Returns the scenario, the
/// cap's ID, and the owner's now-stale read.
fun setup_race(): (Scenario, ID, u64) {
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

    // Tx 2 (OWNER): read the budget. Cross-tx, so this is already stale the
    // moment any later tx touches the vault; reads are quotes, not locks.
    ts.next_tx(OWNER);
    let (cap_id, stale_read) = {
        let vault = ts.take_shared<Vault<USDC>>();
        let cap_id = test_scenario::most_recent_id_for_address<SpenderCap>(SPENDER).extract();
        let stale_read = spend_vault::allowance(&vault, cap_id);
        assert!(stale_read == 400);
        test_scenario::return_shared(vault);
        (cap_id, stale_read)
    };

    // Tx 3 (SPENDER): a 150 spend is sequenced between the read and the
    // owner's upcoming write. remaining is now 250.
    ts.next_tx(SPENDER);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let clock = ts.take_shared<Clock>();
        let cap = ts.take_from_sender<SpenderCap>();

        let funds = spend_vault::spend(&mut vault, &cap, 150, &clock, ts.ctx());
        transfer::public_transfer(funds.into_coin(ts.ctx()), SPENDER);

        ts.return_to_sender(cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    (ts, cap_id, stale_read)
}

// Protects the CAS guard: the stale write is blocked, not applied.
#[test]
#[expected_failure(abort_code = spend_vault::EUnexpectedAllowance)]
fun stale_write_aborts() {
    let (mut ts, cap_id, stale_read) = setup_race();

    // Tx 4 (OWNER): write "reduce to 50" guarded by the Tx-2 read. The entry
    // now holds 250, not 400: the guard fires and nothing is written.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        spend_vault::set_allowance(
            &mut vault, &owner_cap, cap_id,
            50, NO_EXPIRY,
            option::some(stale_read), // 400, stale: aborts with code 8
            &clock, ts.ctx(),
        );

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}

// The other half of the discipline: after a CAS abort, re-read and retry.
// The fresh guard matches and the reduction lands on accurate state.
#[test]
fun reread_and_retry_succeeds() {
    let (mut ts, cap_id, _stale_read) = setup_race();

    // Tx 4 (OWNER): re-read and write in the same tx. The fresh read (250)
    // matches the entry, the guard passes, and the budget becomes 50,
    // applied to the post-spend state the owner has actually seen.
    ts.next_tx(OWNER);
    {
        let mut vault = ts.take_shared<Vault<USDC>>();
        let clock = ts.take_shared<Clock>();
        let owner_cap = ts.take_from_sender<OwnerCap>();

        let fresh_read = spend_vault::allowance(&vault, cap_id);
        assert!(fresh_read == 250);
        spend_vault::set_allowance(
            &mut vault, &owner_cap, cap_id,
            50, NO_EXPIRY,
            option::some(fresh_read),
            &clock, ts.ctx(),
        );
        assert!(spend_vault::allowance(&vault, cap_id) == 50);

        ts.return_to_sender(owner_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(clock);
    };

    ts.end();
}
