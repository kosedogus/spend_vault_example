# spend_vault_example

A standalone, end-to-end demonstration of `openzeppelin_allowance::spend_vault`
(v4, Path D): one **untyped, multi-coin** shared vault whose pool lives as SIP-58
address balances, and a bearer `SpenderCap` that carries an independent budget
per coin. It shows the two integration patterns the library is built for:
**direct delegation** to a known address, and the primary use case, a **protocol
custodying an embedded `SpenderCap`** behind a sender gate. The library is
vendored under `sources/library/` (code identical to upstream; doc comments
condensed for integrators), so the package builds and tests on its own.

## Layout

```
spend_vault_example/
├── Move.toml
├── sources/
│   ├── library/
│   │   └── spend_vault.move                vendored library (code identical to upstream; comments condensed)
│   └── integration/
│       └── defi_keeper.move                integrator-owned keeper service
└── tests/
    ├── coins.move                          test-only coin types (USDC, SUIT, DEEP)
    ├── direct_delegation_tests.move        S1: full multi-coin grant lifecycle
    ├── defi_keeper_tests.move              S2 + sender-gate / wrong-vault rejections
    ├── suspension_vs_revocation_tests.move S3: two aborts, two remedies
    ├── cas_race_tests.move                 S4: stale-write protection (CAS)
    ├── revoke_all_tests.move               S5: one-call whole-cap kill
    └── coin_type_gate_tests.move           F1: a cap can only spend coins it was budgeted for
```

Suggested reading order: `defi_keeper.move` (the flow and the security
boundary), then the tests in scenario order. Each test header tells its story,
and the numbered `Tx N (ACTOR)` comments let you scan a flow without reading the
code.

## Run

```
cd spend_vault_example && sui move test
```

Expected output:

```
[ PASS    ] spend_vault_example::cas_race_tests::reread_and_retry_succeeds
[ PASS    ] spend_vault_example::cas_race_tests::stale_write_aborts
[ PASS    ] spend_vault_example::coin_type_gate_tests::budgeted_coin_spends_fine
[ PASS    ] spend_vault_example::coin_type_gate_tests::unbudgeted_coin_is_gated
[ PASS    ] spend_vault_example::defi_keeper_tests::keeper_spends_multi_coin_and_cap_survives_owner_update
[ PASS    ] spend_vault_example::defi_keeper_tests::register_cap_from_wrong_vault_is_rejected
[ PASS    ] spend_vault_example::defi_keeper_tests::topup_by_non_operator_is_rejected
[ PASS    ] spend_vault_example::direct_delegation_tests::direct_delegation_full_lifecycle
[ PASS    ] spend_vault_example::revoke_all_tests::revoke_all_is_not_raced_by_a_front_running_spend
[ PASS    ] spend_vault_example::revoke_all_tests::revoke_all_kills_every_coin_in_one_call
[ PASS    ] spend_vault_example::revoke_all_tests::revoke_all_on_bare_cap_is_total
[ PASS    ] spend_vault_example::revoke_all_tests::spend_after_revoke_all_aborts_no_allowance
[ PASS    ] spend_vault_example::suspension_vs_revocation_tests::spend_after_revoke_aborts_no_allowance
[ PASS    ] spend_vault_example::suspension_vs_revocation_tests::spend_against_suspended_entry_aborts_exceeded
Test result: OK. Total tests: 14; passed: 14; failed: 0
```

## What this shows

The full life of a grant (create, fund two coins, bare-mint a cap, grant two
per-coin budgets, spend both through the one cap, renew with the CAS idiom, drain
to zero, renounce, tear down); that ONE untyped cap spans N coin budgets resolved
at the `spend<T>` call site (and a USDC update never touches the SUIT budget); a
keeper protocol accepting a cap into custody, with the on-chain vault-binding
check at the boundary and the sender gate a bearer-instrument cap makes
mandatory; that owner-side `set_allowance` never invalidates an embedded cap (no
re-registration, ever); the suspension (`EAllowanceExceeded`) vs revocation
(`ENoAllowance`) abort distinction that remedies key on; the opt-in CAS guard
that blocks stale budget writes plus the re-read-and-retry that resolves it;
`revoke_all` as the one-call, pool-independent answer to a leaked cap's
multi-coin blast radius (it never touches the pool, so a front-running spend
cannot race it into failure, which is why the robust emergency stop runs it
first, in its own tx); and the runtime coin-type gate (a cap budgeted for USDC
cannot draw SUIT even when the SUIT pool is full).