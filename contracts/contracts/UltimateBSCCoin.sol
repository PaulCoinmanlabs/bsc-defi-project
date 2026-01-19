// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// 因为我们只需要调用PancakeSwap (薄饼) 的功能 但不需要把它的源码全抄过来 只需要定义我们要用的函数接口即可

interface IUniswapV2Factory {
    // 创建一个新的交易对
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);
}

interface IUniswapV2Router02 {
    // 获取factory地址
    function factory() external pure returns (address);

    // 获取WBNB得地址 因为链上使用得是WBNB
    function WETH() external pure returns (address);

    // 添加流动性
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
        returns (uint amountToken, uint amountETH, uint liquidity);

    // 卖币换取bnb
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract UltimateBSCCoin is ERC20, Ownable {
    struct Taxes {
        uint256 marketing; // 营销税
        uint256 liquidity; // 流动性税（换算成 LP Token添加到底池子 进行护盘）
        uint256 total; // 总税率（自动计算）
    }

    // 设定初始买入得税 3%营销 + 2%流动性
    Taxes public buyTaxes = Taxes(3, 2, 5);

    // 设定初始卖出税 5%营销 + 5%流动性
    Taxes public sellTaxes = Taxes(5, 5, 10);

    uint256 public maxTxAmount; // 单笔交易最大允许得数量
    uint256 public maxWalletAmount; // 单个钱包最大允许持有得数量

    uint256 public swapTokensAmount; // 当税里面得代币达到设定得该数量自动swap为bnb

    address public marketingWallet; // 营销钱包
    IUniswapV2Router02 public router; // PancakeSwap 的路由器
    address public pair; // 流动性池子的地址

    bool public tradingEnabled = false; // 交易开关 默认关闭 防止机器人开盘操作
    bool public swapEnabled = true; // 是否开启将税兑换成bnb
    bool private swapping; // 锁：防止自己在卖币的时候又触发自己，导致死循环

    mapping(address => bool) public isExculdedFromFees; // 白名单 在该名单内不扣税
    mapping(address => bool) public isExculdedFromMaxTransaction; // 不受最大持仓、交易限制的名单
    mapping(address => bool) public automatedMarketMakerPairs; // 自动做市商 目前设置为池子 只要是池子 交互就是买卖
    mapping(address => bool) public isBlacklisted; // 黑名单

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event SwapAndLiquify(
        uint256 tokenSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiquidity
    );

    constructor(
        address _router,
        address _marketingWallet
    ) ERC20("Ultimate Moon", "UMOON") Ownable(msg.sender) {
        marketingWallet = _marketingWallet;
        router = IUniswapV2Router02(_router);
        // 创建代币的流动性池 当前池子里面还没有任何代币
        pair = IUniswapV2Factory(router.factory()).createPair(
            address(this),
            router.WETH()
        );
        // 将池子地址设置为自动做市商 后续只要跟这个地址交互 就被认为是买卖
        automatedMarketMakerPairs[pair] = true;

        // 设置免税白名单
        isExculdedFromFees[msg.sender] = true;
        isExculdedFromFees[address(this)] = true;
        isExculdedFromFees[address(0xdead)] = true;
        isExculdedFromFees[_marketingWallet] = true;

        // 设置不受限白名单
        isExculdedFromMaxTransaction[msg.sender] = true;
        isExculdedFromMaxTransaction[address(this)] = true;
        isExculdedFromMaxTransaction[address(0xdead)] = true;
        isExculdedFromMaxTransaction[_marketingWallet] = true;
        isExculdedFromMaxTransaction[address(router)] = true;
        isExculdedFromMaxTransaction[pair] = true;

        // 设置总量(总量10亿)
        uint256 totalSupply = 1_000_000_000 * 10 ** decimals();

        // 设置单笔交易 最多2%(2000万)
        maxTxAmount = (totalSupply * 2) / 100;
        // 设置单个钱包最多持仓
        maxWalletAmount = (totalSupply * 3) / 100;
        // 只要合约里面的代币到了500w就开始兑换bnb
        swapTokensAmount = (totalSupply * 5) / 1000;

        _mint(msg.sender, totalSupply);
    }
    // 必须实现该函数 因为合约在swapback的时候需要从router去接受bnb 没有该函数则无法接收
    receive() external payable {}

    // ERC20 每次转帐前都会先走这个函数 openzeppelin 4的版本是_beforeTokenTransfer
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // 校验黑名单
        require(
            !isBlacklisted[from] && !isBlacklisted[to],
            "Address is blacklisted"
        );
        // 交易是否开始 防止机器人操作 白名单操作则一般是PancakeSwap加池子
        if (!tradingEnabled) {
            require(
                isExculdedFromFees[from] || isExculdedFromFees[to],
                "Trading is not active."
            );
        }

        // 设置自动卖出的税的逻辑 不要在用户买入的时候去自动卖币 会有砸盘 用户体验不好 所以在卖出的时候 顺便卖出税收的
        bool canSwap = balanceOf(address(this)) >= swapTokensAmount;
        // 这是合约最复杂的部分。
        // 条件：
        // 1. 合约里的代币余额达到了阈值 (canSwap)
        // 2. 自动回流功能是开启的 (swapEnabled)
        // 3. 当前没有正在进行回流 (!swapping) -> 防止死循环
        // 4. 当前不是【买入】操作 (!automatedMarketMakerPairs[from]) -> 避免在用户买入时砸盘
        // 5. 交易双方不是白名单
        if (
            canSwap &&
            swapEnabled &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            !isExculdedFromFees[from] &&
            !isExculdedFromFees[to]
        ) {
            swapping = true; // 加锁
            swapBack();
            swapping = false;
        }

        bool takeFee = !swapping; // 默认情况 不是项目方自己卖 就是需要征收税

        if (isExculdedFromFees[from] || isExculdedFromFees[to]) {
            takeFee = false;
        }

        uint256 fees = 0;

        if (takeFee) {
            // 情况1： 买入（从池子里面到用户）
            if (
                automatedMarketMakerPairs[from] &&
                !isExculdedFromMaxTransaction[to]
            ) {
                require(
                    amount <= maxTxAmount,
                    "Buy amount exceeds maxTxAmount"
                );
                require(
                    balanceOf(to) + amount <= maxWalletAmount,
                    "Exceeds maxWalletAmount"
                );
                fees = (amount * buyTaxes.total) / 100;
            }
            // 情况2： 卖出
            else if (
                automatedMarketMakerPairs[to] &&
                !isExculdedFromMaxTransaction[from]
            ) {
                require(
                    amount <= maxTxAmount,
                    "Sell amount exceeds maxTxAmount"
                );
                fees = (amount * sellTaxes.total) / 100;
            }

            if (fees > 0) {
                super._update(from, address(this), fees); // 这里先转入合约 后续等待swapBack统一处理
                amount -= fees;
            }
        }

        super._update(from, to, amount); // 执行底层逻辑转账
    }

