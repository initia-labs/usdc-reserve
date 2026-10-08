#[test_only]
module usdc_reserve::test {
    use std::option;
    use std::signer;
    use std::string;

    use initia_std::coin;
    use initia_std::event;
    use initia_std::fungible_asset;
    use initia_std::managed_coin;
    use initia_std::object;
    use initia_std::primary_fungible_store;

    use usdc_reserve::reserve;

    // The interwoven-1 denoms. The metadata address is derived from (0x1, symbol),
    // so creating them here must give the addresses pinned in Move.toml.
    const LEGACY_DENOM: vector<u8> = b"ibc/6490A7EAB61059BFC1CDDEB05917DD70BDF3A611654162A1A47DB930D40D8AF4";
    const BACKING_DENOM: vector<u8> = b"ibc/A64E1233F240D4B886413A12CF0300D6EC6FA0554DBD176119C399D0E2CA8048";

    const USER_LEGACY: u64 = 1_000_000;
    const FUNDER_BACKING: u64 = 1_200_000;

    fun setup(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        primary_fungible_store::init_module_for_test();

        create_ibc_coin(chain, LEGACY_DENOM);
        create_ibc_coin(chain, BACKING_DENOM);

        reserve::init_module_for_test(deployer);

        // existing users hold the Noble-backed token; the funder holds USDC.inj
        managed_coin::sudo_mint(
            chain,
            signer::address_of(user),
            reserve::legacy_metadata(),
            USER_LEGACY
        );
        managed_coin::sudo_mint(
            chain,
            signer::address_of(funder),
            reserve::backing_metadata(),
            FUNDER_BACKING
        );
    }

    fun create_ibc_coin(chain: &signer, denom: vector<u8>) {
        managed_coin::initialize(
            chain,
            option::none(),
            string::utf8(denom),
            string::utf8(denom),
            0,
            string::utf8(b""),
            string::utf8(b"")
        );
    }

    fun vault(): address {
        let (vault, _, _, _, _, _, _) =
            reserve::unpack_reserve_info_response(reserve::get_reserve_info());
        vault
    }

