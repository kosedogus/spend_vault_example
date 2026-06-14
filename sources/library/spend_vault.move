module openzeppelin_allowance::spend_vault;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::linked_table::{Self, LinkedTable};

// === Errors ===

/// Presented `OwnerCap` is bound to a different Vault. First check on every
/// owner-gated function.
#[error(code = 0)]
const EWrongOwnerCap: vector<u8> = "OwnerCap does not match this Vault";

/// Presented `SpenderCap` is bound to a different Vault. First check in
/// `spend` and `renounce`.
#[error(code = 1)]
const EWrongVault: vector<u8> = "SpenderCap does not match this Vault";

/// No allowance entry for this cap_id: never granted, owner-revoked, or
/// spender-renounced. Remedy: a new grant. Distinct from
/// `EAllowanceExceeded` on a suspended entry (`remaining == 0`), whose
/// remedy is asking the owner to raise. `set_allowance` is update-only and
/// aborts here on absent cap_ids, never an upsert.
#[error(code = 2)]
const ENoAllowance: vector<u8> = "No allowance entry for this cap";

/// Entry exists with finite expiry and `now >= expires_at_ms` (closed
/// boundary: a spend in the exact millisecond of expiry fails). The
/// `u64::MAX` sentinel never expires.
#[error(code = 3)]
const EAllowanceExpired: vector<u8> = "Allowance has expired";

/// `amount` exceeds the entry's `remaining`. Also fires on suspended
/// entries (`remaining == 0`) for any positive amount: this is the
/// suspension-vs-revocation discriminator.
#[error(code = 4)]
const EAllowanceExceeded: vector<u8> = "Amount exceeds remaining allowance";

/// `amount` exceeds the pool. The "ceiling is not a guarantee" path: an
/// in-budget, unexpired spend aborts here when the pool is short.
#[error(code = 5)]
const EInsufficientVault: vector<u8> = "Vault balance insufficient";

/// Zero amount on a value-moving entry point (`deposit`, `deposit_balance`,
/// `mint_cap`, `mint_and_transfer`, `spend`, `withdraw`). `set_allowance`
/// deliberately accepts 0 (suspension idiom); `withdraw_all` and `destroy`
/// deliberately permit zero-value outcomes.
#[error(code = 6)]
const EZeroAmount: vector<u8> = "Amount must be greater than zero";

/// Finite `expires_at_ms` was at or before `clock.timestamp_ms()` on a
/// grant or update. The `u64::MAX` sentinel is "no expiry" and always
/// passes. Corollary: `set_allowance` with a future expiry REVIVES an
/// expired entry; expiry is owner-reversible in place.
#[error(code = 7)]
const EExpiryInPast: vector<u8> = "Expiry must be in the future";

/// CAS guard failed on `set_allowance`: the entry's current `remaining`
/// does not equal `expected`. A spend was sequenced between your read and
/// this write; re-read and retry.
#[error(code = 8)]
const EUnexpectedAllowance: vector<u8> = "Current allowance does not match expected";

// === Structs ===

/// Shared escrow + per-spender allowance ledger for coin type `U`.
///
/// `key`-only by design: a Vault returned by `new` cannot be silently
/// discarded (no `drop`), and external modules cannot wrap or re-share it
/// (no `store`). The lifecycle is exactly `new → share` or `new → destroy`.
///
/// The ledger is a `LinkedTable` so `destroy` can drain every entry and
/// recover each per-entry storage rebate; the cost is an O(n) `destroy`
/// (revoke in batches first for very large ledgers).
public struct Vault<phantom U> has key {
    id: UID,
    balance: Balance<U>,
    allowances: LinkedTable<ID, Allowance>,
}

/// Owner authority for exactly one Vault. Transferable + custody-composable
/// (`store` enables multisig/DAO embedding and two-step-transfer wrapping).
/// Exactly ONE OwnerCap exists per Vault for its entire life: `new` mints
/// it and `destroy` consumes it. Transfer of the cap IS owner rotation.
public struct OwnerCap has key, store {
    id: UID,
    vault_id: ID,
}

/// Spend authority for one ledger entry. **BEARER INSTRUMENT**: whoever
/// presents `&SpenderCap` to `spend` holds the entry's full spend authority
/// (see the module-level warning).
///
/// `vault_id` is set at mint and never written again; the binding survives
/// every transfer, wrap, or table embedding. On-chain custodians should
/// validate the binding via `spender_cap_vault_id` before accepting a cap.
public struct SpenderCap has key, store {
    id: UID,
    vault_id: ID,
}