    // 该函数将合约里面的税转换成bnb和LP
    function swapBack() private {
        uint256 contractBalance = balanceOf(address(this));
        uint256 totalTokensSwap = swapTokensAmount;

        if (contractBalance == 0 || totalTokensSwap == 0) return;

        // 这里进行判断 如果积累的税太多了 一次性卖出会砸盘很难看 我们限制每次只处理阈值的20倍
        if (contractBalance > swapTokensAmount * 20) {
            contractBalance = swapTokensAmount * 20;
        }

        // 税收分成两部分 ： 一部分继续去添加流动性 ： 需要一半代币和一半的bnb  营销部分：全部变成bnb
        // 公式：流动性税 / 总税 / 2
        // 为什么要除以2？因为加池子时，Token和BNB是1:1配对的，所以我们只卖掉一半的流动性Token换BNB。
        uint256 liquidityTokens = (contractBalance * sellTaxes.liquidity) /
            sellTaxes.total /
            2;

        uint256 amountToSwapForETH = contractBalance - liquidityTokens; // 需要卖出得到BNB的：一部分是营销 一部分是后续要加池子的

        uint256 initalETHBalance = address(this).balance; // 记录合约初始的BNB

        swapTokenForETH(amountToSwapForETH);

        uint256 ethBalance = address(this).balance - initalETHBalance; // 查看本次卖出获得的BNB

        uint256 ethForMarketing = (ethBalance * sellTaxes.marketing) /
            (sellTaxes.total - (sellTaxes.liquidity / 2));

        uint256 ethForLiquidity = ethBalance - ethForMarketing;

        (bool success, ) = address(marketingWallet).call{value: ethForMarketing}(
            ""
        );

        if (liquidityTokens > 0 && ethForLiquidity > 0) {
            addLiquidity(liquidityTokens, ethForLiquidity);
            emit SwapAndLiquify(
                amountToSwapForETH,
                ethForLiquidity,
                liquidityTokens
            );
        }
    }

