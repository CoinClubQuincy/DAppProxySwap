// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/proxySwap.sol";

contract TestToken is ERC20 {
    constructor() ERC20("Tok", "TOK") {}
    function mint(address to, uint amount) external { _mint(to, amount); }
}

contract FeeToken is TestToken {
    function _transfer(address from, address to, uint amount) internal override {
        super._transfer(from, to, amount - amount / 10);
        _burn(from, amount / 10);
    }
}

/// Runs a callback in the middle of transferFrom.
contract HookToken is TestToken {
    address public target;
    bytes public payload;
    bool public hookSucceeded;
    function arm(address _target, bytes memory _payload) external { target = _target; payload = _payload; }
    function transferFrom(address from, address to, uint amount) public override returns (bool) {
        if (target != address(0)) {
            address t = target;
            target = address(0);
            (hookSucceeded, ) = t.call(payload);
        }
        return super.transferFrom(from, to, amount);
    }
}

/// A stand-in for a Uniswap V2 router paying 2 tokens per XDC, and half an XDC per token.
contract MockRouter {
    address public immutable WETH = address(0xE7);
    uint public lastDeadline;
    address[] public lastPath;
    uint public shortBy; // how much less than it reports the router delivers

    function setShortBy(uint amount) external { shortBy = amount; }

    receive() external payable {}

    function swapExactETHForTokens(uint minOut, address[] calldata path, address to, uint deadline) external payable returns (uint[] memory amounts) {
        require(deadline >= block.timestamp, "router: expired");
        uint out = msg.value * 2;
        require(out >= minOut, "router: insufficient output");
        lastDeadline = deadline;
        lastPath = path;
        TestToken(path[1]).mint(to, out - shortBy);
        amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = out;
    }

    function swapExactTokensForETH(uint amountIn, uint minOut, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts) {
        require(deadline >= block.timestamp, "router: expired");
        uint out = amountIn / 2;
        require(out >= minOut, "router: insufficient output");
        lastDeadline = deadline;
        lastPath = path;
        ERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        (bool ok, ) = to.call{value: out}("");
        require(ok, "router: payment failed");
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

contract ProxySwapTest is Test {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    MockRouter router;
    DAppProxySwap swap;
    TestToken token;

    function setUp() public {
        router = new MockRouter();
        swap = new DAppProxySwap(address(router));
        token = new TestToken();
        vm.deal(alice, 100 ether);
        vm.deal(address(router), 1000 ether);
        token.mint(alice, 100 ether);
    }

    function deadline() internal view returns (uint) {
        return block.timestamp + 60;
    }

    function test_ConstructorRequiresARouterAndReadsTheWrappedToken() public {
        vm.expectRevert("router is required");
        new DAppProxySwap(address(0));
        assertEq(swap.wrappedNative(), router.WETH());
    }

    function test_SwapInRefusesLessThanTheMinimumEvenWhenTheRouterReportsMore() public {
        router.setShortBy(1);
        vm.prank(alice);
        vm.expectRevert("received less than the minimum");
        swap.SwapIn{value: 1 ether}(address(token), 2 ether, deadline());
    }

    function test_SwapInReportsWhatActuallyArrived() public {
        router.setShortBy(1);
        vm.prank(alice);
        uint out = swap.SwapIn{value: 1 ether}(address(token), 1 ether, deadline());
        assertEq(out, 2 ether - 1);
    }

    function test_SwapInPaysTheCaller() public {
        vm.prank(alice);
        uint out = swap.SwapIn{value: 1 ether}(address(token), 2 ether, deadline());
        assertEq(out, 2 ether);
        assertEq(token.balanceOf(alice), 102 ether);
        assertEq(address(swap).balance, 0);
        assertEq(router.lastPath(0), router.WETH());
        assertEq(router.lastPath(1), address(token));
    }

    function test_SwapOutPaysTheCaller() public {
        vm.startPrank(alice);
        token.approve(address(swap), 10 ether);
        uint out = swap.SwapOut(address(token), 10 ether, 5 ether, deadline());
        vm.stopPrank();
        assertEq(out, 5 ether);
        assertEq(alice.balance, 105 ether);
        assertEq(token.balanceOf(alice), 90 ether);
        assertEq(token.balanceOf(address(swap)), 0);
        assertEq(router.lastPath(0), address(token));
        assertEq(router.lastPath(1), router.WETH());
    }

    function test_NoAllowanceIsLeftWithTheRouter() public {
        vm.startPrank(alice);
        token.approve(address(swap), 10 ether);
        swap.SwapOut(address(token), 10 ether, 5 ether, deadline());
        vm.stopPrank();
        assertEq(token.allowance(address(swap), address(router)), 0);
    }

    function test_AZeroMinimumIsRefused() public {
        vm.startPrank(alice);
        vm.expectRevert("minimum output is required");
        swap.SwapIn{value: 1 ether}(address(token), 0, deadline());
        vm.expectRevert("minimum output is required");
        swap.SwapOut(address(token), 1 ether, 0, deadline());
        vm.stopPrank();
    }

    function test_APassedDeadlineIsRefused() public {
        vm.warp(1000);
        vm.startPrank(alice);
        vm.expectRevert("deadline has passed");
        swap.SwapIn{value: 1 ether}(address(token), 1, 999);
        vm.expectRevert("deadline has passed");
        swap.SwapOut(address(token), 1 ether, 1, 999);
        vm.stopPrank();
    }

    function test_TheMinimumIsPassedToTheRouter() public {
        vm.prank(alice);
        vm.expectRevert("router: insufficient output");
        swap.SwapIn{value: 1 ether}(address(token), 2 ether + 1, deadline());
        vm.startPrank(alice);
        token.approve(address(swap), 10 ether);
        vm.expectRevert("router: insufficient output");
        swap.SwapOut(address(token), 10 ether, 5 ether + 1, deadline());
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_TheDeadlineIsPassedToTheRouter() public {
        uint d = deadline();
        vm.prank(alice);
        swap.SwapIn{value: 1 ether}(address(token), 1, d);
        assertEq(router.lastDeadline(), d);
    }

    function test_EmptySwapsAreRefused() public {
        vm.startPrank(alice);
        vm.expectRevert("XDC is required");
        swap.SwapIn(address(token), 1, deadline());
        vm.expectRevert("amount is required");
        swap.SwapOut(address(token), 0, 1, deadline());
        vm.stopPrank();
    }

    function test_ACallerCannotSpendAnotherUsersApproval() public {
        vm.prank(alice);
        token.approve(address(swap), 10 ether);
        vm.prank(bob);
        vm.expectRevert("ERC20: insufficient allowance");
        swap.SwapOut(address(token), 10 ether, 5 ether, deadline());
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_DirectPaymentsAreRefused() public {
        vm.prank(alice);
        (bool ok, ) = address(swap).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_FeeTokensAreRefused() public {
        FeeToken fee = new FeeToken();
        fee.mint(alice, 100 ether);
        vm.startPrank(alice);
        fee.approve(address(swap), 10 ether);
        vm.expectRevert("tokens that take a fee are not supported");
        swap.SwapOut(address(fee), 10 ether, 1, deadline());
        vm.stopPrank();
    }

    function test_ReentrantTokenCannotSwapAgain() public {
        HookToken hook = new HookToken();
        hook.mint(alice, 100 ether);
        hook.arm(address(swap), abi.encodeCall(DAppProxySwap.SwapOut, (address(hook), 1 ether, 1, block.timestamp + 60)));
        vm.startPrank(alice);
        hook.approve(address(swap), 10 ether);
        swap.SwapOut(address(hook), 10 ether, 5 ether, deadline());
        vm.stopPrank();
        assertFalse(hook.hookSucceeded());
        assertEq(alice.balance, 105 ether);
    }

    function testFuzz_SwapsLeaveNothingBehind(uint64 amountIn, uint64 amountOut) public {
        uint inValue = bound(amountIn, 1, 100 ether);
        uint outValue = bound(amountOut, 2, 100 ether);
        vm.startPrank(alice);
        swap.SwapIn{value: inValue}(address(token), inValue * 2, deadline());
        assertEq(token.balanceOf(alice), 100 ether + inValue * 2);
        token.approve(address(swap), outValue);
        swap.SwapOut(address(token), outValue, outValue / 2, deadline());
        vm.stopPrank();
        assertEq(address(swap).balance, 0);
        assertEq(token.balanceOf(address(swap)), 0);
        assertEq(token.allowance(address(swap), address(router)), 0);
        assertEq(alice.balance, 100 ether - inValue + outValue / 2);
    }
}