/// Private ledger entry for one cap. Not an object: reachable exclusively
/// through this module's functions on the owning Vault. The single source
/// of truth for a grant's state; the cap object carries no budget fields.
///
/// `remaining`: `u64::MAX` is the UNLIMITED sentinel (never decremented);
/// `0` is a live-but-suspended entry; anything else is the raw drawable
/// budget. `expires_at_ms`: `u64::MAX` is the NO-EXPIRY sentinel; any
/// finite value must be strictly future at grant/update time.
public struct Allowance has store, drop {
    remaining: u64,
    expires_at_ms: u64,
}

// === Events ===

// One event per state change, fixed schema. The one deliberate non-emitter
// is `share` (platform-visible). `destroy`'s drain loop emits NO per-entry
// `Revoked`: one `VaultDestroyed` is the terminal event for every entry
// under that vault_id. All events carry phantom `U` for type-filtered
// indexing EXCEPT `CapDeleted`, which is non-generic (`delete_cap` has no
// coin type in scope).

/// Emitted by `new`. `owner_cap_id` is the vault-to-cap discovery anchor:
/// indexers resolve current owner custody by following object-ownership
/// changes of this cap. `creator` is `ctx.sender()` at `new` and may differ
/// from the eventual owner.
public struct VaultCreated<phantom U> has copy, drop {
    vault_id: ID,
    owner_cap_id: ID,
    creator: address,
}

/// Emitted by `deposit` and `deposit_balance`. `depositor` is indexer
/// attribution only; depositing confers no rights.
public struct Deposited<phantom U> has copy, drop {
    vault_id: ID,
    amount: u64,
    depositor: address,
}

/// Emitted by `mint_cap` AND `mint_and_transfer`, distinguished by
/// `recipient`: `Some(r)` means `mint_and_transfer` delivered the cap to
/// `r`; `None` means `mint_cap` returned it by value for embedding.
/// `amount == u64::MAX` is the unlimited sentinel; exclude it from volume
/// math. `by` is `ctx.sender()`.
public struct SpenderCapMinted<phantom U> has copy, drop {
    vault_id: ID,
    cap_id: ID,
    recipient: Option<address>,
    amount: u64,
    expires_at_ms: u64,
    by: address,
}

/// Emitted by `set_allowance`. `new_amount == 0` signals the suspension
/// idiom: the entry and cap stay alive. `cas_was_provided` records whether
/// the CAS guard was engaged, so off-chain tooling can spot CAS-less
/// read-derived updates.
public struct AllowanceSet<phantom U> has copy, drop {
    vault_id: ID,
    cap_id: ID,
    new_amount: u64,
    new_expires_at_ms: u64,
    cas_was_provided: bool,
    by: address,
}

/// Emitted on every successful `spend`. `remaining` is the entry's RAW
/// value after the call; for an unlimited grant it stays `u64::MAX`.
/// `caller` is `ctx.sender()`: attribution, never a gate. In wrapper flows
/// it is the wrapper's caller, not necessarily the cap holder.
public struct Spent<phantom U> has copy, drop {
    vault_id: ID,
    cap_id: ID,
    amount: u64,
    remaining: u64,
    caller: address,
}

/// Emitted by `revoke` on every non-aborting call, INCLUDING the idempotent
/// no-op path. `was_present == false` is the typo'd-cap_id signal: nothing
/// was actually removed.
public struct Revoked<phantom U> has copy, drop {
    vault_id: ID,
    cap_id: ID,
    was_present: bool,
    by: address,
}

/// Emitted by `renounce` (spender self-revoke). `by` is `ctx.sender()`.
public struct Renounced<phantom U> has copy, drop {
    vault_id: ID,
    cap_id: ID,
    by: address,
}

/// Emitted by both `withdraw` and `withdraw_all`. `amount` is the actual
/// value extracted, possibly 0 from `withdraw_all` on an empty pool.
public struct Withdrawn<phantom U> has copy, drop {
    vault_id: ID,
    amount: u64,
    by: address,
}

/// Emitted by `destroy`. `refunded` is the leftover pool returned as a
/// possibly-zero `Coin<U>`. This is the TERMINAL event for every ledger
/// entry under `vault_id`; indexers must close all open entries on it.
/// Live SpenderCaps are orphaned; holders dispose of them via `delete_cap`.
public struct VaultDestroyed<phantom U> has copy, drop {
    vault_id: ID,
    refunded: u64,
    by: address,
}

/// Emitted by `delete_cap`. The only non-generic event: `delete_cap`
/// consumes a bare `SpenderCap` (no coin type in scope), so indexers map
/// `vault_id` to `U` from the `VaultCreated`/`SpenderCapMinted` they saw.
/// Lets event-only indexers follow a cap deletion; without it, deleting a
/// live cap would leave its stranded entry looking like live authority.
public struct CapDeleted has copy, drop {
    vault_id: ID,
    cap_id: ID,
}

// === Public Functions ===

// === Lifecycle ===

