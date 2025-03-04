// Uses hodler's STRK balance to buy xSTRK at low price
// and request withdrawal on behalf of the caller

use starknet::ContractAddress;
use strkfarm_contracts::components::swap::{
    AvnuMultiRouteSwap
};

#[starknet::interface]
pub trait IArbWithHodl<TState> {
    fn perform_arb(
        ref self: TState,
        beneficiary: ContractAddress, // the one whose STRK is used for arb
        amount: u128, // amount of STRK to use for arb
        swap_path: AvnuMultiRouteSwap, // swap path to use for arb
        min_percent_bps: u128, // minimum percent gain to make arb
    );
}

#[starknet::interface]
pub trait IERC4626<TState> {
    fn convert_to_assets(self: @TState, shares: u256) -> u256;
    fn redeem(
        ref self: TState, shares: u256, receiver: ContractAddress, owner: ContractAddress
    ) -> u256;
}

#[derive(Drop, Copy, Serde)]
pub struct QueueState {
    pub max_request_id: u128,
    pub unprocessed_withdraw_queue_amount: u256,
    pub intransit_amount: u256,
    pub cumulative_requested_amount: u256
}

#[starknet::interface]
pub trait IWithdrawalQueue<TState> {
    fn get_queue_state(self: @TState) -> QueueState;
}

#[starknet::contract]
pub mod ArbWithHodl {
    use starknet::{
        ContractAddress,
        get_contract_address,
        contract_address::contract_address_const
    };
    use super::{
        IArbWithHodl,
        IERC4626Dispatcher, IERC4626DispatcherTrait,
        IWithdrawalQueueDispatcher, IWithdrawalQueueDispatcherTrait
    };
    use strkfarm_contracts::components::swap::{
        AvnuMultiRouteSwap, AvnuMultiRouteSwapImpl
    };
    use strkfarm_contracts::interfaces::oracle::{IPriceOracleDispatcher};

    #[derive(Drop, Copy, starknet::Event)]
    pub struct ArbWithHodl {
        pub beneficiary: ContractAddress,
        pub amount: u256,
        pub output_amount: u256,
        pub expected_gain: u256,
        pub wq_nft_id: u256,
    }

    #[storage]
    struct Storage {}

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ArbWithHodl: ArbWithHodl
    }

    #[abi(embed_v0)]
    impl ArbWithHodlImpl of IArbWithHodl<ContractState> {
        fn perform_arb(
            ref self: ContractState,
            beneficiary: ContractAddress,
            amount: u128,
            swap_path: AvnuMultiRouteSwap,
            min_percent_bps: u128,
        ) {
            // validations
            let strk = contract_address_const::<0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d>();
            let xstrk = contract_address_const::<0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a>();
            assert(swap_path.token_from_address == strk, 'Invalid token_from_address');
            assert(swap_path.token_to_address == xstrk, 'Invalid token_to_address');
            assert(swap_path.token_from_amount == amount.into(), 'Invalid token_from_amount');
            assert(swap_path.beneficiary == get_contract_address(), 'Invalid beneficiary');
            assert(swap_path.integrator_fee_amount_bps == 0, 'Need 0 fee');
            assert(swap_path.token_to_min_amount != 0, 'Invalid token_to_min_amount');
            assert(swap_path.routes.len() > 0, 'Invalid routes');

            // Perform swap
            strkfarm_contracts::helpers::ERC20Helper::strict_transfer_from(strk, beneficiary, get_contract_address(), amount.into());
            let oracle_addr = contract_address_const::<0x435ab4d9c05c00455f2cb583d8cead3a6e3e5e713de1890b0bb2dba6b8d8349>();
            let outputAmount = swap_path.swap(IPriceOracleDispatcher { contract_address: oracle_addr });

            // Assert min gain
            let xSTRKDisp = IERC4626Dispatcher {
                contract_address: xstrk
            };
            let post_withdraw_strk = xSTRKDisp.convert_to_assets(outputAmount);
            assert(post_withdraw_strk > amount.into(), 'Total loss');
            let gain = (post_withdraw_strk - amount.into()) * 10000 / amount.into();
            assert(gain >= min_percent_bps.into(), 'Not enough gain');

            // Withdraw. Queue NFT is sent to beneficiary
            // Endur's relayer shall complete the claim process when the time comes
            let wq = contract_address_const::<0x518a66e579f9eb1603f5ffaeff95d3f013788e9c37ee94995555026b9648b6>();
            let wqDisp = IWithdrawalQueueDispatcher {
                contract_address: wq
            };
            let nft_id = wqDisp.get_queue_state().max_request_id;
            xSTRKDisp.redeem(outputAmount, beneficiary, get_contract_address());

            self.emit(ArbWithHodl {
                beneficiary: beneficiary,
                amount: amount.into(),
                output_amount: outputAmount,
                expected_gain: post_withdraw_strk - amount.into(),
                wq_nft_id: nft_id.into()
            })
        }
    }
}