/// Integration example: a keeper service that custodies user `SpenderCap`s and
/// spends from their vaults on their behalf.
///
/// This is the library's primary use case: a protocol holds a user's cap and
/// draws from the user's vault, within the per-coin budget and expiry the vault
/// owner set, without the owner having to send the transaction. The service is
/// untyped and `execute_topup<T>` is generic, so one custodied cap can be driven
/// for every coin the owner budgeted it for.
///
/// #### The flow an integrator must get right
///
/// 1. Create a `Service` pinned to exactly ONE vault ID and share it. Pinning up
///    front is what makes the step-2 check meaningful.
/// 2. The user mints a cap (`mint_cap` returns it by value) and hands it into
///    custody via `register`. `register` validates the cap's vault binding
///    (`spender_cap_vault_id`) BEFORE accepting it: this is the custody-boundary
///    rule for any protocol that takes a `SpenderCap`.
/// 3. The operator calls `execute_topup<T>` to draw coin `T`. **This is
///    sender-gated, and the gate is the point of this module:** a `SpenderCap` is
///    a bearer instrument, so any code that gets the library to see `&cap`
///    exercises its full authority. An ungated public function that borrows a
///    custodied cap is world-drainable, so the operator check is the
///    integration's security boundary, not optional hygiene.
/// 4. The user reclaims the cap any time with `unregister`.
///
/// The vault owner keeps full control throughout: raising, lowering, suspending,
/// or revoking the grant (`set_allowance` / `revoke` / `revoke_all`) never
/// changes the cap object, so a cap embedded here keeps working and is never
/// re-registered.
module spend_vault_example::defi_keeper;

use openzeppelin_allowance::spend_vault::{Vault, SpenderCap};
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

/// Shared keeper service. Serves exactly one `Vault` and custodies at most one
/// cap per user. Untyped, so one service drives every coin a cap is budgeted for.
public struct Service has key {
    id: UID,
    operator: address,
    vault_id: ID,
    caps: Table<address, SpenderCap>,
}

// === Public Functions ===

/// Create and share a service pinned to `vault_id`. The creator becomes the
/// operator, the only address the cap-borrowing entrypoint accepts. Returns the
/// service's object ID so callers can address the shared object.
public fun create(vault_id: ID, ctx: &mut TxContext): ID {
    let service = Service {
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
/// The binding check is the custody-boundary rule for ANY protocol that accepts
/// a `SpenderCap`: validate `spender_cap_vault_id` against the vault you intend
/// to spend from, on-chain, before taking the cap.
public fun register(s: &mut Service, cap: SpenderCap, ctx: &TxContext) {
    assert!(cap.spender_cap_vault_id() == s.vault_id, EWrongVaultForService);
    s.caps.add(ctx.sender(), cap);
}

/// Draw `amount` of coin `T` from `user`'s allowance and return the funds for the
/// caller to route (into a position, a `Coin`, ...). Generic over `T`, so the
/// same custodied cap serves every coin the owner budgeted it for; asking for a
/// coin the owner never granted aborts inside the library (`ENoAllowance`), so
/// this fails safe.
///
/// SENDER-GATED: the operator check below is the security boundary. The library
/// never checks who calls `spend`, so the custody layer must.
public fun execute_topup<T>(
    s: &mut Service,
    v: &mut Vault,
    user: address,
    amount: u64,
    clock: &Clock,
    ctx: &TxContext,
): Balance<T> {
    assert!(ctx.sender() == s.operator, ENotOperator);
    assert!(s.caps.contains(user), ENotRegistered);

    let cap = s.caps.borrow(user);
    v.spend<T>(cap, amount, clock, ctx)
}

/// Take a cap back out of custody. The grant is untouched: it stays live in the
/// vault; only custody of the cap changes hands.
public fun unregister(s: &mut Service, ctx: &TxContext): SpenderCap {
    assert!(s.caps.contains(ctx.sender()), ENotRegistered);
    s.caps.remove(ctx.sender())
}

// === Reads ===

/// The vault this service is pinned to.
public fun vault_id(s: &Service): ID {
    s.vault_id
}

/// Whether `user` currently has a cap in custody.
public fun is_registered(s: &Service, user: address): bool {
    s.caps.contains(user)
}
