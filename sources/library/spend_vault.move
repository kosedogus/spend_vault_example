module openzeppelin_allowance::spend_vault;

use std::type_name::{Self, TypeName};
use sui::accumulator::AccumulatorRoot;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::linked_table::{Self, LinkedTable};
use sui::transfer::Receiving;
use sui::vec_set::{Self, VecSet};

// === Errors ===
//
// Dense codes 0..7, no reserved gaps. There is deliberately no
// `EInsufficientVault`: the pool-short case is the framework-native
// `InsufficientFundsForWithdraw` (fired at `redeem_funds`), the last abort on the
// spend/withdraw hot path.

/// Presented `OwnerCap` is bound to a different Vault. First check on every
/// owner-gated function.
#[error(code = 0)]
const EWrongOwnerCap: vector<u8> = b"OwnerCap does not match this Vault";

/// Presented `SpenderCap` is bound to a different Vault. First check in `spend`
/// and `renounce`.
#[error(code = 1)]
const EWrongVault: vector<u8> = b"SpenderCap does not match this Vault";

/// No `(cap, coin)` allowance entry: never granted, owner-revoked, or
/// spender-renounced. Remedy: a new grant. Spend-only: `set_allowance` is an
/// upsert and never aborts here. Distinct from `EAllowanceExceeded` on a suspended
/// entry (`remaining == 0`); `contains<T>` is the off-chain disambiguator.
#[error(code = 2)]
const ENoAllowance: vector<u8> = b"No allowance entry for this cap";

/// Entry exists with finite expiry and `now >= expires_at_ms` (closed boundary: a
/// spend in the exact millisecond of expiry fails). The `u64::MAX` sentinel never
/// expires.
#[error(code = 3)]
const EAllowanceExpired: vector<u8> = b"Allowance has expired";

/// `amount` exceeds the entry's `remaining`. Also fires on suspended entries
/// (`remaining == 0`) for any positive amount.
#[error(code = 4)]
const EAllowanceExceeded: vector<u8> = b"Amount exceeds remaining allowance";

/// Zero amount where zero is meaningless: `deposit`, `deposit_balance`, `spend`,
/// partial `withdraw`. `set_allowance` deliberately accepts 0 (suspension idiom);
/// `withdraw_all`/`destroy`/`squash` permit zero-value outcomes; `mint_cap` is
/// bare (no amount).
#[error(code = 5)]
const EZeroAmount: vector<u8> = b"Amount must be greater than zero";

/// Finite `new_expires_at_ms` was at or before `clock.timestamp_ms()` on
/// `set_allowance`. The `u64::MAX` sentinel is "no expiry" and always passes. A
/// future expiry revives an expired entry in place.
#[error(code = 6)]
const EExpiryInPast: vector<u8> = b"Expiry must be in the future";

/// CAS guard failed on `set_allowance`: the entry is absent, or its current
/// `remaining` does not equal `expected`. Re-read and retry.
#[error(code = 7)]
const EUnexpectedAllowance: vector<u8> = b"Current allowance does not match expected";

// === Structs ===

/// Shared, UNTYPED escrow + per-`(cap, coin)` allowance ledger. One vault holds N
/// coin types at once.
///
/// `key`-only: a Vault from `new` cannot be silently discarded (no `drop`) and
/// external modules cannot wrap or re-share it (no `store`). Its lifecycle is
/// exactly `new → share` or `new → destroy`, controlled solely by this module.
///
/// The pool is NOT a field here: per-coin funds live as object-owned SIP-58
/// address balances at `object::id(v).to_address()`. Key-only protects `id` (the
/// `&mut v.id` spend authority) and the ledger, and forces every teardown through
/// `destroy`.
///
/// - `allowances`: a `LinkedTable` (not `Table`) so `destroy`/`revoke_all`/
///   `renounce` can drain entries and recover each per-entry storage rebate.
/// - `granted_coin_types`: the owner-written enumeration handle that
///   `revoke_all`/`renounce` iterate on-chain. Written ONLY by a `set_allowance`
///   that creates an entry, so permissionless `deposit`/`squash` cannot inflate
///   it. It is NOT the drain-before-destroy list: that is off-chain
///   `getAllBalances`, which also surfaces stray `send_funds` types and loose coins.
public struct Vault has key {
    id: UID,
    allowances: LinkedTable<BudgetKey, Allowance>,
    granted_coin_types: VecSet<TypeName>,
}

/// Composite ledger key: one entry per `(cap, coin type)`. `copy + drop + store`
/// so it can serve as a `LinkedTable` key. `coin_type` is always
/// `type_name::with_defining_ids<T>()`.
public struct BudgetKey has copy, drop, store {
    cap_id: ID,
    coin_type: TypeName,
}

/// Owner authority for exactly one Vault. `key + store` (transferable +
/// custody-composable for multisig/DAO embedding and two-step-transfer wrapping).
/// Exactly ONE OwnerCap exists per Vault for its whole life: `new` mints it,
/// `destroy` consumes it. `vault_id` is set at `new` and never rewritten; transfer
/// of the cap IS owner rotation. It gates `withdraw`/`withdraw_all` over every
/// coin and `revoke_all` over every `(cap, coin)` entry.
public struct OwnerCap has key, store {
    id: UID,
    vault_id: ID,
}

/// Spend authority. **BEARER INSTRUMENT** (see the module-level warning):
/// presenting `&SpenderCap` to `spend<T>` exercises the full authority of every
/// `(cap, coin)` budget it keys, so a leaked cap exposes the SUM of its per-coin
/// budgets.
///
/// UNTYPED: no phantom, no coin-type field. The coin dimension is supplied by the
/// `T` argument at the `spend<T>` call site. `vault_id` is set at `mint_cap` and
/// never rewritten; the binding survives every transfer, wrap, or table embedding.
/// On-chain custodians should validate it via `spender_cap_vault_id` before
/// accepting a cap. No `copy`: spend authority cannot be duplicated.
public struct SpenderCap has key, store {
    id: UID,
    vault_id: ID,
}

