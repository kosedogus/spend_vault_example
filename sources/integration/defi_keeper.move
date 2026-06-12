/// Integration example: a keeper service that custodies user `SpenderCap`s.
///
/// This is the library's PRIMARY use case: a protocol holds a user's cap
/// and spends from the user's vault on the user's behalf, within the budget
/// and expiry the user's vault owner set.
///
/// #### The flow an integrator must get right
///
/// 1. The OPERATOR creates a `Service<U>` pinned to exactly ONE vault ID and
///    shares it. Pinning up front is what makes step 2's check meaningful.
/// 2. A user mints a cap against their vault (`mint_cap` returns it by
///    value) and hands it into custody via `register`. `register` validates
///    the cap's vault binding (`spender_cap_vault_id`) BEFORE accepting:
///    a cap bound to some other vault would sit in custody and fail every
///    spend with `EWrongVault`, or meter a vault this service never agreed
///    to serve.
/// 3. The operator calls `execute_topup`, which borrows the custodied cap
///    and draws from the user's vault. **This function is sender-gated.**
///    A `SpenderCap` is a bearer instrument: whoever gets the library to
///    see `&SpenderCap` exercises its full authority. An UNGATED public
///    function that borrows a custodied cap is world-drainable authority,
///    so the gate below is not optional hygiene, it is the integration's
///    security boundary.
/// 4. The user reclaims their cap any time with `unregister`.
///
/// What the vault owner keeps throughout: full control. They can raise,
/// lower, suspend (`set_allowance`), or kill (`revoke`) the grant while the
/// cap sits embedded here. The cap object and its ID never change across
/// owner updates, so registration survives unlimited `set_allowance` calls
/// and is never repeated.
module spend_vault_example::defi_keeper;

use openzeppelin_allowance::spend_vault::{Self, Vault, SpenderCap};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::table::{Self, Table};

// === Errors ===

/// Caller of a cap-borrowing entrypoint is not the service operator.
const ENotOperator: u64 = 0;

/// Offered cap is bound to a different vault than this service serves.
const EWrongVaultForService: u64 = 1;

/// No cap registered under this user address.
const ENotRegistered: u64 = 2;

// === Structs ===

/// Shared keeper service. Serves exactly one `Vault<U>`; custodies at most
/// one cap per user address.
public struct Service<phantom U> has key {
    id: UID,
    operator: address,
    vault_id: ID,
    caps: Table<address, SpenderCap>,
}

// === Public Functions ===

/// Create and share a service pinned to `vault_id`. The creator becomes the
/// operator, the only address the cap-borrowing entrypoint accepts.
/// Returns the service's object ID so callers can address the shared object.
public fun create<U>(vault_id: ID, ctx: &mut TxContext): ID {
    let service = Service<U> {
        id: object::new(ctx),
        operator: ctx.sender(),
        vault_id,
        caps: table::new(ctx),
    };
    let service_id = object::id(&service);
    transfer::share_object(service);
    service_id
}

/// Hand a cap into the service's custody, keyed by the registering sender.
///
/// The binding check is the custody-boundary rule for ANY protocol that
/// accepts a `SpenderCap`: validate `spender_cap_vault_id` against the
/// vault you intend to spend from, on-chain, before taking the cap.
public fun register<U>(s: &mut Service<U>, cap: SpenderCap, ctx: &TxContext) {
    assert!(cap.spender_cap_vault_id() == s.vault_id, EWrongVaultForService);
    s.caps.add(ctx.sender(), cap);
}

/// Draw `amount` from `user`'s vault allowance and return the funds for the
/// caller to route (deposit into a position, convert to `Coin`, ...).
///
/// SENDER-GATED: the assert below is the whole point of this module. The
/// library itself never checks who calls `spend` (any holder of `&cap` has
/// full authority), so the custody layer must decide who may borrow the cap.
public fun execute_topup<U>(
    s: &mut Service<U>,
    v: &mut Vault<U>,
    user: address,
    amount: u64,
    clock: &Clock,
    ctx: &TxContext,
): Balance<U> {
    assert!(ctx.sender() == s.operator, ENotOperator);
    assert!(s.caps.contains(user), ENotRegistered);

    let cap = s.caps.borrow(user);
    spend_vault::spend(v, cap, amount, clock, ctx)
}

/// Take your cap back. The ledger entry is untouched: the grant stays live
/// in the vault; only custody of the cap changes hands.
public fun unregister<U>(s: &mut Service<U>, ctx: &TxContext): SpenderCap {
    assert!(s.caps.contains(ctx.sender()), ENotRegistered);
    s.caps.remove(ctx.sender())
}

// === Reads ===

/// The vault this service is pinned to.
public fun vault_id<U>(s: &Service<U>): ID {
    s.vault_id
}

/// Whether `user` currently has a cap in custody.
public fun is_registered<U>(s: &Service<U>, user: address): bool {
    s.caps.contains(user)
}