/// Create a Vault for coin type `U` and its sole, vault-bound `OwnerCap`,
/// both returned BY VALUE.
///
/// One PTB composes the full setup atomically:
/// `new → deposit → mint_cap/mint_and_transfer (×N) → share →
/// transfer(owner_cap)`. Creator and owner can differ: transfer the cap
/// anywhere. The Vault has no `drop`, so the tx fails unless it is consumed
/// by `share` or `destroy` in the same tx.
///
/// #### Returns
/// - `(Vault<U>, OwnerCap)`: caller must consume both.
///
/// #### Aborts
/// Never. Emits `VaultCreated { vault_id, owner_cap_id, creator }`.
public fun new<U>(ctx: &mut TxContext): (Vault<U>, OwnerCap) {
    let vault_uid = object::new(ctx);
    let vault_id = vault_uid.to_inner();

    let vault = Vault<U> {
        id: vault_uid,
        balance: balance::zero<U>(),
        allowances: linked_table::new<ID, Allowance>(ctx),
    };

    let owner_cap = OwnerCap {
        id: object::new(ctx),
        vault_id,
    };

    event::emit(VaultCreated<U> {
        vault_id,
        owner_cap_id: object::id(&owner_cap),
        creator: ctx.sender(),
    });

    (vault, owner_cap)
}

/// Share the Vault. Module-only entry point (`Vault<U>` omits `store`, so
/// external modules cannot share it another way).
///
/// Must run in the same tx as `new`; there is no deferred-share path. After
/// `share`, the Vault becomes addressable as a shared input only in
/// subsequent transactions, so all same-PTB fund/grant steps must precede
/// it. No event: sharing is platform-visible.
public fun share<U>(v: Vault<U>) {
    transfer::share_object(v);
}

/// Terminal owner exit. Consumes the Vault and OwnerCap, drains EVERY
/// ledger entry, deletes both UIDs, and returns the leftover pool as a
/// possibly-zero `Coin<U>`.
///
/// The drain is O(n) in live entries and recovers each entry's storage
/// rebate. For very large ledgers, revoke in batches first to spread gas.
///
/// Teardown is never blockable: the only abort is the cap binding. No
/// ledger state (suspended, expired, unlimited entries included) is
/// consulted as a gate. Live `SpenderCap`s are orphaned by this call;
/// holders dispose of them via `delete_cap`.
///
/// `VaultDestroyed` is the terminal event for every entry under this
/// vault_id; the drain emits no per-entry `Revoked`.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: cap bound to a different Vault. Only abort.
public fun destroy<U>(v: Vault<U>, cap: OwnerCap, ctx: &mut TxContext): Coin<U> {
    assert!(cap.vault_id == object::id(&v), EWrongOwnerCap);

    let Vault { id: vault_uid, balance, mut allowances } = v;
    let vault_id = vault_uid.to_inner();

    // Full drain, recovering per-entry storage rebates. `destroy_empty` is
    // the backstop; the loop makes a non-empty table unreachable there.
    while (!allowances.is_empty()) {
        let (_cap_id, _entry) = allowances.pop_front();
    };
    allowances.destroy_empty();

    // The refund is the pool, exactly: split/join only, no computed amounts.
    let refunded = balance.value();
    let refund = balance.into_coin(ctx);

    let OwnerCap { id: owner_cap_uid, vault_id: _ } = cap;
    vault_uid.delete();
    owner_cap_uid.delete();

    event::emit(VaultDestroyed<U> {
        vault_id,
        refunded,
        by: ctx.sender(),
    });

    refund
}

// === Fund ===

/// Add a `Coin<U>` to the pool. PERMISSIONLESS: anyone may deposit, and
/// depositing confers NO rights (no entry, no claim, no refund path); the
/// funds become the owner's pool. Only fund a Vault whose owner you trust.
///
/// CAVEAT: because deposits are permissionless and allowances are ceilings
/// on the pool, a deposit by anyone (including a spender) re-arms live
/// allowances after a `withdraw_all`-as-freeze. The durable kill-all is
/// batched `revoke` or `destroy`.
///
/// #### Aborts (in order)
/// 1. `EZeroAmount`: `c.value() == 0`.
public fun deposit<U>(v: &mut Vault<U>, c: Coin<U>, ctx: &TxContext) {
    let amount = c.value();
    assert!(amount > 0, EZeroAmount);

    v.balance.join(c.into_balance());

    event::emit(Deposited<U> {
        vault_id: object::id(v),
        amount,
        depositor: ctx.sender(),
    });
}