/// Private ledger entry for one `(cap, coin)` grant. Not an object: reachable only
/// through this module's functions on the owning Vault, and the single source of
/// truth for the grant's state (the cap carries no budget). The coin type is in
/// the `BudgetKey`, not here, so one cap has N independent `Allowance` values.
///
/// `remaining`: `u64::MAX` is the UNLIMITED sentinel (never decremented); `0` is a
/// live-but-suspended entry; anything else is the raw drawable budget.
/// `expires_at_ms`: `u64::MAX` is the NO-EXPIRY sentinel; any finite value must be
/// strictly future at `set_allowance` time. `store` lets it live as a
/// `LinkedTable` value; `drop` allows clean disposal during drains.
public struct Allowance has store, drop {
    remaining: u64,
    expires_at_ms: u64,
}

// === Events ===
//
// One canonical event per state change; reads and `share` emit nothing. Events
// are untyped and carry a runtime `coin_type: TypeName` on coin-specific events,
// none on coin-agnostic ones. Module-private, so only this module can emit them.
// Each has a `#[test_only]` constructor at the foot of the module.

/// Emitted by `new`. `owner_cap_id` is the vault→cap discovery anchor: indexers
/// resolve current owner custody by following object-ownership changes of this
/// cap. `creator` is `ctx.sender()` at `new` and may differ from the eventual owner.
public struct VaultCreated has copy, drop {
    vault_id: ID,
    owner_cap_id: ID,
    creator: address,
}

/// Emitted by `deposit` and `deposit_balance`. `depositor` is indexer attribution
/// only; depositing confers no rights.
public struct Deposited has copy, drop {
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    depositor: address,
}

/// Emitted by `squash`. Distinct from `Deposited` so indexers can separate
/// recovered strays from real deposits.
public struct Squashed has copy, drop {
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    by: address,
}

/// Emitted by `mint_cap`. BARE: the cap carries no budget yet, so there is no
/// recipient / amount / expiry here; budget data rides on the subsequent
/// `AllowanceSet { was_created: true }`. `by` is `ctx.sender()`.
public struct SpenderCapMinted has copy, drop {
    vault_id: ID,
    cap_id: ID,
    by: address,
}

/// Emitted by `set_allowance`. `new_amount == 0` signals the suspension idiom
/// (entry and cap stay alive). `cas_was_provided` records whether the CAS guard
/// was engaged; `was_created` is `true` on the create branch, `false` on overwrite.
public struct AllowanceSet has copy, drop {
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    new_amount: u64,
    new_expires_at_ms: u64,
    cas_was_provided: bool,
    was_created: bool,
    by: address,
}

/// Emitted on every successful `spend`, strictly AFTER `redeem_funds` succeeds (so
/// a decremented-then-reverted pool-short spend emits nothing). `remaining` is the
/// entry's raw value after the call. `caller` is `ctx.sender()`: attribution, not
/// a gate, so in wrapper flows it is the wrapper's caller, not the cap holder.
public struct Spent has copy, drop {
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    amount: u64,
    remaining: u64,
    caller: address,
}

/// Emitted by `revoke` on every non-aborting call (including the idempotent
/// no-op), and by `revoke_all` once per removed coin. `was_present == false` means
/// nothing was actually removed (typo'd cap_id / wrong coin).
public struct Revoked has copy, drop {
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    was_present: bool,
    by: address,
}

/// Emitted by `renounce` (spender self-revoke). Coin-agnostic terminal event: it
/// removes every `(cap, *)` entry, so an indexer closes all of the cap's open
/// entries on it. `by` is `ctx.sender()`.
public struct Renounced has copy, drop {
    vault_id: ID,
    cap_id: ID,
    by: address,
}

/// Emitted by both `withdraw` and `withdraw_all`. `amount` is the actual value
/// extracted, possibly 0 from `withdraw_all` on an empty pool.
public struct Withdrawn has copy, drop {
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    by: address,
}

/// Emitted by `destroy`. Coin-agnostic terminal event for every `(vault, *)`
/// entry; indexers close all open entries under `vault_id` on it. No `refunded`
/// field: the owner drained each coin via `withdraw_all<T>` beforehand.
public struct VaultDestroyed has copy, drop {
    vault_id: ID,
    by: address,
}

/// Emitted by `delete_orphaned_cap`. Non-generic (a bare cap has no coin type in
/// scope): lets event-only indexers follow a cap deletion.
public struct CapDeleted has copy, drop {
    vault_id: ID,
    cap_id: ID,
}

// === Public Functions ===

// === Lifecycle ===

/// Create an UNTYPED, multi-coin Vault and its sole, vault-bound `OwnerCap`, both
/// returned BY VALUE.
///
/// One PTB composes the full setup atomically: `new → deposit<T> (×N) → mint_cap →
/// set_allowance<T> (×M) → share → transfer(owner_cap)`. Creator and owner can
/// differ: transfer the cap anywhere. The Vault has no `drop`, so the tx fails
/// unless it is consumed by `share` or `destroy` in the same tx.
///
/// #### Aborts
/// Never. Emits `VaultCreated { vault_id, owner_cap_id, creator }`.
public fun new(ctx: &mut TxContext): (Vault, OwnerCap) {
    let vault_uid = object::new(ctx);
    let vault_id = vault_uid.to_inner();

    let vault = Vault {
        id: vault_uid,
        allowances: linked_table::new<BudgetKey, Allowance>(ctx),
        granted_coin_types: vec_set::empty<TypeName>(),
    };

    let owner_cap = OwnerCap {
        id: object::new(ctx),
        vault_id,
    };

    event::emit(VaultCreated {
        vault_id,
        owner_cap_id: object::id(&owner_cap),
        creator: ctx.sender(),
    });

    (vault, owner_cap)
}

