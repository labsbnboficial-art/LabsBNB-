// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    LabsBNB (LBNB)
    Fixed supply token for BNB Smart Chain.

    TOKENOMICS
    -----------------------------
    Buy tax:  1.5%
    Sell tax: 1.5%

    0.5% Dev
    0.5% Auto-LP
    0.5% Burn

    Wallet-to-wallet transfers: 0%

    IMPORTANT:
    - No owner
    - No admin functions
    - No mint after deployment
    - No blacklist
    - No pause
    - No fee modification
    - No router modification
    - No wallet modification
    - No upgradeability
*/

interface IERC20 {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);

    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);
}

interface IPancakeFactory {
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);
}

interface IPancakePair {
    function totalSupply() external view returns (uint256);
}

interface IPancakeRouter02 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract LabsBNB is IERC20 {

    // =============================================================
    //                       TOKEN SETTINGS
    // =============================================================

    string private constant _NAME = "LabsBNB";
    string private constant _SYMBOL = "LBNB";
    uint8 private constant _DECIMALS = 18;

    uint256 private constant _TOTAL_SUPPLY =
        1_000_000 * 10 ** 18;

    // =============================================================
    //                     PANCAKESWAP BSC
    // =============================================================

    address public constant PANCAKE_ROUTER =
        0x10ED43C718714eb63d5aA57B78B54704E256024E;

    address public constant PANCAKE_FACTORY =
        0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    address public constant WBNB =
        0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // =============================================================
    //                         FEE WALLETS
    // =============================================================

    address public constant DEV_WALLET =
        0xa4d589dF0BA858DFA96c6fac20CC761Ea03dACa8;

    // Permanent dead address for Auto-LP tokens.
    address public constant DEAD =
        0x000000000000000000000000000000000000dEaD;

    // =============================================================
    //                           FEES
    // =============================================================

    uint256 public constant DEV_FEE_BPS = 50;   // 0.50%
    uint256 public constant LP_FEE_BPS = 50;    // 0.50%
    uint256 public constant BURN_FEE_BPS = 50;  // 0.50%

    uint256 public constant TOTAL_FEE_BPS =
        DEV_FEE_BPS +
        LP_FEE_BPS +
        BURN_FEE_BPS; // 150 = 1.50%

    uint256 private constant BPS = 10_000;

    /*
        Auto processing threshold.

        Once the contract has accumulated at least this many
        LBNB in Dev + LP fees, processing occurs on a SELL.

        1,000 LBNB = 0.1% of the total original supply.
    */
    uint256 public constant SWAP_THRESHOLD =
        1_000 * 10 ** 18;

    // =============================================================
    //                         ERC20 STORAGE
    // =============================================================