/// `Balance<U>`-native deposit: the natural sink for a `spend` output
/// routed back into escrow, or for address-balance composition. Same
/// permissionless, rights-free semantics as `deposit`.
///
/// #### Aborts (in order)
/// 1. `EZeroAmount`: `b.value() == 0`.
public fun deposit_balance<U>(v: &mut Vault<U>, b: Balance<U>, ctx: &TxContext) {
    let amount = b.value();
    assert!(amount > 0, EZeroAmount);

    v.balance.join(b);

    event::emit(Deposited<U> {
        vault_id: object::id(v),
        amount,
        depositor: ctx.sender(),
    });
}

// === Grant ===

// Each grant call mints a NEW, ADDITIVE entry: two grants to the same
// person are two independent budgets that SUM. To change an existing
// grant, use `set_allowance`, NEVER a second mint.

/// Owner-only. Mints a `SpenderCap` with a fresh ledger entry and RETURNS
/// the cap by value, for embedding in wrapper objects or protocol records.
/// Caller decides the cap's destination in the same PTB. For the common
/// "delegate to a known address" path, use `mint_and_transfer`.
///
/// #### Parameters
/// - `amount`: initial budget. Must be `> 0`; `u64::MAX` = UNLIMITED
///   sentinel (never decremented).
/// - `expires_at_ms`: strictly-future consensus-Clock ms timestamp, or
///   `u64::MAX` = no expiry. Same time base `spend` enforces against.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: cap bound to a different Vault.
/// 2. `EZeroAmount`: `amount == 0`.
/// 3. `EExpiryInPast`: finite `expires_at_ms <= now`.
public fun mint_cap<U>(
    v: &mut Vault<U>,
    cap: &OwnerCap,
    amount: u64,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): SpenderCap {
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);
    assert!(amount > 0, EZeroAmount);
    assert!(
        expires_at_ms == std::u64::max_value!() || expires_at_ms > clock.timestamp_ms(),
        EExpiryInPast, // the u64::MAX no-expiry sentinel always passes
    );

    mint_internal(v, amount, expires_at_ms, option::none(), ctx)
}

/// Owner-only. `mint_cap` + `public_transfer(cap, recipient)` in one call:
/// the common-case "delegate to a known address" path. (Deliberately NOT
/// named `approve`: a second call to the same person is a NEW additive
/// grant, not an update.)
///
/// `recipient` is unvalidated: the cap is a bearer instrument, so
/// mis-delivery is mis-authorization. Choosing a sound address is the
/// owner's responsibility.
///
/// #### Aborts
/// Identical to `mint_cap`, in order:
/// `EWrongOwnerCap` → `EZeroAmount` → `EExpiryInPast`.
public fun mint_and_transfer<U>(
    v: &mut Vault<U>,
    cap: &OwnerCap,
    amount: u64,
    expires_at_ms: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);
    assert!(amount > 0, EZeroAmount);
    assert!(
        expires_at_ms == std::u64::max_value!() || expires_at_ms > clock.timestamp_ms(),
        EExpiryInPast, // the u64::MAX no-expiry sentinel always passes
    );

    let spender_cap = mint_internal(v, amount, expires_at_ms, option::some(recipient), ctx);
    // Sui transfers execute no code at the destination: this cannot
    // re-enter the module or observe intermediate state.
    transfer::public_transfer(spender_cap, recipient);
}

// === Update ===

/// Owner-only. Modify an existing entry IN PLACE: the primary update path.
/// The ledger key, the `SpenderCap` object, its ID, and its binding are all
/// untouched by any parameter change: a cap embedded in a protocol table
/// survives unlimited owner updates, and re-granting is never required.
///
/// Takes `cap_id: ID`, not `&SpenderCap`: the owner doesn't hold the cap.
/// Update-only, never an upsert: an absent `cap_id` aborts `ENoAllowance`.
///
/// - **Suspension:** `new_amount == 0` zeroes the budget but keeps entry +
///   cap alive; the next spend aborts `EAllowanceExceeded`. There is
///   deliberately no `EZeroAmount` here.
/// - **Revival:** a future `new_expires_at_ms` revives an expired entry;
///   expiry is owner-reversible in place. Note: suspending an
///   *already-expired* entry necessarily restates a valid future expiry
///   (or `u64::MAX`), time-reviving it while zeroing the budget.
/// - **CAS:** pass `expected = Some(e)` on ANY read-derived update,
///   including expiry-only renewals (the amount restates). The race-free
///   idiom is `allowance()` then `set_allowance(…, expected = Some(result),
///   …)` in one PTB (the shared Vault is locked for the tx). `None` is the
///   unconditional overwrite. CAS compares the RAW `remaining`: `0` for
///   suspended and `u64::MAX` for unlimited included.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: cap bound to a different Vault.
/// 2. `ENoAllowance`: no entry for `cap_id` (update-only).
/// 3. `EExpiryInPast`: finite `new_expires_at_ms <= now`.
/// 4. `EUnexpectedAllowance`: CAS provided and current `remaining` differs.
public fun set_allowance<U>(
    v: &mut Vault<U>,
    cap: &OwnerCap,
    cap_id: ID,
    new_amount: u64,
    new_expires_at_ms: u64,
    expected: Option<u64>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let vault_id = object::id(v);

    // Precedence: gate, then existence, then time, then CAS.
    assert!(cap.vault_id == vault_id, EWrongOwnerCap);
    assert!(v.allowances.contains(cap_id), ENoAllowance);
    assert!(
        new_expires_at_ms == std::u64::max_value!()
            || new_expires_at_ms > clock.timestamp_ms(),
        EExpiryInPast, // the u64::MAX no-expiry sentinel always passes
    );

    // CAS: compare-without-consuming against the raw remaining.
    let cas_was_provided = expected.is_some();
    if (cas_was_provided) {
        let current = v.allowances.borrow(cap_id).remaining;
        assert!(current == expected.destroy_some(), EUnexpectedAllowance);
    };

    // In-place field mutation: never a remove + re-add, never a re-mint.
    // new_amount == 0 leaves the entry in the ledger (suspension).
    let entry = v.allowances.borrow_mut(cap_id);
    entry.remaining = new_amount;
    entry.expires_at_ms = new_expires_at_ms;

    event::emit(AllowanceSet<U> {
        vault_id,
        cap_id,
        new_amount,
        new_expires_at_ms,
        cas_was_provided,
        by: ctx.sender(),
    });
}