/// Share the Vault. Module-only entry point: `Vault` omits `store`, so external
/// modules cannot share it another way.
///
/// Must run in the same tx as `new`; there is no deferred-share path. After
/// `share`, the Vault is addressable as a shared input only in subsequent
/// transactions, so all same-PTB fund / grant / embed steps must precede it. No
/// event: sharing is platform-visible.
public fun share(v: Vault) {
    transfer::share_object(v);
}

/// Terminal owner exit: tear the vault down and reclaim its storage rebates.
///
/// > **DANGER: DRAIN THE POOL FIRST, OR FUNDS ARE LOST FOREVER.** `destroy`
/// > deletes the vault and the owner cap and drains the budget ledger, but it does
/// > NOT drain the pool. Any coin still held in the vault's address balances
/// > strands permanently at the dead vault address: with the UID gone, no cap and
/// > no transaction can ever reach it again. The vault cannot drain itself (Move
/// > cannot iterate runtime coin types), and no on-chain guard can stop a premature
/// > `destroy`, so the safe teardown is owner discipline:
/// >
/// > // 1. list EVERY coin type at the vault address (off-chain, complete):
/// > //      suix_getAllBalances(vault_address)
/// > // 2. fold in any loose Coins (shown as totalBalance > fundsInAddressBalance):
/// > //      squash<T>(&mut vault, receiving, ctx)
/// > // 3. drain every listed type, one call each:
/// > //      let bal = withdraw_all<T>(&mut vault, &owner_cap, &root, ctx)
/// > // 4. WAIT one checkpoint, then re-run getAllBalances; if non-empty, GOTO 2
/// > //    (a same-checkpoint deposit is invisible to step 3's settled read, so
/// > //     you cannot catch it by draining harder in one checkpoint)
/// > // 5. ONLY when getAllBalances reads empty across a settled checkpoint:
/// > //      destroy(vault, owner_cap, ctx)
/// >
/// > Drain in a PRIOR transaction, never the same PTB as `destroy`: a same-tx
/// > `send_funds` credit settles AFTER the drain read and strands. Residual: a
/// > permissionless deposit landing between step 4's check and step 5 strands, so
/// > time `destroy` when no deposits are expected. To merely stop a spender or
/// > freeze the vault, use `revoke_all` then `withdraw_all` (separate txs), which
/// > do NOT delete the vault.
///
/// Mechanics: consumes the Vault and OwnerCap by value, drains EVERY ledger entry
/// (recovering each per-entry storage rebate), deletes both UIDs, and returns
/// NOTHING (it cannot return N heterogeneous per-coin balances). The drain is O(n)
/// in live entries; for a very large ledger, batch-`revoke` first to spread gas
/// across txs. Teardown is never blockable by spender state.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: cap bound to a different Vault. Only abort.
public fun destroy(v: Vault, cap: OwnerCap, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(&v), EWrongOwnerCap);

    let Vault { id: vault_uid, mut allowances, granted_coin_types: _ } = v;
    let vault_id = vault_uid.to_inner();

    // Full drain. `destroy_empty` is the backstop; the loop empties a non-empty
    // table first. Each pop drops a (BudgetKey, Allowance) and recovers its rebate.
    while (!allowances.is_empty()) {
        let (_key, _entry) = allowances.pop_front();
    };
    allowances.destroy_empty();

    let OwnerCap { id: owner_cap_uid, vault_id: _ } = cap;
    vault_uid.delete();
    owner_cap_uid.delete();

    event::emit(VaultDestroyed { vault_id, by: ctx.sender() });
}

// === Fund (permissionless, confers no rights) ===

// NOTE (direct address-balance funding is a valid alternative). Because the pool
// IS the vault's SIP-58 address balance, anyone can fund it WITHOUT this module by
// calling `sui::balance::send_funds(bal, object::id(v).to_address())` directly (a
// `Coin<T>` via `c.into_balance()` first). Such funds are spendable and withdrawable
// identically to a `deposit`. The ONLY difference: a raw `send_funds` emits no typed
// `Deposited` event, so an event-only indexer won't see it (still visible via
// `getBalance`/`getAllBalances`). Use `deposit`/`deposit_balance` for the typed
// event; raw `send_funds` is a lighter permissionless top-up.

/// Add a `Coin<T>` to the vault's per-coin pool. PERMISSIONLESS: anyone may
/// deposit, and depositing confers NO rights (no entry, no claim, no refund path);
/// the funds become the owner's pool. Only fund a vault whose owner you trust.
///
/// Takes `&Vault`, not `&mut`: a deposit writes no on-chain state, so it mutates
/// nothing. `send_funds` needs only the vault's address; the funds land in the
/// SIP-58 address balance there.
///
/// CAVEAT: because deposits are permissionless and allowances are ceilings on the
/// pool, a deposit by anyone re-arms live allowances after a
/// `withdraw_all`-as-freeze. The durable kill-all is `revoke_all` or `destroy`,
/// not draining the pool.
///
/// #### Aborts (in order)
/// 1. `EZeroAmount`: `c.value() == 0`.
public fun deposit<T>(v: &Vault, c: Coin<T>, ctx: &TxContext) {
    let amount = c.value();
    assert!(amount > 0, EZeroAmount);

    c.into_balance().send_funds(object::id(v).to_address());

    event::emit(Deposited {
        vault_id: object::id(v),
        coin_type: type_name::with_defining_ids<T>(),
        amount,
        depositor: ctx.sender(),
    });
}

/// `Balance<T>`-native deposit: the symmetric ingress to the `Balance<T>` egress
/// of `spend`/`withdraw`/`withdraw_all`. The natural sink for a `spend` output
/// routed back into escrow, or for funding from any address balance the caller
/// controls. Same permissionless, rights-free, `&Vault` semantics as `deposit`.
///
/// #### Aborts (in order)
/// 1. `EZeroAmount`: `b.value() == 0`.
public fun deposit_balance<T>(v: &Vault, b: Balance<T>, ctx: &TxContext) {
    let amount = b.value();
    assert!(amount > 0, EZeroAmount);

    b.send_funds(object::id(v).to_address());

    event::emit(Deposited {
        vault_id: object::id(v),
        coin_type: type_name::with_defining_ids<T>(),
        amount,
        depositor: ctx.sender(),
    });
}

