pragma solidity ^0.8.10;
// SPDX-License-Identifier: MIT 
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IUniswapV2Router02} from "./RouterV2.flat.sol";

/// @title Swap between XDC and a token through one fixed router
/// @notice Works with routers that use the Uniswap V2 interface. The router is set when this
/// contract is deployed and can never be changed by a caller. Each swap moves only the caller's
/// funds and pays only the caller. The caller sets the minimum output and the deadline, and a
/// minimum of zero is refused, since that would invite sandwich attacks.
contract DAppProxySwap is ReentrancyGuard{
    using SafeERC20 for IERC20;

    IUniswapV2Router02 public immutable router;
    address public immutable wrappedNative;

    event Swapped(address indexed _user, address indexed _token, bool _toToken, uint _amountIn, uint _amountOut);

    constructor(address _router){
        require(_router != address(0), "router is required");
        router = IUniswapV2Router02(_router);
        wrappedNative = IUniswapV2Router02(_router).WETH();
    }
    modifier protectedSwap(uint _minOut,uint _deadline){
        require(_minOut > 0, "minimum output is required");
        require(_deadline >= block.timestamp, "deadline has passed");
        _;
    }
    function pathFor(address _from,address _to) internal pure returns(address[] memory path){
        path = new address[](2);
        path[0] = _from;
        path[1] = _to;
    }
    /// @notice Swap the XDC sent with this call for _token, delivered to the caller
    function SwapIn(address _token,uint _minOut,uint _deadline)public payable nonReentrant protectedSwap(_minOut,_deadline) returns(uint){
        require(msg.value > 0, "XDC is required");
        uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(_minOut,pathFor(wrappedNative,_token),msg.sender,_deadline);
        uint out = amounts[amounts.length-1];
        emit Swapped(msg.sender,_token,true,msg.value,out);
        return out;
    }
    /// @notice Swap _total of the caller's _token for XDC, delivered to the caller.
    /// The caller must approve this contract first.
    function SwapOut(address _token,uint _total,uint _minOut,uint _deadline)public nonReentrant protectedSwap(_minOut,_deadline) returns(uint){
        require(_total > 0, "amount is required");
        IERC20 token = IERC20(_token);
        uint before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender,address(this),_total);
        require(token.balanceOf(address(this)) - before == _total, "tokens that take a fee are not supported");

        token.forceApprove(address(router),_total);
        uint[] memory amounts = router.swapExactTokensForETH(_total,_minOut,pathFor(_token,wrappedNative),msg.sender,_deadline);
        token.forceApprove(address(router),0);

        uint out = amounts[amounts.length-1];
        emit Swapped(msg.sender,_token,false,_total,out);
        return out;
    }
}
