module FACoin::predicate_fa {
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::fungible_asset::{Self, MintRef, TransferRef, BurnRef, Metadata, FungibleAsset, FungibleStore };
    use aptos_framework::primary_fungible_store;
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::function_info;
    use aptos_framework::account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::{Self, AptosCoin};

    use aptos_framework::aptos_account;
    use std::signer;
    use std::option;
    use std::event;
    use std::string::{Self, utf8};
    use std::debug;
    use aptos_std::math64;


    /* Errors */
    /// The caller is unauthorized.
    const EUNAUTHORIZED: u64 = 1;
    const E_LOW_SEQUENCE_NO: u64 = 2;

    /* Constants */
    const ASSET_NAME: vector<u8> = b"Predicate Fungible Asset";
    const ASSET_SYMBOL: vector<u8> = b"PFA";
    const CAP_RATE: u64 = 200;
    const SCALE_FACTOR: u64 = 100;

    /* Resources */
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Management has key {
        extend_ref: ExtendRef,
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef,
    }

    /* Events */
    #[event]
    struct Mint has drop, store {
        minter: address,
        to: address,
        amount: u64,
    }

    #[event]
    struct Burn has drop, store {
        minter: address,
        from: address,
        amount: u64,
    }

    /* View Functions */
    #[view]
    public fun metadata_address(): address {
        object::create_object_address(&@FACoin, ASSET_SYMBOL)
    }

    #[view]
    public fun metadata(): Object<Metadata> {
        object::address_to_object(metadata_address())
    }

    #[view]
    public fun deployer_store(): Object<FungibleStore> {
        primary_fungible_store::ensure_primary_store_exists(@FACoin, metadata())
    }

    /* Initialization - Asset Creation, Register Dispatch Functions */
    fun init_module(deployer: &signer) {
        // Create the fungible asset metadata object. 
        let constructor_ref = &object::create_named_object(deployer, ASSET_SYMBOL);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            utf8(ASSET_NAME), 
            utf8(ASSET_SYMBOL), 
            8, 
            utf8(b"http://example.com/favicon.ico"), 
            utf8(b"http://example.com"), 
        );

        // Generate a signer for the asset metadata object. 
        let metadata_object_signer = &object::generate_signer(constructor_ref);

        // Generate asset management refs and move to the metadata object.
        move_to(metadata_object_signer, Management {
            extend_ref: object::generate_extend_ref(constructor_ref),
            mint_ref: fungible_asset::generate_mint_ref(constructor_ref),
            burn_ref: fungible_asset::generate_burn_ref(constructor_ref),
            transfer_ref: fungible_asset::generate_transfer_ref(constructor_ref),
        });

        // Override the withdraw function.
        // This ensures all transfer will call the withdraw function in this module and impose a tax.
        let withdraw = function_info::new_function_info(
            deployer,
            string::utf8(b"predicate_fa"),
            string::utf8(b"withdraw"),
        );

        let deposit = function_info::new_function_info(
            deployer,
            string::utf8(b"predicate_fa"),
            string::utf8(b"deposit"),
        );

