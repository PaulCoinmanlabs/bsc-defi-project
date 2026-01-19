// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// 该合约只用于测试

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}
}

contract MockFactory {
    mapping(address => mapping(address => address)) public getPair;

    address public allPairs;

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair) {
        pair = address(
            uint160(uint(keccak256(abi.encodePacked(tokenA, tokenB))))
        );
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
        return pair;
    }
}

contract MockRouter {
    address public factory;
    address public WETH;

    constructor(address _factory, address _weth) {
        factory = _factory;
        WETH = _weth;
    }

    // 模拟加池子 (收到 BNB 和 Token，什么都不做，直接返回成功)
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity)
    {
        return (amountTokenDesired, msg.value, amountTokenDesired);
    }

    // 模拟卖币 (收到 Token，什么都不做)
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external {}
}