    function swapTokenForETH(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _approve(address(this), address(router), tokenAmount);

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function  addLiquidity(uint256 tokenAmount, uint256 ethAmount) private{
        _approve(address(this), address(router), tokenAmount);

        router.addLiquidityETH{value: ethAmount}(address(this), tokenAmount, 0, 0, address(0xdead), block.timestamp);
    }

    // 开启交易：一旦开启，无法通过此函数关闭 (防止项目方恶意关盘)
    function enableTrading() external onlyOwner {
        tradingEnabled = true;
    }

    // 设置黑名单：针对机器人
    function setBlacklist(address account, bool value) external onlyOwner {
        isBlacklisted[account] = value;
    }

    // 更新营销钱包地址
    function updateMarketingWallet(address newWallet) external onlyOwner {
        marketingWallet = newWallet;
    }

    // 设置免税名单
    function excludeFromFees(address account, bool excluded) public onlyOwner {
        isExculdedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    // 设置不受限名单
    function excludeFromMaxTransaction(address account, bool excluded) public onlyOwner {
        isExculdedFromMaxTransaction[account] = excluded;
    }
    
    // 设置做市商对 (如果以后上线了新的去中心化交易所，需要调用这个)
    function setAutomatedMarketMakerPair(address _pair, bool value) public onlyOwner {
        require(_pair != pair, "The pair cannot be removed from automatedMarketMakerPairs");
        _setAutomatedMarketMakerPair(_pair, value);
    }

    function _setAutomatedMarketMakerPair(address _pair, bool value) private {
        automatedMarketMakerPairs[_pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }


    function updateBuyTaxes(uint256 _marketing, uint256 _liquidity) external onlyOwner {
        buyTaxes.marketing = _marketing;
        buyTaxes.liquidity = _liquidity;
        buyTaxes.total = _marketing + _liquidity;
        require(buyTaxes.total <= 25, "Must keep fees at 25% or less");
    }

    function updateSellTaxes(uint256 _marketing, uint256 _liquidity) external onlyOwner {
        sellTaxes.marketing = _marketing;
        sellTaxes.liquidity = _liquidity;
        sellTaxes.total = _marketing + _liquidity;
        require(sellTaxes.total <= 25, "Must keep fees at 25% or less");
    }


    function updateLimits(uint256 _maxTxAmount, uint256 _maxWalletAmount) external onlyOwner {
        require(_maxTxAmount >= (totalSupply() * 5 / 1000), "Cannot set maxTx lower than 0.5%");
        require(_maxWalletAmount >= (totalSupply() * 1 / 100), "Cannot set maxWallet lower than 1%");
        maxTxAmount = _maxTxAmount;
        maxWalletAmount = _maxWalletAmount;
    }

    function updateSwapTokensAtAmount(uint256 newAmount) external onlyOwner {
        require(newAmount >= totalSupply() * 1 / 100000, "Swap amount cannot be lower than 0.001% total supply.");
        require(newAmount <= totalSupply() * 5 / 1000, "Swap amount cannot be higher than 0.5% total supply.");
        swapTokensAmount = newAmount;
    }


    function updateSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
    }

    function withdrawStuckETH() external onlyOwner {
        (bool success, ) = address(msg.sender).call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }


    function withdrawStuckToken(address _token, address _to) external onlyOwner {
        require(_token != address(this), "Cannot remove native token"); // 禁止提自己的币
        uint256 _contractBalance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transfer(_to, _contractBalance);
    }
}
