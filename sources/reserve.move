module usdc_reserve::reserve {
    use std::error;
    use std::signer;

    use initia_std::coin;
    use initia_std::event;
    use initia_std::fungible_asset::Metadata;
    use initia_std::managed_coin;
    use initia_std::object::{Self, ExtendRef, Object};

    // Errors
    /// the caller is not allowed to call this
    const EUNAUTHORIZED: u64 = 1;
    /// amount must be greater than zero
    const EZERO_AMOUNT: u64 = 2;
    /// redeem is not enabled
    const ENOT_REDEEMABLE: u64 = 3;
    /// vault does not hold enough of the requested asset
    const EINSUFFICIENT_RESERVE: u64 = 4;

    // Resources
    struct ModuleStore has key {
        /// the vault, holding what `issue` minted and whatever is swapped in
        extend_ref: ExtendRef,
        is_redeemable: bool,
        total_issued: u64
    }

    // Responses
    struct ReserveInfoResponse has drop {
        vault_store_addr: address,
        legacy_metadata: Object<Metadata>,
        backing_metadata: Object<Metadata>,
        legacy_balance: u64,
        backing_balance: u64,
        total_issued: u64,
        is_redeemable: bool
    }

    // Events
    #[event]
    struct IssueEvent has drop, store {
        amount: u64,
        total_issued: u64
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
        let constructor_ref = object::create_object(@0x0, false);
        move_to(
            publisher,
            ModuleStore {
                extend_ref: object::generate_extend_ref(&constructor_ref),
                is_redeemable: false,
                total_issued: 0
            }
        );
    }

    // Entry Functions
    /// Mint `amount` of the existing token into the vault. It leaves the vault
    /// only through `wrap`, 1:1 against USDC.inj. Only gov can call this.
    public entry fun issue(chain: &signer, amount: u64) acquires ModuleStore {
        check_gov(chain);
        assert!(amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let module_store = borrow_global_mut<ModuleStore>(@usdc_reserve);
        managed_coin::sudo_mint(
            chain,
            object::address_from_extend_ref(&module_store.extend_ref),
            legacy_metadata(),
            amount
        );
        module_store.total_issued += amount;

        event::emit(IssueEvent { amount, total_issued: module_store.total_issued });
    }

    /// Enable or disable `redeem`. Only gov or the publisher can call this.
    /// Enable it only once Noble inflow is blocked.
    public entry fun set_redeemable(account: &signer, is_redeemable: bool) acquires ModuleStore {
        check_gov_or_publisher(account);

        let module_store = borrow_global_mut<ModuleStore>(@usdc_reserve);
        module_store.is_redeemable = is_redeemable;
    }

    /// Existing token -> USDC.inj, 1:1, out of what the vault holds. Only
    /// while `redeem` is enabled.
    public entry fun redeem(account: &signer, amount: u64) acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@usdc_reserve);
        assert!(module_store.is_redeemable, error::invalid_state(ENOT_REDEEMABLE));

        swap(
            module_store,
            account,
            amount,
            legacy_metadata(),
            backing_metadata()
        );
        event::emit(RedeemEvent { account: signer::address_of(account), amount });
    }

    /// USDC.inj -> existing token, 1:1, out of what the vault holds. This is
    /// also how the funder pays for what `issue` minted.
    public entry fun wrap(account: &signer, amount: u64) acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@usdc_reserve);
        swap(
            module_store,
            account,
            amount,
            backing_metadata(),
            legacy_metadata()
        );
        event::emit(WrapEvent { account: signer::address_of(account), amount });
    }

    // Public Functions
    public fun legacy_metadata(): Object<Metadata> {
        object::address_to_object<Metadata>(@legacy_usdc)
    }

    public fun backing_metadata(): Object<Metadata> {
        object::address_to_object<Metadata>(@backing_usdc)
    }

    // Helper Functions
    /// Move `amount` of `in_metadata` from `account` into the vault and the same
    /// amount of `out_metadata` from the vault back to `account`.
    fun swap(
        module_store: &ModuleStore,
        account: &signer,
        amount: u64,
        in_metadata: Object<Metadata>,
        out_metadata: Object<Metadata>
    ) {
        assert!(amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let vault_store_addr = object::address_from_extend_ref(&module_store.extend_ref);
        assert!(
            coin::balance(vault_store_addr, out_metadata) >= amount,
            error::invalid_state(EINSUFFICIENT_RESERVE)
        );

        let vault_signer =
            object::generate_signer_for_extending(&module_store.extend_ref);
        coin::transfer(account, vault_store_addr, in_metadata, amount);
        coin::transfer(
            &vault_signer,
            signer::address_of(account),
            out_metadata,
            amount
        );
    }

    fun check_gov_or_publisher(account: &signer) {
        let addr = signer::address_of(account);
        assert!(
            addr == @initia_std || addr == @usdc_reserve,
            error::permission_denied(EUNAUTHORIZED)
        );
    }

    /// Minting the existing token needs the 0x1 signer, so only gov passes.
    fun check_gov(chain: &signer) {
        assert!(
            signer::address_of(chain) == @initia_std,
            error::permission_denied(EUNAUTHORIZED)
        );
    }

    // View Functions
    #[view]
    public fun get_reserve_info(): ReserveInfoResponse acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@usdc_reserve);
        let vault_store_addr = object::address_from_extend_ref(&module_store.extend_ref);
        ReserveInfoResponse {
            vault_store_addr,
            legacy_metadata: legacy_metadata(),
            backing_metadata: backing_metadata(),
            legacy_balance: coin::balance(vault_store_addr, legacy_metadata()),
            backing_balance: coin::balance(vault_store_addr, backing_metadata()),
            total_issued: module_store.total_issued,
            is_redeemable: module_store.is_redeemable
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
    /// (vault_store_addr, legacy_balance, backing_balance, total_issued, is_redeemable)
    public fun unpack_reserve_info_response(res: ReserveInfoResponse)
        : (address, u64, u64, u64, bool) {
        (
            res.vault_store_addr,
            res.legacy_balance,
            res.backing_balance,
            res.total_issued,
            res.is_redeemable
        )
    }
}