// === Spend ===

/// Draw exactly `amount` against the presented `&SpenderCap`. CAP-GATED,
/// never sender-gated: any transaction context (an EOA, a protocol module
/// borrowing an embedded cap, a sponsored tx) spends identically.
/// `ctx.sender()` feeds `Spent.caller` only.
///
/// EXACT-AMOUNT-OR-ABORT: success extracts exactly `amount` from the pool
/// and decrements the budget by exactly `amount`, unless the budget is
/// `u64::MAX`, which is never decremented. No partial draws, no rounding,
/// no fees. On ANY abort, the pool and every entry are bit-identical to
/// pre-call: all six checks precede the first mutation.
///
/// Returns `Balance<U>` with no `drop`, so the caller MUST consume it:
/// plumb it onward in the same PTB (`into_coin`, `deposit_balance`, a
/// downstream protocol call). Spend-to-zero leaves the entry in place;
/// removal is `revoke`/`renounce`/`destroy`.
///
/// An allowance is a CEILING, not a reservation: a live, unexpired,
/// within-budget spend can still abort `EInsufficientVault` if the owner
/// withdrew first or sibling spenders drained the pool. Pre-`spend` reads
/// are advisory; `spend` itself is the only atomic check-and-draw.
///
/// #### Aborts (in order; deterministic integrator ABI)
/// 1. `EWrongVault`: cap bound to a different Vault.
/// 2. `ENoAllowance`: no entry for this cap (never granted or revoked).
/// 3. `EAllowanceExpired`: finite expiry and `now >= expires_at_ms`.
/// 4. `EZeroAmount`: `amount == 0`.
/// 5. `EAllowanceExceeded`: finite `remaining` and `amount > remaining`;
///    includes suspended-at-zero.
/// 6. `EInsufficientVault`: `amount > pool`.
public fun spend<U>(
    v: &mut Vault<U>,
    cap: &SpenderCap,
    amount: u64,
    clock: &Clock,
    ctx: &TxContext,
): Balance<U> {
    let vault_id = object::id(v);
    let cap_id = object::id(cap);

    // 1. Binding gate, before any ledger access.
    assert!(cap.vault_id == vault_id, EWrongVault);

    // 2. Existence. Absent (never granted / revoked) is deliberately
    //    distinct from suspended-at-zero (check 5).
    assert!(v.allowances.contains(cap_id), ENoAllowance);

    // Read phase: copy the two scalars; the immutable borrow ends here.
    let (remaining, expires_at_ms) = {
        let entry = v.allowances.borrow(cap_id);
        (entry.remaining, entry.expires_at_ms)
    };

    // 3. Closed boundary: a spend in the exact millisecond of expiry
    //    fails. The no-expiry sentinel short-circuits by equality.
    assert!(
        expires_at_ms == std::u64::max_value!()
            || clock.timestamp_ms() < expires_at_ms,
        EAllowanceExpired,
    );

    // 4. No zero-value draws.
    assert!(amount > 0, EZeroAmount);

    // 5. Compare-before-decrement (no underflow path exists). The
    //    unlimited sentinel short-circuits by equality, no arithmetic.
    assert!(
        remaining == std::u64::max_value!() || amount <= remaining,
        EAllowanceExceeded,
    );

    // 6. Explicit pool check BEFORE `split`, so code 5 (not a framework
    //    abort) always surfaces. This is the ceiling-is-not-a-guarantee path.
    assert!(amount <= v.balance.value(), EInsufficientVault);

    // Commit (all checks passed; no abort below this line). Exact
    // decrement; the unlimited sentinel is never decremented.
    let remaining_after = if (remaining == std::u64::max_value!()) {
        remaining
    } else {
        remaining - amount
    };
    // In-place write; the entry stays even at zero.
    v.allowances.borrow_mut(cap_id).remaining = remaining_after;

    // Exact split: check 6 proved `amount <= pool`.
    let bal = v.balance.split(amount);

    event::emit(Spent<U> {
        vault_id,
        cap_id,
        amount,
        remaining: remaining_after,
        caller: ctx.sender(),
    });

    bal
}