// === Cap + budgets (two owner verbs: mint_cap, set_allowance) ===

/// Owner-only. Mint a BARE, untyped `SpenderCap` and return it BY VALUE: no
/// budget, no ledger entry, no coin type yet. The caller decides the cap's
/// destination in the same PTB: `public_transfer` it to a delegate, or embed it by
/// value in a wrapper object / protocol record. Per-coin budgets are added
/// separately via `set_allowance<T>`.
///
/// Takes `&Vault` (it creates no ledger entry). The cap's `vault_id` binds it to
/// this vault for life and is never rewritten.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: cap bound to a different Vault. Only abort.
public fun mint_cap(v: &Vault, cap: &OwnerCap, ctx: &mut TxContext): SpenderCap {
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);

    let spender_cap = SpenderCap {
        id: object::new(ctx),
        vault_id: object::id(v),
    };
    let cap_id = object::id(&spender_cap);

    event::emit(SpenderCapMinted {
        vault_id: object::id(v),
        cap_id,
        by: ctx.sender(),
    });

    spender_cap
}

/// Owner-only. UPSERT the `(cap_id, T)` budget: create it if absent, else
/// overwrite `remaining` and `expires_at_ms` IN PLACE. The primary create-or-change
/// path; one cap accrues N independent per-coin budgets via N `set_allowance<T>`
/// calls.
///
/// Takes `cap_id: ID`, not `&SpenderCap`: the owner manages budgets without holding
/// the cap. The cap object, its ID, and every downstream embedding are untouched by
/// any change here, so a cap embedded in a protocol survives unlimited owner
/// updates and re-granting is never required.
///
/// - **Create vs overwrite.** Absent: create, recording `T` in
///   `granted_coin_types`. Present: overwrite. Re-setting a key OVERWRITES, it
///   never adds. Two summing budgets for one person require two caps.
/// - **Suspension.** `new_amount == 0` zeroes the budget but keeps the entry and
///   cap alive; the next `spend<T>` aborts `EAllowanceExceeded`. No `EZeroAmount`
///   here.
/// - **Revival.** A future `new_expires_at_ms` revives an expired entry in place.
/// - **CAS.** `expected = Some(e)` proceeds only if the entry exists AND its
///   current `remaining == e`; on an absent entry or a mismatch it aborts
///   `EUnexpectedAllowance`. The race-free idiom is `allowance<T>()` then
///   `set_allowance<T>(.., Some(result), ..)` in one PTB. `None` is the
///   unconditional create-or-overwrite. CAS compares the raw `remaining`.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: cap bound to a different Vault.
/// 2. `EExpiryInPast`: finite `new_expires_at_ms <= now`.
/// 3. `EUnexpectedAllowance`: CAS provided and the entry is absent or its current
///    `remaining` differs.
public fun set_allowance<T>(
    v: &mut Vault,
    cap: &OwnerCap,
    cap_id: ID,
    new_amount: u64,
    new_expires_at_ms: u64,
    expected: Option<u64>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let vault_id = object::id(v);

    // Precedence: owner gate, then expiry validity, then CAS. No ENoAllowance
    // (upsert), no EZeroAmount (0 = suspend).
    assert!(cap.vault_id == vault_id, EWrongOwnerCap);
    assert!(
        new_expires_at_ms == std::u64::max_value!()
            || new_expires_at_ms > clock.timestamp_ms(),
        EExpiryInPast, // the u64::MAX no-expiry sentinel always passes
    );

    let coin_type = type_name::with_defining_ids<T>();
    let key = BudgetKey { cap_id, coin_type };

    // CAS: compare-without-consuming against the raw `remaining`. `Some(e)` on an
    // absent entry must abort; the `contains` short-circuits the `&&`.
    let cas_was_provided = expected.is_some();
    if (cas_was_provided) {
        let e = expected.destroy_some();
        assert!(
            v.allowances.contains(key) && v.allowances.borrow(key).remaining == e,
            EUnexpectedAllowance,
        );
    };

    // Upsert: overwrite in place if present (cap_id + embeddings untouched), else
    // create and record the coin in `granted_coin_types`.
    let was_created = if (v.allowances.contains(key)) {
        let entry = v.allowances.borrow_mut(key);
        entry.remaining = new_amount;
        entry.expires_at_ms = new_expires_at_ms;
        false
    } else {
        v.allowances.push_back(
            key,
            Allowance { remaining: new_amount, expires_at_ms: new_expires_at_ms },
        );
        // Sole writer of `granted_coin_types`, and owner-gated, so permissionless
        // funding can never inflate the set the revoke paths iterate. Guard the
        // insert: `vec_set::insert` aborts on a duplicate.
        if (!v.granted_coin_types.contains(&coin_type)) {
            v.granted_coin_types.insert(coin_type);
        };
        true
    };

    event::emit(AllowanceSet {
        vault_id,
        cap_id,
        coin_type,
        new_amount,
        new_expires_at_ms,
        cas_was_provided,
        was_created,
        by: ctx.sender(),
    });
}

// === Spend (cap-gated, never sender-gated; exact-amount-or-abort) ===

