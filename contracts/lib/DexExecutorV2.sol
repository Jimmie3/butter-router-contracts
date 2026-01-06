// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


library DexExecutorV2 {
    using SafeERC20 for IERC20;
    address internal constant ZERO_ADDRESS = address(0);
    address internal constant NATIVE_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;


    enum DexType {
        AGG,
        UNIV2,
        UNIV3,
        CURVE,
        FILL,
        MIX
    }

    error DexExecutor_unsupported_dex_type();
    error DexExecutor_swap_failed();
    error DexExecutor_native_wrap_failed();
    error DexExecutor_call_function_black_list();

    function execute(
        uint8 _dexType,
        address _router,
        address _srcToken,
        uint256 _amount,
        bytes calldata _swap,
        mapping(bytes4 => bool) storage _funcBlackList
    ) internal {
        bool _result;
        DexType dexType = DexType(_dexType);
        if (dexType == DexType.AGG) {
            (_result) = makeAggSwap(_router, _amount, _srcToken, _swap, _funcBlackList);
        } else if (dexType == DexType.UNIV2) {
            (_result) = makeUniV2Swap(_router, _srcToken, _amount, _swap);
        } else if (dexType == DexType.UNIV3) {
            (_result) = makeUniV3Swap(_router, _srcToken, _amount, _swap);
        } else if (dexType == DexType.CURVE) {
            (_result) = makeCurveSwap(_router, _srcToken, _amount, _swap);
        } else if (dexType == DexType.FILL) {
            (_result) = makeAggFill(_srcToken,_router, _amount, _swap, _funcBlackList);
        } else if (dexType == DexType.MIX) {
            (_result) = makeMixSwap(_srcToken, _amount, _swap, _funcBlackList);
        } else {
            revert DexExecutor_unsupported_dex_type();
        }
        if(!_result) revert DexExecutor_swap_failed();
    }

    struct MixSwap {
        uint256 offset;
        address srcToken;
        address callTo;
        address approveTo;
        bytes callData;
    }

    function makeMixSwap(
        address _srcToken, 
        uint256 _amount, 
        bytes calldata _swapData,
        mapping(bytes4 => bool) storage _funcBlackList
    ) internal returns (bool result) {
        MixSwap[] memory mixSwaps = abi.decode(_swapData, (MixSwap[]));
        uint256 length = mixSwaps.length;

        for (uint256 i = 0; i < length; ) {
            MixSwap memory mix = mixSwaps[i];
            if (i != 0) {
                _srcToken = mix.srcToken;
                _amount = getBalance(_srcToken, address(this));
            }
            bytes memory callData = mix.callData;
            uint256 offset = mix.offset;
            if (offset > 35) {
                //32 length + 4 funcSig
                assembly {
                    mstore(add(callData, offset), _amount)
                }
            }
            checkApproval(_funcBlackList, getFirst4Bytes(callData));
            uint256 value = approveToken(_srcToken, mix.approveTo, _amount);
            (result, ) = mix.callTo.call{value: value}(callData);
            if (!result) break;
            unchecked {
                ++i;
            }
        }
    }

    function makeAggSwap(
        address _router,
        uint256 _amount,
        address _token,
        bytes calldata _swap,
        mapping(bytes4 => bool) storage _funcBlackList
    ) internal returns (bool _result) {
        bytes4 sig = bytes4(_swap[0:4]);
        checkApproval(_funcBlackList, sig);
        uint256 value = approveToken(_token, _router, _amount);
        (_result, ) = _router.call{value: value}(_swap);
 
    }

    function makeAggFill(
        address _token,
        address _router,
        uint256 _amount,
        bytes calldata _swapData,
        mapping(bytes4 => bool) storage _funcBlackList
    ) internal returns (bool result) {
        (uint256[] memory offsets, bytes memory callData) = abi.decode(_swapData, (uint256[], bytes));
        
        uint256 len = offsets.length;
        for (uint i = 0; i < len; ) {
            uint256 offset = offsets[i];
            if (offset > 35) {
                //32 length + 4 funcSig
                assembly {
                    mstore(add(callData, offset), _amount)
                }
            }
            unchecked {
                ++i;
            }
        }
        checkApproval(_funcBlackList, getFirst4Bytes(callData));
        uint256 value = approveToken(_token, _router, _amount);
        (result, ) = _router.call{value: value}(callData);
    }

    function makeUniV2Swap(
        address _router,
        address _srcToken,
        uint256 _amount,
        bytes calldata _swap
    ) internal returns (bool _result) {
        (uint256 amountOutMin, address[] memory path) = abi.decode(_swap, (uint256, address[]));
        // if input is native token, path[0] must be wtoken wrap it first
        if(isNative(_srcToken)) {
           _srcToken = path[0];
           safeDeposit(_srcToken, _amount);
        }
        uint256 value = approveToken(_srcToken, _router, _amount);
        (_result, ) = _router.call{value: value}(
            abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                _amount,
                amountOutMin,
                path,
                address(this),
                block.timestamp + 100
            )
        );
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function makeUniV3Swap(
        address _router,
        address _srcToken,
        uint256 _amount,
        bytes calldata _swap
    ) internal returns (bool _result) {
        (uint256 amountOutMin, bytes memory path) = abi.decode(_swap, (uint256, bytes));
        uint256 value = approveToken(_srcToken, _router, _amount);
        address receiver = address(this);
        ExactInputParams memory params = ExactInputParams(path, receiver, _amount, amountOutMin);
        bytes memory swapData = abi.encodeWithSignature("exactInput((bytes,address,uint256,uint256))", params);
        (_result, ) = _router.call{value: value}(swapData);
    }

    function makeCurveSwap(
        address _router,
        address _srcToken,
        uint256 _amount,
        bytes calldata _swap
    ) internal returns (bool _result) {
        (uint256 expected, address[9] memory routes, uint256[3][4] memory swap_params, address[4] memory pools) = abi
            .decode(_swap, (uint256, address[9], uint256[3][4], address[4]));
        uint256 value = approveToken(_srcToken, _router, _amount);
        (_result, ) = _router.call{value: value}(
            abi.encodeWithSignature(
                "exchange_multiple(address[9],uint256[3][4],uint256,uint256,address[4],address)",
                routes,
                swap_params,
                _amount,
                expected,
                pools,
                address(this)
            )
        );
    }

    function isNative(address token) internal pure returns (bool) {
        return (token == ZERO_ADDRESS || token == NATIVE_ADDRESS);
    }

    function getBalance(address _token, address _account) internal view returns (uint256) {
        if (isNative(_token)) {
            return _account.balance;
        } else {
            return IERC20(_token).balanceOf(_account);
        }
    }

    function transfer(uint256 _chainId, address _token, address _to, uint256 _amount) internal {
        if (isNative(_token)) {
            Address.sendValue(payable(_to), _amount);
        } else {
            if (_chainId == 728126428 && _token == 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C) {
                // Tron USDT
                _token.call(abi.encodeWithSelector(0xa9059cbb, _to, _amount));
            } else {
                IERC20(_token).safeTransfer(_to, _amount);
            }
        }
    }

    function safeDeposit(address _wToken, uint _value) internal {
        (bool success, bytes memory data) = _wToken.call{value: _value}(abi.encodeWithSelector(0xd0e30db0));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert DexExecutor_native_wrap_failed();
    }

    function getFirst4Bytes(bytes memory data) internal pure returns (bytes4 outBytes4) {
        if (data.length == 0) {
            return 0x0;
        }
        assembly {
            outBytes4 := mload(add(data, 32))
        }
    }

    function checkApproval(mapping(bytes4 => bool) storage funcBlackList, bytes4 sig) private view {
        if (funcBlackList[sig]) revert DexExecutor_call_function_black_list();
    }

    function approveToken(address token, address spender, uint256 amount) internal returns (uint256 value) {
        if (isNative(token)) {
            value = amount;
        } else {
            uint256 allowance = IERC20(token).allowance(address(this), spender);
            if (allowance < amount) {
                IERC20(token).forceApprove(spender, amount);
            }
        }
    }

}
