# spend_vault_example

A standalone, end-to-end demonstration of `openzeppelin_allowance::spend_vault`,
a cap-keyed coin-allowance vault for Sui. It shows the two integration
patterns the library is built for: **direct delegation** to a known address,
and the primary use case, a **protocol custodying an embedded `SpenderCap`**
behind a sender gate.

## Layout

```
spend_vault_example/
├── Move.toml
├── sources/
│   ├── library/
│   │   └── spend_vault.move              vendored library (code identical to
│   │                                     upstream; comments condensed for
│   │                                     integrators)
│   └── integration/
│       └── defi_keeper.move              integrator-owned keeper service
└── tests/
    ├── usdc.move                         test-only coin type
    ├── direct_delegation_tests.move      Scenario 1: full grant lifecycle
    ├── defi_keeper_tests.move            Scenario 2: protocol-embedded cap
    ├── suspension_vs_revocation_tests.move  Scenario 3: two aborts, two remedies
    └── cas_race_tests.move               Scenario 4: stale-write protection
```

Suggested reading order: `defi_keeper.move` (the flow and the security
boundary), then the tests in scenario order. Each test header tells its
story, and the numbered `Tx N (ACTOR)` comments let you scan a flow without
reading the code.

## Run

```
cd spend_vault_example && sui move test --build-env testnet
```

Expected output:

```
[ PASS    ] spend_vault_example::defi_keeper_tests::keeper_spends_and_cap_survives_owner_update
[ PASS    ] spend_vault_example::defi_keeper_tests::register_cap_from_wrong_vault_is_rejected
[ PASS    ] spend_vault_example::defi_keeper_tests::topup_by_non_operator_is_rejected
[ PASS    ] spend_vault_example::direct_delegation_tests::direct_delegation_full_lifecycle
[ PASS    ] spend_vault_example::suspension_vs_revocation_tests::spend_after_revoke_aborts_no_allowance
[ PASS    ] spend_vault_example::suspension_vs_revocation_tests::spend_against_suspended_entry_aborts_exceeded
[ PASS    ] spend_vault_example::cas_race_tests::reread_and_retry_succeeds
[ PASS    ] spend_vault_example::cas_race_tests::stale_write_aborts
Test result: OK. Total tests: 8; passed: 8; failed: 0
```

## What this shows

The full life of a grant (create → fund → grant → spend → renew → drain →
renounce → destroy); a keeper protocol accepting a cap into custody, with
the on-chain vault-binding check at the boundary and the sender gate that a
bearer-instrument cap makes mandatory; that owner-side `set_allowance` never
invalidates an embedded cap (no re-registration, ever); the suspension
(`EAllowanceExceeded`) vs revocation (`ENoAllowance`) abort distinction that
remedies key on; and the opt-in CAS guard that blocks stale budget writes,
plus the re-read-and-retry that resolves it.