/// Draw exactly `amount` of coin `T` against the presented `&SpenderCap`.
/// CAP-GATED, never sender-gated: any transaction context (an EOA, a protocol
/// module borrowing an embedded cap, a sponsored tx) spends identically.
/// `ctx.sender()` feeds `Spent.caller` only.
///
/// **Runtime coin-type gate.** The `(cap, T)` budget is resolved by the
/// `(cap_id, T)` key. A cap budgeted only for another coin aborts `ENoAllowance`
/// for this `T`: cross-coin safety is a runtime check.
///
/// EXACT-AMOUNT-OR-ABORT: success extracts exactly `amount` from the pool and
/// decrements `remaining` by exactly `amount`, unless `remaining == u64::MAX`,
/// which is never decremented. On ANY abort, the pool and every entry are unchanged.
///
/// Returns `Balance<T>` with no `drop`, so the caller MUST consume it: plumb it
/// onward in the same PTB (`into_coin`, `send_funds`, `deposit_balance`, a
/// downstream protocol call). Spend-to-zero leaves the entry in place; removal is
/// `revoke`/`revoke_all`/`renounce`/`destroy`.
///
/// **Ceiling, not guarantee + mixed error model.** An allowance is a ceiling on
/// the pool, not a reservation: a live, unexpired, within-budget spend can still
/// fail when the pool is short, and that failure is the framework-native
/// `InsufficientFundsForWithdraw` (fired at `redeem_funds`), NOT one of this
/// module's codes. Integrator preflight must handle the framework code too. The
/// error is deterministic and dry-run-visible.
///
/// #### Aborts (in order; deterministic integrator ABI)
/// 1. `EWrongVault`: cap bound to a different Vault.
/// 2. `ENoAllowance`: no `(cap, T)` entry (never granted, revoked, or a different
///    coin).
/// 3. `EAllowanceExpired`: finite expiry and `now >= expires_at_ms`.
/// 4. `EZeroAmount`: `amount == 0`.
/// 5. `EAllowanceExceeded`: finite `remaining` and `amount > remaining`; includes
///    suspended-at-zero.
/// 6. *(framework)* `InsufficientFundsForWithdraw`: pool short. NOT one of our codes.
public fun spend<T>(
    v: &mut Vault,
    cap: &SpenderCap,
    amount: u64,
    clock: &Clock,
    ctx: &TxContext,
): Balance<T> {
    let vault_id = object::id(v);
    let cap_id = object::id(cap);

    // 1. Binding gate, before any ledger access.
    assert!(cap.vault_id == vault_id, EWrongVault);

    let coin_type = type_name::with_defining_ids<T>();
    let key = BudgetKey { cap_id, coin_type };

    // 2. Existence. Absent (never granted / revoked / a different coin) is
    //    deliberately distinct from suspended-at-zero (check 5).
    assert!(v.allowances.contains(key), ENoAllowance);

    // Read phase: copy the two scalars; the immutable borrow ends here.
    let (remaining, expires_at_ms) = {
        let entry = v.allowances.borrow(key);
        (entry.remaining, entry.expires_at_ms)
    };

    // 3. Closed boundary: a spend in the exact millisecond of expiry fails. The
    //    no-expiry sentinel short-circuits by equality.
    assert!(
        expires_at_ms == std::u64::max_value!() || clock.timestamp_ms() < expires_at_ms,
        EAllowanceExpired,
    );

    // 4. No zero-value draws.
    assert!(amount > 0, EZeroAmount);

    // 5. Compare-before-decrement (no underflow path exists). The unlimited
    //    sentinel short-circuits by equality, no arithmetic.
    assert!(
        remaining == std::u64::max_value!() || amount <= remaining,
        EAllowanceExceeded,
    );

    // === Commit (all five checks passed; no library abort below) ===
    //
    // Order matters: decrement the budget, THEN draw from the pool. The pool is
    // not pre-checked; if it is short, `redeem_funds` aborts the framework-native
    // `InsufficientFundsForWithdraw` and Move's atomic revert rolls the decrement
    // back. No external call runs between the decrement and the withdraw.

    // Exact decrement; the unlimited sentinel is never decremented.
    let remaining_after = if (remaining == std::u64::max_value!()) {
        remaining
    } else {
        remaining - amount
    };
    v.allowances.borrow_mut(key).remaining = remaining_after;

    // Draw exactly `amount` from the per-coin address balance via `&mut v.id`: no
    // signer, only this module's cap-gated `&mut UID`. `withdraw_funds_from_object`
    // only builds the Withdrawal; the fund movement and the pool-short check both
    // happen at `redeem_funds`.
    let w = balance::withdraw_funds_from_object<T>(&mut v.id, amount);
    let bal = balance::redeem_funds(w);

    // Emit AFTER redeem succeeds: a reverted pool-short spend emits nothing.
    event::emit(Spent {
        vault_id,
        cap_id,
        coin_type,
        amount,
        remaining: remaining_after,
        caller: ctx.sender(),
    });

    bal
}

// === Revoke / renounce / cap disposal ===

/// Owner kill-switch for ONE coin: remove the `(cap_id, T)` entry. IDEMPOTENT and
/// ledger-state-independent: a present entry is removed, an absent one is a no-op,
/// and the return says which (`was_present == false` is the typo'd cap_id /
/// wrong-coin signal). No allowance state can make it abort: the kill-switch cannot
/// be raced into failure.
///
/// Strictly per-coin: revoking `(cap, USDC)` leaves every other coin of the cap
/// untouched. The coin type stays in `granted_coin_types` (grows-only); a later
/// `revoke_all`/`renounce` probe of it is a harmless no-op.
///
/// NOT retroactive: a spend sequenced before the owner's tx still succeeds. Pair
/// `revoke`/`revoke_all` (durably kills authority) with `withdraw_all` (sweeps
/// funds, but reversible by permissionless deposit) for emergencies. The cap OBJECT
/// survives in its holder's wallet as inert non-authority; dispose of it via
/// `renounce` (live vault) or `delete_orphaned_cap`.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: only abort.
public fun revoke<T>(v: &mut Vault, cap: &OwnerCap, cap_id: ID, ctx: &TxContext): bool {
    // Owner gate: the ONLY check, so no state can race this into failure.
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);

    let coin_type = type_name::with_defining_ids<T>();
    let key = BudgetKey { cap_id, coin_type };

    let was_present = if (v.allowances.contains(key)) {
        // Removal recovers the entry's storage rebate to this tx's gas payer.
        v.allowances.remove(key);
        true
    } else {
        false
    };

    // Emitted on EVERY non-aborting call, no-op included.
    event::emit(Revoked {
        vault_id: object::id(v),
        cap_id,
        coin_type,
        was_present,
        by: ctx.sender(),
    });

    was_present
}

