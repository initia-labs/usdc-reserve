module usdc_reserve::reserve {
    use std::error;
    use std::signer;

    use initia_std::coin;
    use initia_std::event;
    use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};
    use initia_std::managed_coin;
    use initia_std::object::{Self, ExtendRef, Object};
    use initia_std::table::{Self, Table};

    // Errors
    /// the caller is not allowed to call this
    const EUNAUTHORIZED: u64 = 1;
    /// amount must be greater than zero
    const EZERO_AMOUNT: u64 = 2;
    /// the account uncommitted deposit is smaller than the amount
    const EINSUFFICIENT_DEPOSIT: u64 = 3;
    /// redeeming the existing token for USDC.inj is not open yet
    const EREDEEM_CLOSED: u64 = 4;
    /// vault does not hold enough of the requested asset
    const EINSUFFICIENT_RESERVE: u64 = 5;
    /// asset passed in is not the one this function accepts
    const EWRONG_ASSET: u64 = 6;

    // Resources
    struct ModuleStore has key {
        /// holds the committed USDC.inj and any existing token swapped back in
        vault_extend_ref: ExtendRef,
        vault_store_addr: address,
        /// holds deposits that gov has not committed yet
        pending_extend_ref: ExtendRef,
        pending_store_addr: address,
        /// uncommitted USDC.inj deposit per account
        pending: Table<address, u64>,
        pending_total: u64,
        /// whether `redeem` is open
        redeem_open: bool,
        total_issued: u64
    }

    // Responses
    struct ReserveInfoResponse has drop {
        vault_store_addr: address,
        pending_store_addr: address,
        legacy_metadata: Object<Metadata>,
        backing_metadata: Object<Metadata>,
        backing_balance: u64,
        legacy_balance: u64,
        pending_total: u64,
        total_issued: u64,
        redeem_open: bool
    }

    // Events

    #[event]
    struct DepositEvent has drop, store {
        account: address,
        amount: u64
    }

    #[event]
    struct WithdrawDepositEvent has drop, store {
        account: address,
        amount: u64
    }

    #[event]
    struct IssueEvent has drop, store {
        funder: address,
        amount: u64,
        total_issued: u64
    }

    #[event]
    struct SetRedeemOpenEvent has drop, store {
        open: bool
    }

    #[event]
    struct RedeemEvent has drop, store {
        account: address,
        amount: u64
    }

    #[event]
    struct WrapEvent has drop, store {
        account: address,
        amount: u64
    }

    fun init_module(publisher: &signer) {
        let vault_constructor_ref = object::create_object(@0x0, false);
        let pending_constructor_ref = object::create_object(@0x0, false);

        move_to(
            publisher,
            ModuleStore {
                vault_extend_ref: object::generate_extend_ref(&vault_constructor_ref),
                vault_store_addr: object::address_from_constructor_ref(
                    &vault_constructor_ref
                ),
                pending_extend_ref: object::generate_extend_ref(
                    &pending_constructor_ref
                ),
                pending_store_addr: object::address_from_constructor_ref(
                    &pending_constructor_ref
                ),
                pending: table::new(),
                pending_total: 0,
                redeem_open: false,
                total_issued: 0
            }
        );
    }

    // Entry Functions

    /// Deposit USDC.inj for a later `issue`. Withdrawable until committed.
    public entry fun deposit(account: &signer, amount: u64) acquires ModuleStore {
        assert!(amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let module_store = borrow_global_mut<ModuleStore>(@usdc_reserve);
        let addr = signer::address_of(account);

        let fa = coin::withdraw(account, backing_metadata(), amount);
        coin::deposit(module_store.pending_store_addr, fa);

        let pending = table::borrow_mut_with_default(&mut module_store.pending, addr, 0);
        *pending += amount;
        module_store.pending_total += amount;

        event::emit(DepositEvent { account: addr, amount });
    }

    /// Take back a deposit that gov has not committed.
    public entry fun withdraw_deposit(account: &signer, amount: u64) acquires ModuleStore {
        assert!(amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let module_store = borrow_global_mut<ModuleStore>(@usdc_reserve);
        let addr = signer::address_of(account);

        let fa = take_pending(module_store, addr, amount);
        coin::deposit(addr, fa);

        event::emit(WithdrawDepositEvent { account: addr, amount });
    }

    /// Commit `amount` of the funder's deposit as backing and mint the same
    /// amount of the existing token to the funder. gov only.
    public entry fun issue(chain: &signer, funder: address, amount: u64) acquires ModuleStore {
        check_sudo(chain);
        assert!(amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let module_store = borrow_global_mut<ModuleStore>(@usdc_reserve);

        let fa = take_pending(module_store, funder, amount);
        coin::deposit(module_store.vault_store_addr, fa);

        managed_coin::sudo_mint(chain, funder, legacy_metadata(), amount);
        module_store.total_issued += amount;

        event::emit(
            IssueEvent { funder, amount, total_issued: module_store.total_issued }
        );
    }

    /// Open or close `redeem`. Governance or the publisher can call this.
    /// Open it only once Noble inflow is blocked.
    public entry fun set_redeem_open(chain: &signer, open: bool) acquires ModuleStore {
        check_chain_permission(chain);

        let module_store = borrow_global_mut<ModuleStore>(@usdc_reserve);
        module_store.redeem_open = open;

        event::emit(SetRedeemOpenEvent { open });
    }

    /// Existing token -> USDC.inj, 1:1.
    public entry fun redeem(account: &signer, amount: u64) acquires ModuleStore {
        assert!(amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let legacy = coin::withdraw(account, legacy_metadata(), amount);
        let backing = redeem_fa(account, legacy);
        coin::deposit(signer::address_of(account), backing);
    }

    /// USDC.inj -> existing token, 1:1, out of what the vault holds.
    public entry fun wrap(account: &signer, amount: u64) acquires ModuleStore {
        assert!(amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let backing = coin::withdraw(account, backing_metadata(), amount);
        let legacy = wrap_fa(account, backing);
        coin::deposit(signer::address_of(account), legacy);
    }

    // Public Functions

    /// `account` is the caller recorded in the event. Taking a signer keeps it
    /// from being faked.
    public fun redeem_fa(account: &signer, legacy: FungibleAsset): FungibleAsset acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@usdc_reserve);
        assert!(module_store.redeem_open, error::invalid_state(EREDEEM_CLOSED));
        assert!(
            fungible_asset::asset_metadata(&legacy) == legacy_metadata(),
            error::invalid_argument(EWRONG_ASSET)
        );

        let amount = fungible_asset::amount(&legacy);
        let backing = swap(module_store, legacy, backing_metadata());

        event::emit(RedeemEvent { account: signer::address_of(account), amount });
        backing
    }

    /// `account` is the caller recorded in the event.
    public fun wrap_fa(account: &signer, backing: FungibleAsset): FungibleAsset acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@usdc_reserve);
        assert!(
            fungible_asset::asset_metadata(&backing) == backing_metadata(),
            error::invalid_argument(EWRONG_ASSET)
        );

        let amount = fungible_asset::amount(&backing);
        let legacy = swap(module_store, backing, legacy_metadata());

        event::emit(WrapEvent { account: signer::address_of(account), amount });
        legacy
    }

    public fun legacy_metadata(): Object<Metadata> {
        object::address_to_object<Metadata>(@legacy_usdc)
    }

    public fun backing_metadata(): Object<Metadata> {
        object::address_to_object<Metadata>(@backing_usdc)
    }

    // Helper Functions

    /// Put `fa_in` into the vault and take the same amount of `out` from it.
    fun swap(
        module_store: &ModuleStore, fa_in: FungibleAsset, out: Object<Metadata>
    ): FungibleAsset {
        let vault_store_addr = module_store.vault_store_addr;
        let amount = fungible_asset::amount(&fa_in);
        assert!(
            coin::balance(vault_store_addr, out) >= amount,
            error::invalid_state(EINSUFFICIENT_RESERVE)
        );

        coin::deposit(vault_store_addr, fa_in);
        let vault_signer =
            object::generate_signer_for_extending(&module_store.vault_extend_ref);
        coin::withdraw(&vault_signer, out, amount)
    }

    fun take_pending(
        module_store: &mut ModuleStore, account: address, amount: u64
    ): FungibleAsset {
        let pending = table::borrow_mut_with_default(
            &mut module_store.pending, account, 0
        );
        assert!(*pending >= amount, error::invalid_state(EINSUFFICIENT_DEPOSIT));
        *pending -= amount;
        module_store.pending_total -= amount;

        let pending_signer =
            object::generate_signer_for_extending(&module_store.pending_extend_ref);
        coin::withdraw(&pending_signer, backing_metadata(), amount)
    }

    fun check_chain_permission(chain: &signer) {
        let addr = signer::address_of(chain);
        assert!(
            addr == @initia_std || addr == @usdc_reserve,
            error::permission_denied(EUNAUTHORIZED)
        );
    }

    /// minting the existing token needs the 0x1 signer, so gov only
    fun check_sudo(chain: &signer) {
        assert!(
            signer::address_of(chain) == @initia_std,
            error::permission_denied(EUNAUTHORIZED)
        );
    }

    // View Functions

    #[view]
    public fun get_pending_deposit(account: address): u64 acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@usdc_reserve);
        *table::borrow_with_default(&module_store.pending, account, &0)
    }

    #[view]
    public fun get_reserve_info(): ReserveInfoResponse acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@usdc_reserve);
        let vault_store_addr = module_store.vault_store_addr;
        ReserveInfoResponse {
            vault_store_addr,
            pending_store_addr: module_store.pending_store_addr,
            legacy_metadata: legacy_metadata(),
            backing_metadata: backing_metadata(),
            backing_balance: coin::balance(vault_store_addr, backing_metadata()),
            legacy_balance: coin::balance(vault_store_addr, legacy_metadata()),
            pending_total: module_store.pending_total,
            total_issued: module_store.total_issued,
            redeem_open: module_store.redeem_open
        }
    }

    // Test Functions

    #[test_only]
    public fun init_module_for_test(publisher: &signer) {
        init_module(publisher);
    }

    #[test_only]
    public fun redeem_event_for_test(account: address, amount: u64): RedeemEvent {
        RedeemEvent { account, amount }
    }

    #[test_only]
    public fun wrap_event_for_test(account: address, amount: u64): WrapEvent {
        WrapEvent { account, amount }
    }

    #[test_only]
    /// (vault_store_addr, pending_store_addr, backing_balance, legacy_balance, pending_total, total_issued, redeem_open)
    public fun unpack_reserve_info_response(
        res: ReserveInfoResponse
    ): (address, address, u64, u64, u64, u64, bool) {
        (
            res.vault_store_addr,
            res.pending_store_addr,
            res.backing_balance,
            res.legacy_balance,
            res.pending_total,
            res.total_issued,
            res.redeem_open
        )
    }
}