// === Revoke / Renounce / Cap Disposal ===

/// Owner kill-switch: remove the entry for `cap_id`. IDEMPOTENT and
/// ledger-state-independent: a present entry is removed, an absent one is a
/// no-op, and the return value says which happened (`was_present == false`
/// is the typo'd-cap_id signal, never a success-shaped lie). No allowance
/// state (absent, suspended, expired, unlimited) can make it abort: the
/// kill-switch cannot be raced into failure.
///
/// NOT retroactive: a spend sequenced before the owner's tx still
/// succeeds (true of `withdraw_all` too). Pair `revoke` (durably kills the
/// cap) with `withdraw_all` (sweeps funds, but reversible by permissionless
/// deposit) for emergencies.
///
/// The cap OBJECT survives in its holder's wallet as inert non-authority:
/// subsequent spends abort `ENoAllowance`; the holder disposes of it via
/// `renounce` (no-op removal + deletion) or `delete_cap`.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: only abort.
public fun revoke<U>(v: &mut Vault<U>, cap: &OwnerCap, cap_id: ID, ctx: &TxContext): bool {
    // Owner gate: the ONLY check, so no state can race this into failure.
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);

    let was_present = v.allowances.contains(cap_id);
    if (was_present) {
        // Allowance has `drop`; removal recovers the entry's storage
        // rebate to this tx's gas payer.
        v.allowances.remove(cap_id);
    };

    // Emitted on EVERY non-aborting call, no-op included.
    event::emit(Revoked<U> {
        vault_id: object::id(v),
        cap_id,
        was_present,
        by: ctx.sender(),
    });

    was_present
}

/// Spender self-revoke against a LIVE vault. Consumes the cap by value,
/// removes its entry if present, deletes the cap object: the only path that
/// removes both sides atomically. No inert authority-shaped garbage
/// survives, and the entry's storage rebate routes to this tx's gas payer.
///
/// If the vault is already destroyed this function is uncallable (no
/// `&mut Vault` exists); use `delete_cap` for orphaned caps.
///
/// #### Aborts (in order)
/// 1. `EWrongVault`: cap bound to a different Vault. Only abort: an
///    already-revoked entry is fine (the cap-side cleanup proceeds).
public fun renounce<U>(v: &mut Vault<U>, cap: SpenderCap, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(v), EWrongVault);

    let SpenderCap { id, vault_id: _ } = cap;
    let cap_id = id.to_inner();

    // The entry may already be gone (owner revoked first); the renounce
    // still completes the cap side.
    if (v.allowances.contains(cap_id)) {
        v.allowances.remove(cap_id);
    };
    id.delete();

    event::emit(Renounced<U> {
        vault_id: object::id(v),
        cap_id,
        by: ctx.sender(),
    });
}

/// Vault-less cap destructor: for caps orphaned by `destroy` (`renounce`
/// needs `&mut Vault`, which no longer exists). Total: never aborts,
/// touches no vault state, deletes exactly the cap's UID. Emits
/// `CapDeleted` so event-only indexers can follow the deletion.
///
/// **Prefer `renounce` if the vault is alive; use `delete_cap` only when
/// renounce is impossible because the vault is gone.** Deleting a cap whose
/// entry is still live STRANDS the entry: unspendable forever (object IDs
/// are never reused), still visible via `contains`, removable only by owner
/// `revoke`, and you forfeit the entry's storage rebate that `renounce`
/// would have recovered.
public fun delete_cap(cap: SpenderCap) {
    let SpenderCap { id, vault_id } = cap;
    let cap_id = id.to_inner();
    id.delete();

    event::emit(CapDeleted { vault_id, cap_id });
}

// === Owner Exit ===

// Exit consults ONLY the cap binding and the pool, never the ledger. No
// spender state, adversarial or accidental, can block the owner from
// defunding or tearing down.