/// Owner whole-cap kill: remove EVERY `(cap_id, T)` entry the cap holds, in one
/// call: the answer for a leaked cap spanning N budgets. Iterates the vault's
/// `granted_coin_types` and emits one `Revoked` per removed coin. A cap with no
/// entries emits nothing and still succeeds; total on ledger state, it cannot be
/// raced into failure.
///
/// Owner-bounded: it iterates `granted_coin_types`, written only by
/// `set_allowance`-create, so permissionless `deposit`/`squash` can never inflate
/// the loop. It never touches another cap's entries.
///
/// NOT retroactive. For an emergency stop, `revoke_all` is the PRIMARY action: run
/// it FIRST in its own tx (it never touches the pool, so it cannot be raced into
/// failure), THEN `withdraw_all<T>` per coin in a later tx (retry-safe). Do NOT
/// bundle them in one PTB: a same-checkpoint pool-short in `withdraw_all` would
/// revert the `revoke_all` with it.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: only abort.
public fun revoke_all(v: &mut Vault, cap: &OwnerCap, cap_id: ID, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);

    let vault_id = object::id(v);
    let by = ctx.sender();

    // Snapshot the owner-written type set (a copy) so the loop can mutate the
    // ledger with no outstanding immutable borrow of the vault. O(k) in the
    // owner-granted distinct coin types.
    let types = *v.granted_coin_types.keys();
    let n = types.length();
    let mut i = 0;
    while (i < n) {
        let coin_type = *types.borrow(i);
        let key = BudgetKey { cap_id, coin_type };
        if (v.allowances.contains(key)) {
            v.allowances.remove(key);
            event::emit(Revoked { vault_id, cap_id, coin_type, was_present: true, by });
        };
        i = i + 1;
    };
}

/// Spender self-revoke against a LIVE vault, whole-cap. Consumes the cap by value,
/// removes EVERY `(cap_id, T)` entry it holds, deletes the cap object: the only
/// path that removes both sides atomically. No inert authority-shaped garbage
/// survives, and each entry's storage rebate routes to this tx's gas payer.
///
/// Total on ledger state: a cap whose entries were already revoked still renounces
/// successfully (absent coins are harmless probes); the cap is always deleted.
/// Emits one coin-agnostic `Renounced`.
///
/// If the vault is already destroyed this is uncallable (no `&mut Vault` exists);
/// use `delete_orphaned_cap` for orphaned caps.
///
/// #### Aborts (in order)
/// 1. `EWrongVault`: cap bound to a different Vault. Only abort.
public fun renounce(v: &mut Vault, cap: SpenderCap, ctx: &TxContext) {
    let vault_id = object::id(v);
    assert!(cap.vault_id == vault_id, EWrongVault);

    let SpenderCap { id, vault_id: _ } = cap;
    let cap_id = id.to_inner();

    // Remove every (cap, T) entry the cap holds. Snapshot the type set (copy) so
    // the loop can mutate the ledger; absent coins are harmless no-op probes.
    let types = *v.granted_coin_types.keys();
    let n = types.length();
    let mut i = 0;
    while (i < n) {
        let key = BudgetKey { cap_id, coin_type: *types.borrow(i) };
        if (v.allowances.contains(key)) {
            v.allowances.remove(key);
        };
        i = i + 1;
    };

    id.delete();

    event::emit(Renounced { vault_id, cap_id, by: ctx.sender() });
}

/// Dispose of an ORPHANED cap, one whose vault was already `destroy`ed. `renounce`
/// is the live-vault path (it needs `&mut Vault`, gone after teardown); this is its
/// vault-less counterpart. Never aborts, touches no vault state, deletes exactly
/// the cap's UID, and emits `CapDeleted { vault_id, cap_id }`.
///
/// **On a LIVE vault, prefer `renounce`.** Deleting a live cap STRANDS ALL of its
/// `(cap, T)` entries at once. Each becomes inert (unspendable, not live authority)
/// but lingers in the ledger, still visible via `contains<T>`, and you forfeit the
/// storage rebates `renounce` would have recovered.
///
/// **Owner cleanup of a stranded cap:** take the `cap_id` from the `CapDeleted`
/// event (or your issuance records) and call `revoke_all(&mut vault, &owner_cap,
/// cap_id, ctx)` to remove the entries and reclaim their rebate. Optional: the
/// entries are inert, and `destroy` drains the whole ledger regardless.
public fun delete_orphaned_cap(cap: SpenderCap) {
    let SpenderCap { id, vault_id } = cap;
    let cap_id = id.to_inner();
    id.delete();

    event::emit(CapDeleted { vault_id, cap_id });
}

// === Recovery ===

/// Recover a stray `Coin<T>` that was `public_transfer`'d to the vault address (it
/// lands as a loose owned object, counted in the address's totals but NOT in the
/// spendable address balance) by folding it back into the per-coin pool.
/// PERMISSIONLESS and STRICTLY FUNDS-IN: it can only move value INTO the pool,
/// never out or elsewhere, so exposing it to the world has no griefing or
/// extraction vector (the worst a caller can do is donate). Emits `Squashed`
/// (distinct from `Deposited` so indexers separate recovered strays).
///
/// Recovers only strays sent to THIS vault: a generic cross-address squash is
/// unbuildable (you cannot consume a coin you do not control). It needs `&mut v.id`
/// only for `public_receive`.
///
/// #### Aborts
/// Never on pool/ledger state. (The framework `public_receive` can abort on an
/// invalid or stale `Receiving` ticket: a framework guarantee, not a library abort.)
public fun squash<T>(v: &mut Vault, c: Receiving<Coin<T>>, ctx: &TxContext) {
    let vault_id = object::id(v);

    let coin = transfer::public_receive(&mut v.id, c);
    let amount = coin.value();
    coin.into_balance().send_funds(vault_id.to_address());

    event::emit(Squashed {
        vault_id,
        coin_type: type_name::with_defining_ids<T>(),
        amount,
        by: ctx.sender(),
    });
}