        dispatchable_fungible_asset::register_dispatch_functions(
            constructor_ref,
            option::some(withdraw),
            option::some(deposit),
            option::none(),
        );       
    }

    /* Dispatchable Hooks */
    /// Withdraw function override
    public fun withdraw<T: key>(
        store: Object<T>,
        amount: u64,
        transfer_ref: &TransferRef,
    ): FungibleAsset {
        let from_address = object::owner(store);
        let sequence_number = account::get_sequence_number(from_address);
        assert!(sequence_number > 0, 2);
        let asset = metadata();
        let max_cap = math64::mul_div(amount, CAP_RATE, SCALE_FACTOR);
        assert!(primary_fungible_store::balance(from_address, asset) >  max_cap, 3);

        fungible_asset::withdraw_with_ref(transfer_ref, store, amount)

    }

    public fun deposit<T: key>(
        store: Object<T>,
        fa: FungibleAsset,
        transfer_ref: &TransferRef,
    ) {
        let to_address = object::owner(store);
        let sequence_number = account::get_sequence_number(to_address);
        assert!(sequence_number > 0, 2);
        assert!(coin::balance<AptosCoin>(to_address) > 1000, 7);

        fungible_asset::deposit_with_ref(transfer_ref, store, fa);

    }

    /* Minting and Burning */
    /// Mint new assets to the specified account. 
    public entry fun mint(deployer: &signer, to: address, amount: u64) acquires Management {
        let management = borrow_global<Management>(metadata_address());
        let assets = fungible_asset::mint(&management.mint_ref, amount);
        fungible_asset::deposit_with_ref(&management.transfer_ref, primary_fungible_store::ensure_primary_store_exists(to, metadata()), assets);

        event::emit(Mint {
            minter: signer::address_of(deployer),
            to,
            amount,
        });
    }

    /// Burn assets from the specified account. 
    public entry fun burn(deployer: &signer, from: address, amount: u64) acquires Management {
        // Withdraw the assets from the account and burn them.
        let management = borrow_global<Management>(metadata_address());
        let assets = withdraw(primary_fungible_store::ensure_primary_store_exists(from, metadata()), amount, &management.transfer_ref);
        fungible_asset::burn(&management.burn_ref, assets);

        event::emit(Burn {
            minter: signer::address_of(deployer),
            from,
            amount,
        });
    }

    /* Transfer */
    /// Transfer assets from one account to another. 
    public entry fun transfer(from: &signer, to: address, amount: u64) acquires Management {
        // Withdraw the assets from the sender's store and deposit them to the recipient's store.
        let management = borrow_global<Management>(metadata_address());
        let from_store = primary_fungible_store::ensure_primary_store_exists(signer::address_of(from), metadata());
        let to_store = primary_fungible_store::ensure_primary_store_exists(to, metadata());
        let assets = withdraw(from_store, amount, &management.transfer_ref);
        deposit(to_store, assets, &management.transfer_ref);
    }

    #[test(creator = @FACoin, aaron = @0x123)]
    fun init_for_test(creator: &signer, aaron: &signer) acquires Management{
        let creator_address = signer::address_of(creator);
        
        account::create_account_for_test(creator_address);
        init_module(creator);
        
        let aaron_address = signer::address_of(aaron);
        account::create_account_for_test(aaron_address);
        
        let asset = metadata();

        mint(creator, creator_address, 100);
        debug::print(&account::get_sequence_number(creator_address));
        
        //to pass our sequence number assertion
        account::increment_sequence_number_for_test(creator_address);
        account::increment_sequence_number_for_test(aaron_address);

        //to pass our aptos coin balance assertion
        primary_fungible_store::deposit(aaron_address, aptos_coin::mint_apt_fa_for_test(1001));

        debug::print(&account::get_sequence_number(creator_address));
        assert!(primary_fungible_store::balance(aaron_address, asset) == 0, 4);
        transfer(creator, aaron_address, 10);
        assert!(primary_fungible_store::balance(aaron_address, asset) == 10, 5);
    }


    #[test(creator = @FACoin, aaron = @0x123)]
    #[expected_failure(abort_code = 2)]
    fun init_for_test_fail_seq_no_from(creator: &signer, aaron: &signer) acquires Management{
        let creator_address = signer::address_of(creator);
        
        account::create_account_for_test(creator_address);
        init_module(creator);

        let aaron_address = signer::address_of(aaron);
        account::create_account_for_test(aaron_address);
        
        let asset = metadata();

        mint(creator, creator_address, 100);
        assert!(primary_fungible_store::balance(aaron_address, asset) == 0, 4);
        transfer(creator, aaron_address, 10);
        assert!(primary_fungible_store::balance(aaron_address, asset) == 10, 5);
    }

    #[test(creator = @FACoin, aaron = @0x123)]
    #[expected_failure(abort_code = 7)]
    fun init_for_test_fail_min_balance_to(creator: &signer, aaron: &signer) acquires Management{
        let creator_address = signer::address_of(creator);
        
        account::create_account_for_test(creator_address);
        init_module(creator);
        
        let aaron_address = signer::address_of(aaron);
        account::create_account_for_test(aaron_address);
        
        let asset = metadata();

        mint(creator, creator_address, 100);
        debug::print(&account::get_sequence_number(creator_address));
        
        //to pass our sequence number assertion
        account::increment_sequence_number_for_test(creator_address);
        account::increment_sequence_number_for_test(aaron_address);

        //to fail our aptos coin balance assertion
        primary_fungible_store::deposit(aaron_address, aptos_coin::mint_apt_fa_for_test(1000));

        debug::print(&account::get_sequence_number(creator_address));
        assert!(primary_fungible_store::balance(aaron_address, asset) == 0, 4);
        transfer(creator, aaron_address, 10);
        assert!(primary_fungible_store::balance(aaron_address, asset) == 10, 5);
    }

    #[test(creator = @FACoin, aaron = @0x123)]
    #[expected_failure(abort_code = 3)]
    fun init_for_test_fail_max_cap_exceeded(creator: &signer, aaron: &signer) acquires Management{
        let creator_address = signer::address_of(creator);
        
        account::create_account_for_test(creator_address);
        init_module(creator);
        
        let aaron_address = signer::address_of(aaron);
        account::create_account_for_test(aaron_address);
        
        let asset = metadata();

        mint(creator, creator_address, 100);
        debug::print(&account::get_sequence_number(creator_address));
        
        //to pass our sequence number assertion
        account::increment_sequence_number_for_test(creator_address);
        account::increment_sequence_number_for_test(aaron_address);

        //to fail our aptos coin balance assertion
        primary_fungible_store::deposit(aaron_address, aptos_coin::mint_apt_fa_for_test(1001));

        debug::print(&account::get_sequence_number(creator_address));
        assert!(primary_fungible_store::balance(aaron_address, asset) == 0, 4);
        transfer(creator, aaron_address, 50000);
        assert!(primary_fungible_store::balance(aaron_address, asset) == 10, 5);
    }
}