/// Owner-only. Withdraw exactly `amount` from the pool as a `Coin<U>`.
///
/// May leave live allowances unbacked: intended (allowances are ceilings;
/// the next over-pool spend aborts `EInsufficientVault` with a live budget).
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`
/// 2. `EZeroAmount`
/// 3. `EInsufficientVault`: `amount > pool` (asserted before `split`).
public fun withdraw<U>(
    v: &mut Vault<U>,
    cap: &OwnerCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<U> {
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);
    assert!(amount > 0, EZeroAmount);
    // Explicit check so the documented code 5, not a framework abort,
    // surfaces.
    assert!(amount <= v.balance.value(), EInsufficientVault);

    let c = v.balance.split(amount).into_coin(ctx);

    event::emit(Withdrawn<U> {
        vault_id: object::id(v),
        amount,
        by: ctx.sender(),
    });

    c
}

/// Owner-only. Withdraw the ENTIRE pool as a possibly-zero `Coin<U>`;
/// never aborts on pool state. An aborting drain would fail exactly when
/// racing a spender who just emptied the pool, the moment the emergency
/// `revoke + withdraw_all` PTB matters most.
///
/// CAVEAT: withdraw_all-as-freeze is REVERSIBLE. `deposit` is
/// permissionless, so anyone (including the spender) re-arms live
/// allowances by topping up the pool. The durable kill-all is batched
/// `revoke` (one PTB) or `destroy`.
///
/// #### Aborts (in order)
/// 1. `EWrongOwnerCap`: only abort.
public fun withdraw_all<U>(v: &mut Vault<U>, cap: &OwnerCap, ctx: &mut TxContext): Coin<U> {
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);

    // Possibly-zero withdrawal: no pool-state abort of any kind.
    let drained = v.balance.withdraw_all();
    let amount = drained.value();
    let c = drained.into_coin(ctx);

    event::emit(Withdrawn<U> {
        vault_id: object::id(v),
        amount,
        by: ctx.sender(),
    });

    c
}

// === Reads ===

// All reads are TOTAL: they never abort, for any input, in any vault state.
// Absent cap_ids return the documented defaults, not errors.
//
// All reads are ADVISORY: results are stale the moment a later tx mutates
// the vault. Cross-tx check-then-act is unsound; within one PTB the shared
// Vault is locked for the whole tx, so read → decide → write sequences are
// atomic (the CAS idiom on `set_allowance`).

/// Raw `remaining` for `cap_id`; `0` if absent. Ambiguous at 0: suspended
/// and absent both read 0; disambiguate with `contains`. `u64::MAX` is the
/// unlimited sentinel, not a volume.
public fun allowance<U>(v: &Vault<U>, cap_id: ID): u64 {
    if (v.allowances.contains(cap_id)) {
        v.allowances.borrow(cap_id).remaining
    } else {
        0
    }
}

/// What a `spend` through this entry could draw RIGHT NOW: `0` if absent
/// or expired, else `min(remaining, pool)`; for an unlimited entry this
/// reduces to the pool. Same expiry predicate and same `min` semantics as
/// `spend`'s own checks, so `spend(spendable_now(…))` with no intervening
/// mutation in the same PTB never aborts on time, budget, or pool, **when
/// the quote is non-zero**. Guard `> 0` before feeding it to `spend`: a
/// zero quote aborts `EZeroAmount`.
public fun spendable_now<U>(v: &Vault<U>, cap_id: ID, clock: &Clock): u64 {
    if (!v.allowances.contains(cap_id)) {
        return 0
    };
    let entry = v.allowances.borrow(cap_id);
    // Same closed boundary as `spend` check 3.
    if (entry.expires_at_ms != std::u64::max_value!()
        && clock.timestamp_ms() >= entry.expires_at_ms) {
        return 0
    };
    // The u64::MAX sentinel is min's neutral element: unlimited reduces to
    // the pool with no special case.
    entry.remaining.min(v.balance.value())
}

/// Raw `expires_at_ms` for `cap_id`; `0` if absent. `u64::MAX` is the
/// no-expiry sentinel.
public fun expiry<U>(v: &Vault<U>, cap_id: ID): u64 {
    if (v.allowances.contains(cap_id)) {
        v.allowances.borrow(cap_id).expires_at_ms
    } else {
        0
    }
}

/// Ledger membership for `cap_id`: the absent-vs-suspended disambiguator.
/// `allowance == 0 && contains` is a suspended (or drained) entry whose cap
/// is still valid; `!contains` is never-granted / revoked / renounced.
public fun contains<U>(v: &Vault<U>, cap_id: ID): bool {
    v.allowances.contains(cap_id)
}

/// Current pool value.
public fun balance_value<U>(v: &Vault<U>): u64 {
    v.balance.value()
}

/// The Vault this OwnerCap is bound to: on-chain custodians validate the
/// binding before accepting a cap.
public fun owner_cap_vault_id(cap: &OwnerCap): ID {
    cap.vault_id
}

/// The Vault this SpenderCap is bound to: protocols accepting a user's cap
/// MUST check this against the expected vault before custody (see the
/// module-level bearer-cap warning).
public fun spender_cap_vault_id(cap: &SpenderCap): ID {
    cap.vault_id
}

// === Private Helpers ===

/// Shared construction path for `mint_cap` / `mint_and_transfer`. Callers
/// have already run the full precedence asserts.
///
/// Creates the cap and its ledger entry atomically in one call: the key is
/// the fresh cap's globally-unique object ID, so a mint can never
/// overwrite, merge with, or top-up an existing entry, and the entry always
/// has a matching live cap object at the instant of insert. `recipient`
/// feeds the event only.
fun mint_internal<U>(
    v: &mut Vault<U>,
    amount: u64,
    expires_at_ms: u64,
    recipient: Option<address>,
    ctx: &mut TxContext,
): SpenderCap {
    let cap = SpenderCap {
        id: object::new(ctx),
        vault_id: object::id(v),
    };
    let cap_id = object::id(&cap);

    // `push_back` aborts on a duplicate key: unreachable (object IDs are
    // globally unique), but the container enforces it as a backstop.
    v.allowances.push_back(cap_id, Allowance { remaining: amount, expires_at_ms });

    event::emit(SpenderCapMinted<U> {
        vault_id: object::id(v),
        cap_id,
        recipient,
        amount,
        expires_at_ms,
        by: ctx.sender(),
    });

    cap
}

// === Test-Only Helpers ===

/// Construct a `VaultCreated<U>` event value for test-side equality
/// assertions.
#[test_only]
public fun test_new_vault_created<U>(
    vault_id: ID,
    owner_cap_id: ID,
    creator: address,
): VaultCreated<U> {
    VaultCreated { vault_id, owner_cap_id, creator }
}

/// Construct a `Deposited<U>` event value for test-side equality
/// assertions.
#[test_only]
public fun test_new_deposited<U>(
    vault_id: ID,
    amount: u64,
    depositor: address,
): Deposited<U> {
    Deposited { vault_id, amount, depositor }
}

/// Construct a `SpenderCapMinted<U>` event value for test-side equality
/// assertions.
#[test_only]
public fun test_new_spender_cap_minted<U>(
    vault_id: ID,
    cap_id: ID,
    recipient: Option<address>,
    amount: u64,
    expires_at_ms: u64,
    by: address,
): SpenderCapMinted<U> {
    SpenderCapMinted {
        vault_id,
        cap_id,
        recipient,
        amount,
        expires_at_ms,
        by,
    }
}

/// Construct an `AllowanceSet<U>` event value for test-side equality
/// assertions.
#[test_only]
public fun test_new_allowance_set<U>(
    vault_id: ID,
    cap_id: ID,
    new_amount: u64,
    new_expires_at_ms: u64,
    cas_was_provided: bool,
    by: address,
): AllowanceSet<U> {
    AllowanceSet {
        vault_id,
        cap_id,
        new_amount,
        new_expires_at_ms,
        cas_was_provided,
        by,
    }
}

/// Construct a `Spent<U>` event value for test-side equality assertions.
#[test_only]
public fun test_new_spent<U>(
    vault_id: ID,
    cap_id: ID,
    amount: u64,
    remaining: u64,
    caller: address,
): Spent<U> {
    Spent { vault_id, cap_id, amount, remaining, caller }
}

/// Construct a `Revoked<U>` event value for test-side equality
/// assertions.
#[test_only]
public fun test_new_revoked<U>(
    vault_id: ID,
    cap_id: ID,
    was_present: bool,
    by: address,
): Revoked<U> {
    Revoked { vault_id, cap_id, was_present, by }
}

/// Construct a `Renounced<U>` event value for test-side equality
/// assertions.
#[test_only]
public fun test_new_renounced<U>(
    vault_id: ID,
    cap_id: ID,
    by: address,
): Renounced<U> {
    Renounced { vault_id, cap_id, by }
}

/// Construct a `Withdrawn<U>` event value for test-side equality
/// assertions.
#[test_only]
public fun test_new_withdrawn<U>(
    vault_id: ID,
    amount: u64,
    by: address,
): Withdrawn<U> {
    Withdrawn { vault_id, amount, by }
}

/// Construct a `VaultDestroyed<U>` event value for test-side equality
/// assertions.
#[test_only]
public fun test_new_vault_destroyed<U>(
    vault_id: ID,
    refunded: u64,
    by: address,
): VaultDestroyed<U> {
    VaultDestroyed { vault_id, refunded, by }
}