// === Owner exit (consults only the cap binding + pool, never the ledger) ===

/// Owner-only. Withdraw exactly `amount` of coin `T` from the pool as `Balance<T>`.
/// May leave live allowances unbacked: intended (allowances are ceilings; the next
/// over-pool spend aborts the native pool-short error with a live budget).
///
/// Consults only the OwnerCap binding and the pool, never the ledger, so no spender
/// state can block it. Pool-short is the framework-native
/// `InsufficientFundsForWithdraw` at `redeem_funds`, consistent with `spend`.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: cap bound to a different Vault.
/// 2. `EZeroAmount`: `amount == 0`.
/// 3. *(framework)* `InsufficientFundsForWithdraw`: `amount > pool`.
public fun withdraw<T>(
    v: &mut Vault,
    cap: &OwnerCap,
    amount: u64,
    ctx: &TxContext,
): Balance<T> {
    let vault_id = object::id(v);
    assert!(cap.vault_id == vault_id, EWrongOwnerCap);
    assert!(amount > 0, EZeroAmount);

    let w = balance::withdraw_funds_from_object<T>(&mut v.id, amount);
    let bal = balance::redeem_funds(w);

    event::emit(Withdrawn {
        vault_id,
        coin_type: type_name::with_defining_ids<T>(),
        amount,
        by: ctx.sender(),
    });

    bal
}

/// Owner-only. Drain the SETTLED `T` pool as a possibly-zero `Balance<T>`. It reads
/// `settled_funds_value<T>(root, vault_address)` (the START-OF-CHECKPOINT snapshot)
/// and withdraws exactly that. There is deliberately no caller-supplied amount: a
/// fixed amount would be a stale-amount DoS. An empty settled pool returns a zero
/// `Balance<T>` (consume it via `destroy_zero` or a join) without touching the
/// accumulator.
///
/// **NOT abort-free against the pool.** The settled read disagrees with
/// `redeem_funds`'s LIVE check whenever the pool moved earlier in the SAME
/// checkpoint (a prior `spend`/`withdraw` on this vault, including an earlier
/// command in the same PTB):
/// - over-ask → abort: a prior same-checkpoint `spend` lowers the live pool below
///   the settled snapshot, so the withdraw aborts the framework-native
///   `InsufficientFundsForWithdraw` (even `spend(1)` trips it);
/// - under-drain: a same-checkpoint `deposit` is not yet in the snapshot, so the
///   drain misses it.
/// Both are RETRY-SAFE: the next checkpoint settles and a retry succeeds. It still
/// NEVER aborts on spender/ledger state.
///
/// Call once per coin type in the drain-before-`destroy` ritual, enumerating types
/// off-chain via `getAllBalances`. Do NOT sequence it after a `spend`/`withdraw` on
/// this vault in the same PTB (deterministic abort).
///
/// CAVEAT: `withdraw_all`-as-freeze is REVERSIBLE: `deposit` is permissionless, so
/// anyone can re-arm live allowances by topping up the pool. The durable kill-all
/// is `revoke_all` or `destroy`. For an emergency stop, run `revoke_all` FIRST in
/// its own tx (pool-independent, cannot be raced), THEN `withdraw_all` in a later
/// tx; do NOT bundle them, or a front-run `spend(1)` reverts the whole PTB and
/// rolls back the `revoke_all` with it.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: cap bound to a different Vault.
/// 2. *(framework)* `InsufficientFundsForWithdraw`: the live pool fell below the
///    settled snapshot earlier in this checkpoint (retry-safe). Never aborts on
///    spender/ledger state.
public fun withdraw_all<T>(
    v: &mut Vault,
    cap: &OwnerCap,
    root: &AccumulatorRoot,
    ctx: &TxContext,
): Balance<T> {
    let vault_id = object::id(v);
    assert!(cap.vault_id == vault_id, EWrongOwnerCap);

    // Drain-exact: read the SETTLED (start-of-checkpoint) pool and withdraw exactly
    // it. This settled value can over-ask the LIVE balance if a prior
    // same-checkpoint spend/withdraw lowered it, so redeem may abort the native
    // pool-short (retry-safe next checkpoint). The empty settled case is a clean
    // zero-balance no-op that never reaches the flagged primitive.
    let amount = balance::settled_funds_value<T>(root, vault_id.to_address());
    let bal = if (amount == 0) {
        balance::zero<T>()
    } else {
        let w = balance::withdraw_funds_from_object<T>(&mut v.id, amount);
        balance::redeem_funds(w)
    };

    event::emit(Withdrawn {
        vault_id,
        coin_type: type_name::with_defining_ids<T>(),
        amount,
        by: ctx.sender(),
    });

    bal
}

// === Reads ===

// All reads are TOTAL (never abort, any input, any vault state) and ADVISORY
// (stale the moment a later tx mutates the vault or pool). Cross-tx
// check-then-act is unsound; within one PTB the shared Vault is locked for the
// whole tx, so read → decide → write is atomic (the CAS idiom on
// `set_allowance`). Pool-reading reads take the `AccumulatorRoot`.

/// Raw `remaining` for `(cap, T)`; `0` if absent. Ambiguous at 0: suspended and
/// absent both read 0, disambiguate with `contains`. `u64::MAX` is the unlimited
/// sentinel, not a volume.
public fun allowance<T>(v: &Vault, cap_id: ID): u64 {
    let key = budget_key<T>(cap_id);
    if (v.allowances.contains(key)) {
        v.allowances.borrow(key).remaining
    } else {
        0
    }
}