    uint256 private _totalSupply;

    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256))
        private _allowances;

    // =============================================================
    //                         DEX STORAGE
    // =============================================================

    IPancakeRouter02 public immutable router;

    address public immutable pair;

    bool private _inSwap;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 value
    );

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    event FeesProcessed(
        uint256 devTokens,
        uint256 devBNB,
        uint256 lpTokens,
        uint256 lpBNB
    );

    event TokensBurned(
        address indexed account,
        uint256 amount
    );

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor() {

        router = IPancakeRouter02(PANCAKE_ROUTER);

        require(
            router.factory() == PANCAKE_FACTORY,
            "Invalid Pancake factory"
        );

        require(
            router.WETH() == WBNB,
            "Invalid WBNB"
        );

        address existingPair =
            IPancakeFactory(PANCAKE_FACTORY).getPair(
                address(this),
                WBNB
            );

        if (existingPair == address(0)) {
            existingPair =
                IPancakeFactory(PANCAKE_FACTORY).createPair(
                    address(this),
                    WBNB
                );
        }

        pair = existingPair;

        // Entire supply goes to the deployment wallet.
        // There is no owner/admin role after deployment.
        _mint(msg.sender, _TOTAL_SUPPLY);

        // Approve PancakeSwap permanently.
        _approve(
            address(this),
            PANCAKE_ROUTER,
            type(uint256).max
        );
    }

    // =============================================================
    //                         ERC20 METADATA
    // =============================================================

    function name() external pure returns (string memory) {
        return _NAME;
    }

    function symbol() external pure returns (string memory) {
        return _SYMBOL;
    }

    function decimals() external pure returns (uint8) {
        return _DECIMALS;
    }

    // =============================================================
    //                         ERC20 VIEWS
    // =============================================================

    function totalSupply()
        external
        view
        override
        returns (uint256)
    {
        return _totalSupply;
    }

    function balanceOf(address account)
        public
        view
        override
        returns (uint256)
    {
        return _balances[account];
    }

    function allowance(
        address owner,
        address spender
    )
        external
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    // =============================================================
    //                         ERC20 ACTIONS
    // =============================================================

    function transfer(
        address recipient,
        uint256 amount
    )
        external
        override
        returns (bool)
    {
        _transfer(
            msg.sender,
            recipient,
            amount
        );

        return true;
    }

    function approve(
        address spender,
        uint256 amount
    )
        external
        override
        returns (bool)
    {
        _approve(
            msg.sender,
            spender,
            amount
        );

        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    )
        external
        override
        returns (bool)
    {
        uint256 currentAllowance =
            _allowances[sender][msg.sender];

        require(
            currentAllowance >= amount,
            "ERC20: insufficient allowance"
        );

        unchecked {
            _allowances[sender][msg.sender] =
                currentAllowance - amount;
        }

        emit Approval(
            sender,
            msg.sender,
            _allowances[sender][msg.sender]
        );

        _transfer(
            sender,
            recipient,
            amount
        );

        return true;
    }

    // =============================================================
    //                         INTERNAL ERC20
    // =============================================================

    function _mint(
        address account,
        uint256 amount
    ) internal {

        require(
            account != address(0),
            "ERC20: mint to zero"
        );

        _totalSupply += amount;
        _balances[account] += amount;

        emit Transfer(
            address(0),
            account,
            amount
        );
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal {

        require(
            owner != address(0),
            "ERC20: approve from zero"
        );

        require(
            spender != address(0),
            "ERC20: approve to zero"
        );

        _allowances[owner][spender] = amount;

        emit Approval(
            owner,
            spender,
            amount
        );
    }

    // =============================================================
    //                          TRANSFERS
    // =============================================================

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {

        require(
            from != address(0),
            "ERC20: transfer from zero"
        );

        require(
            to != address(0),
            "ERC20: transfer to zero"
        );

        require(
            _balances[from] >= amount,
            "ERC20: insufficient balance"
        );

        /*
            Internal contract operations are never taxed.

            This is necessary so that:
            - Dev swaps work.
            - Auto-LP works.
            - Router operations do not recursively trigger fees.
        */
        if (_inSwap) {
            _basicTransfer(
                from,
                to,
                amount
            );
            return;
        }

        /*
            The first liquidity provision is automatically
            fee-free.

            This happens only while the Pancake pair has
            zero LP token supply.

            There is no admin function to reactivate this.
        */
        bool initialLiquidity =
            to == pair &&
            IPancakePair(pair).totalSupply() == 0;

        bool isBuy =
            from == pair;

        bool isSell =
            to == pair;

        /*
            Normal wallet-to-wallet transfers:
            0% fee.

            First liquidity:
            0% fee.

            Buys/sells:
            1.50% fee.
        */
        if (
            !initialLiquidity &&
            (isBuy || isSell)
        ) {

            _transferWithFees(
                from,
                to,
                amount,
                isSell
            );

        } else {

            _basicTransfer(
                from,
                to,
                amount
            );
        }
    }

    function _basicTransfer(
        address from,
        address to,
        uint256 amount
    ) internal {

        unchecked {
            _balances[from] -= amount;
        }

        _balances[to] += amount;

        emit Transfer(
            from,
            to,
            amount
        );
    }

    // =============================================================
    //                       FEE CALCULATION
    // =============================================================

    function _transferWithFees(
        address from,
        address to,
        uint256 amount,
        bool isSell
    ) internal {

        uint256 devFee =
            (amount * DEV_FEE_BPS) / BPS;

        uint256 lpFee =
            (amount * LP_FEE_BPS) / BPS;

        uint256 burnFee =
            (amount * BURN_FEE_BPS) / BPS;

        uint256 totalFee =
            devFee +
            lpFee +
            burnFee;

        uint256 amountAfterFees =
            amount - totalFee;

        unchecked {
            _balances[from] -= amount;
        }

        // Recipient receives the net amount.
        _balances[to] += amountAfterFees;

        emit Transfer(
            from,
            to,
            amountAfterFees
        );

        /*
            Dev + LP fee tokens stay in this contract.

            They are later converted according to the
            fixed 50/50 Dev/LP allocation.
        */
        uint256 contractFee =
            devFee + lpFee;

        if (contractFee > 0) {

            _balances[address(this)] += contractFee;

            emit Transfer(
                from,
                address(this),
                contractFee
            );
        }

        /*
            Burn immediately.

            This permanently decreases totalSupply.
        */
        if (burnFee > 0) {

            _totalSupply -= burnFee;

            emit Transfer(
                from,
                address(0),
                burnFee
            );

            emit TokensBurned(
                from,
                burnFee
            );
        }

        /*
            Processing is triggered on sells only.

            This prevents every buy from creating another
            market sell and keeps normal buys lighter.

            The fees themselves are collected on BOTH
            buys and sells.
        */
        if (
            isSell &&
            _balances[address(this)] >= SWAP_THRESHOLD
        ) {
            _processFees();
        }
    }

    // =============================================================
    //                        FEE PROCESSING
    // =============================================================

    function _processFees() internal {

        if (_inSwap) {
            return;
        }

        uint256 tokenBalance =
            _balances[address(this)];

        if (tokenBalance == 0) {
            return;
        }

        _inSwap = true;

        /*
            Dev and LP allocations are both 0.50%.

            Therefore, of the accumulated 1.00% Dev+LP
            tokens:

                50% = Dev
                50% = LP
        */
        uint256 devTokens =
            tokenBalance / 2;

        uint256 lpTokens =
            tokenBalance - devTokens;

        uint256 devBNB = 0;
        uint256 lpBNB = 0;

        // ---------------------------------------------------------
        // DEV
        // ---------------------------------------------------------

        if (devTokens > 0) {

            uint256 bnbBefore =
                address(this).balance;

            _swapTokensForBNB(
                devTokens
            );

            uint256 bnbReceived =
                address(this).balance - bnbBefore;

            devBNB = bnbReceived;

            if (bnbReceived > 0) {

                (bool success, ) =
                    payable(DEV_WALLET).call{
                        value: bnbReceived
                    }("");

                require(
                    success,
                    "Dev BNB transfer failed"
                );
            }
        }

        // ---------------------------------------------------------
        // AUTO-LP
        // ---------------------------------------------------------

        if (lpTokens > 1) {

            /*
                Half of the LP allocation is converted to BNB.

                The other half remains as LBNB.

                This creates a balanced token + BNB
                liquidity contribution.
            */
            uint256 tokensToSwap =
                lpTokens / 2;

            uint256 tokensForLiquidity =
                lpTokens - tokensToSwap;

            uint256 bnbBeforeLP =
                address(this).balance;

            _swapTokensForBNB(
                tokensToSwap
            );

            uint256 bnbReceivedForLP =
                address(this).balance - bnbBeforeLP;

            /*
                Add the LBNB + BNB to PancakeSwap.

                LP tokens are sent to DEAD.

                Therefore the newly created liquidity
                cannot later be withdrawn by this contract.
            */
            if (
                tokensForLiquidity > 0 &&
                bnbReceivedForLP > 0
            ) {

                uint256 balanceBefore =
                    address(this).balance;

                router.addLiquidityETH{
                    value: bnbReceivedForLP
                }(
                    address(this),
                    tokensForLiquidity,
                    0,
                    0,
                    DEAD,
                    block.timestamp
                );

                uint256 balanceAfter =
                    address(this).balance;

                /*
                    Any extremely small BNB dust/refund
                    remains in the contract.
                */
                if (balanceAfter > balanceBefore) {
                    lpBNB =
                        balanceBefore + bnbReceivedForLP
                        - balanceAfter;
                } else {
                    lpBNB = bnbReceivedForLP;
                }
            }
        }

        _inSwap = false;

        emit FeesProcessed(
            devTokens,
            devBNB,
            lpTokens,
            lpBNB
        );
    }

    // =============================================================
    //                       TOKEN -> BNB SWAP
    // =============================================================

    function _swapTokensForBNB(
        uint256 tokenAmount
    ) internal {

        if (tokenAmount == 0) {
            return;
        }

        address[] memory path =
            new address[](2);

        path[0] = address(this);
        path[1] = WBNB;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    // =============================================================
    //                         BNB RECEIVER
    // =============================================================

    receive() external payable {}
}