    /// (backing_balance, legacy_balance, pending_total, total_issued)
    fun balances(): (u64, u64, u64, u64) {
        let (_, _, backing, legacy, pending_total, total_issued, _) =
            reserve::unpack_reserve_info_response(reserve::get_reserve_info());
        (backing, legacy, pending_total, total_issued)
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    fun metadata_addresses_match_mainnet(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        assert!(
            coin::metadata_address(@initia_std, string::utf8(LEGACY_DENOM))
                == @legacy_usdc,
            0
        );
        assert!(
            coin::metadata_address(@initia_std, string::utf8(BACKING_DENOM))
                == @backing_usdc,
            1
        );
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    fun end_to_end(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);
        let user_addr = signer::address_of(user);
        let funder_addr = signer::address_of(funder);
        let legacy = reserve::legacy_metadata();
        let backing = reserve::backing_metadata();

        // funder deposits with headroom; nothing is committed yet
        reserve::deposit(funder, FUNDER_BACKING);
        assert!(reserve::get_pending_deposit(funder_addr) == FUNDER_BACKING, 0);
        let (vault_backing, _, pending_total, total_issued) = balances();
        assert!(vault_backing == 0 && total_issued == 0, 1);
        assert!(pending_total == FUNDER_BACKING, 2);

        // governance issues exactly the existing supply
        reserve::issue(chain, funder_addr, USER_LEGACY);
        assert!(coin::balance(funder_addr, legacy) == USER_LEGACY, 3);
        assert!(
            coin::supply(legacy) == option::some((2 * USER_LEGACY as u128)),
            4
        );
        let (vault_backing, vault_legacy, pending_total, total_issued) = balances();
        assert!(
            vault_backing == USER_LEGACY && vault_legacy == 0,
            5
        );
        assert!(total_issued == USER_LEGACY, 6);
        assert!(pending_total == FUNDER_BACKING - USER_LEGACY, 7);

        // the headroom was never committed, so the funder takes it back
        reserve::withdraw_deposit(funder, FUNDER_BACKING - USER_LEGACY);
        assert!(
            coin::balance(funder_addr, backing) == FUNDER_BACKING - USER_LEGACY,
            8
        );
        assert!(reserve::get_pending_deposit(funder_addr) == 0, 9);

        // redeem opens, a user swaps out and partly back in
        reserve::set_redeem_open(chain, true);
        reserve::redeem(user, 300_000);
        assert!(coin::balance(user_addr, backing) == 300_000, 10);
        assert!(
            coin::balance(user_addr, legacy) == USER_LEGACY - 300_000,
            11
        );

        reserve::wrap(user, 100_000);
        assert!(coin::balance(user_addr, backing) == 200_000, 12);
        assert!(
            coin::balance(user_addr, legacy) == USER_LEGACY - 200_000,
            13
        );

        // the swap events name who swapped
        assert!(
            event::was_event_emitted(
                &reserve::redeem_event_for_test(user_addr, 300_000)
            ),
            17
        );
        assert!(
            event::was_event_emitted(&reserve::wrap_event_for_test(user_addr, 100_000)),
            18
        );
        assert!(
            !event::was_event_emitted(
                &reserve::redeem_event_for_test(funder_addr, 300_000)
            ),
            19
        );

        // vault USDC.inj + vault existing token == total issued
        let (vault_backing, vault_legacy, _, total_issued) = balances();
        assert!(
            vault_backing == 800_000 && vault_legacy == 200_000,
            14
        );
        assert!(vault_backing + vault_legacy == total_issued, 15);

        // the funder swaps back the part it could not send to Noble
        reserve::redeem(funder, 50_000);
        let (vault_backing, vault_legacy, _, total_issued) = balances();
        assert!(vault_backing + vault_legacy == total_issued, 16);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    fun deposit_is_refundable_before_issue(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);
        let funder_addr = signer::address_of(funder);

        reserve::deposit(funder, FUNDER_BACKING);
        assert!(coin::balance(funder_addr, reserve::backing_metadata()) == 0, 0);

        // e.g. the vote failed
        reserve::withdraw_deposit(funder, FUNDER_BACKING);
        assert!(
            coin::balance(funder_addr, reserve::backing_metadata()) == FUNDER_BACKING,
            1
        );
        let (_, _, pending_total, _) = balances();
        assert!(pending_total == 0, 2);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x30003, location = usdc_reserve::reserve)]
    fun cannot_withdraw_committed_deposit(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);
        reserve::issue(chain, signer::address_of(funder), USER_LEGACY);
        reserve::withdraw_deposit(funder, 1);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x30003, location = usdc_reserve::reserve)]
    fun cannot_withdraw_someone_elses_deposit(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);
        reserve::withdraw_deposit(user, 1);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x50001, location = usdc_reserve::reserve)]
    fun only_chain_can_issue(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        // the publisher can pause, but it can't mint
        reserve::deposit(funder, USER_LEGACY);
        reserve::issue(deployer, signer::address_of(funder), USER_LEGACY);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x30003, location = usdc_reserve::reserve)]
    fun cannot_issue_more_than_deposited(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);
        reserve::issue(chain, signer::address_of(funder), USER_LEGACY + 1);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x30003, location = usdc_reserve::reserve)]
    fun issue_uses_only_the_named_funders_deposit(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);
        reserve::issue(chain, signer::address_of(user), USER_LEGACY);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x50001, location = usdc_reserve::reserve)]
    fun only_chain_or_publisher_can_set_redeem_open(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::set_redeem_open(user, true);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x30004, location = usdc_reserve::reserve)]
    fun publisher_can_pause_redeem(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);
        reserve::issue(chain, signer::address_of(funder), USER_LEGACY);
        reserve::set_redeem_open(chain, true);
        reserve::redeem(user, 1);

        // the publisher closes redeem without a vote
        reserve::set_redeem_open(deployer, false);
        reserve::redeem(user, 1);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x30004, location = usdc_reserve::reserve)]
    fun redeem_is_closed_until_opened(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);
        reserve::issue(chain, signer::address_of(funder), USER_LEGACY);
        reserve::redeem(user, 1);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x30004, location = usdc_reserve::reserve)]
    fun redeem_can_be_closed_again(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);
        reserve::issue(chain, signer::address_of(funder), USER_LEGACY);
        reserve::set_redeem_open(chain, true);
        reserve::redeem(user, 1);
        reserve::set_redeem_open(chain, false);
        reserve::redeem(user, 1);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x30005, location = usdc_reserve::reserve)]
    fun cannot_redeem_more_than_the_backing(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        // only half the supply is backed here
        reserve::deposit(funder, USER_LEGACY / 2);
        reserve::issue(chain, signer::address_of(funder), USER_LEGACY / 2);
        reserve::set_redeem_open(chain, true);
        reserve::redeem(user, USER_LEGACY / 2 + 1);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x30005, location = usdc_reserve::reserve)]
    fun cannot_wrap_more_than_the_vault_holds(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        // the vault holds no existing token until someone redeems
        reserve::wrap(funder, 1);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x10006, location = usdc_reserve::reserve)]
    fun redeem_rejects_the_wrong_asset(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);
        reserve::issue(chain, signer::address_of(funder), USER_LEGACY);
        reserve::set_redeem_open(chain, true);

        let wrong = coin::withdraw(funder, reserve::backing_metadata(), 1);
        let out = reserve::redeem_fa(funder, wrong);
        coin::deposit(signer::address_of(funder), out);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x10006, location = usdc_reserve::reserve)]
    fun wrap_rejects_the_wrong_asset(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        let wrong = coin::withdraw(user, reserve::legacy_metadata(), 1);
        let out = reserve::wrap_fa(user, wrong);
        coin::deposit(signer::address_of(user), out);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x10002, location = usdc_reserve::reserve)]
    fun zero_deposit_is_rejected(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, 0);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    fun vaults_are_owned_by_no_one(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        let (vault, pending_vault, _, _, _, _, _) =
            reserve::unpack_reserve_info_response(reserve::get_reserve_info());
        assert!(
            object::owner(object::address_to_object<object::ObjectCore>(vault)) == @0x0,
            0
        );
        assert!(
            object::owner(
                object::address_to_object<object::ObjectCore>(pending_vault)
            ) == @0x0,
            1
        );
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x50008, location = initia_std::fungible_asset)]
    fun chain_cannot_withdraw_from_the_vault_as_owner(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);
        reserve::issue(chain, signer::address_of(funder), USER_LEGACY);

        let store =
            primary_fungible_store::primary_store(vault(), reserve::backing_metadata());
        let taken = fungible_asset::withdraw(chain, store, 1);
        coin::deposit(signer::address_of(chain), taken);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x50008, location = initia_std::fungible_asset)]
    fun deployer_cannot_withdraw_from_the_vault(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);
        reserve::issue(chain, signer::address_of(funder), USER_LEGACY);

        let store =
            primary_fungible_store::primary_store(vault(), reserve::backing_metadata());
        let stolen = fungible_asset::withdraw(deployer, store, 1);
        coin::deposit(signer::address_of(deployer), stolen);
    }

    #[test(
        chain = @0x1, deployer = @usdc_reserve, user = @0xa11ce, funder = @0xf00d
    )]
    #[expected_failure(abort_code = 0x50008, location = initia_std::fungible_asset)]
    fun deployer_cannot_withdraw_pending_deposits(
        chain: &signer,
        deployer: &signer,
        user: &signer,
        funder: &signer
    ) {
        setup(chain, deployer, user, funder);

        reserve::deposit(funder, USER_LEGACY);

        let (_, pending_vault, _, _, _, _, _) =
            reserve::unpack_reserve_info_response(reserve::get_reserve_info());
        let store =
            primary_fungible_store::primary_store(
                pending_vault, reserve::backing_metadata()
            );
        let stolen = fungible_asset::withdraw(deployer, store, 1);
        coin::deposit(signer::address_of(deployer), stolen);
    }
}