/// What a `spend<T>` through this entry could draw RIGHT NOW: `0` if absent or
/// expired, else `min(remaining, settled_pool)`; for an unlimited entry this
/// reduces to the settled pool. ADVISORY UPPER BOUND, not a guarantee: the pool
/// term is the SETTLED (start-of-checkpoint) value, so `spend<T>(spendable_now<T>(…))`
/// can still abort the native pool-short if a prior same-checkpoint op reduced the
/// LIVE pool below this quote. Time and budget do hold (no intervening mutation).
/// Guard `> 0` before feeding it to `spend`: a zero quote aborts `EZeroAmount`.
public fun spendable_now<T>(
    v: &Vault,
    cap_id: ID,
    root: &AccumulatorRoot,
    clock: &Clock,
): u64 {
    let key = budget_key<T>(cap_id);
    if (!v.allowances.contains(key)) {
        return 0
    };
    let entry = v.allowances.borrow(key);
    // Same closed boundary as `spend` check 3.
    if (entry.expires_at_ms != std::u64::max_value!()
        && clock.timestamp_ms() >= entry.expires_at_ms) {
        return 0
    };
    // The u64::MAX sentinel is min's neutral element: unlimited reduces to the
    // settled pool with no special case.
    entry.remaining.min(balance::settled_funds_value<T>(root, object::id(v).to_address()))
}

/// Raw `expires_at_ms` for `(cap, T)`; `0` if absent. `u64::MAX` is the no-expiry
/// sentinel.
public fun expiry<T>(v: &Vault, cap_id: ID): u64 {
    let key = budget_key<T>(cap_id);
    if (v.allowances.contains(key)) {
        v.allowances.borrow(key).expires_at_ms
    } else {
        0
    }
}

/// Ledger membership for `(cap, T)`: the absent-vs-suspended disambiguator.
/// `allowance == 0 && contains` is a suspended (or drained) entry whose cap is
/// still valid; `!contains` is never-granted / revoked / renounced.
public fun contains<T>(v: &Vault, cap_id: ID): bool {
    v.allowances.contains(budget_key<T>(cap_id))
}

/// The settled `T` pool at the vault's address (the START-OF-CHECKPOINT snapshot;
/// advisory). NOTE: deriving a `withdraw(amount)` from this read can still abort
/// native pool-short if the live pool dropped since the read.
public fun balance_value<T>(v: &Vault, root: &AccumulatorRoot): u64 {
    balance::settled_funds_value<T>(root, object::id(v).to_address())
}

/// The coin types the OWNER has granted: exactly what `revoke_all`/`renounce`
/// iterate (SDK / indexer aid). NOTE: this is NOT the drain-before-`destroy` list:
/// that is off-chain `getAllBalances(vault_address)`, which also surfaces stray
/// `send_funds` types and loose coins.
public fun granted_coin_types(v: &Vault): vector<TypeName> {
    *v.granted_coin_types.keys()
}

/// The Vault this OwnerCap is bound to: on-chain custodians validate the binding
/// before accepting a cap.
public fun owner_cap_vault_id(cap: &OwnerCap): ID {
    cap.vault_id
}

/// The Vault this SpenderCap is bound to: protocols accepting a user's cap MUST
/// check this against the expected vault before custody (see the module-level
/// bearer-cap warning).
public fun spender_cap_vault_id(cap: &SpenderCap): ID {
    cap.vault_id
}

// === Private Helpers ===

/// Build the composite ledger key for `(cap_id, T)`. The canonical
/// `with_defining_ids<T>()` (never the deprecated `get`) keeps keys stable across
/// grant and spend. Used by the read paths; the mutating paths build the key inline
/// because they also emit `coin_type` in their event.
fun budget_key<T>(cap_id: ID): BudgetKey {
    BudgetKey { cap_id, coin_type: type_name::with_defining_ids<T>() }
}

// === Test-Only Helpers ===

// Event-value constructors for test-side equality assertions (the events are
// otherwise module-private and unconstructable). One per event, matching the
// untyped + runtime `coin_type` schema.

#[test_only]
public fun test_new_vault_created(
    vault_id: ID,
    owner_cap_id: ID,
    creator: address,
): VaultCreated {
    VaultCreated { vault_id, owner_cap_id, creator }
}

#[test_only]
public fun test_new_deposited(
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    depositor: address,
): Deposited {
    Deposited { vault_id, coin_type, amount, depositor }
}

#[test_only]
public fun test_new_squashed(
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    by: address,
): Squashed {
    Squashed { vault_id, coin_type, amount, by }
}

#[test_only]
public fun test_new_spender_cap_minted(vault_id: ID, cap_id: ID, by: address): SpenderCapMinted {
    SpenderCapMinted { vault_id, cap_id, by }
}

#[test_only]
public fun test_new_allowance_set(
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    new_amount: u64,
    new_expires_at_ms: u64,
    cas_was_provided: bool,
    was_created: bool,
    by: address,
): AllowanceSet {
    AllowanceSet {
        vault_id,
        cap_id,
        coin_type,
        new_amount,
        new_expires_at_ms,
        cas_was_provided,
        was_created,
        by,
    }
}

#[test_only]
public fun test_new_spent(
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    amount: u64,
    remaining: u64,
    caller: address,
): Spent {
    Spent { vault_id, cap_id, coin_type, amount, remaining, caller }
}

#[test_only]
public fun test_new_revoked(
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    was_present: bool,
    by: address,
): Revoked {
    Revoked { vault_id, cap_id, coin_type, was_present, by }
}

#[test_only]
public fun test_new_renounced(vault_id: ID, cap_id: ID, by: address): Renounced {
    Renounced { vault_id, cap_id, by }
}

#[test_only]
public fun test_new_withdrawn(
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    by: address,
): Withdrawn {
    Withdrawn { vault_id, coin_type, amount, by }
}

#[test_only]
public fun test_new_vault_destroyed(vault_id: ID, by: address): VaultDestroyed {
    VaultDestroyed { vault_id, by }
}

#[test_only]
public fun test_new_cap_deleted(vault_id: ID, cap_id: ID): CapDeleted {
    CapDeleted { vault_id, cap_id }
}
