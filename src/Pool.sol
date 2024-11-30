// SPDX-License-Identifier: MIT

/// 0xFaE1701bC57FC694F836F0704642E15E43C88d3A

pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Clones} from "./libraries/Clones.sol";
import {IFunDeployer} from "./interfaces/IFunDeployer.sol";
import {IFunEventTracker} from "./interfaces/IFunEventTracker.sol";

import {IUniswapV2Router02} from "@v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "@v2-core/contracts/interfaces/IUniswapV2Factory.sol";

import "forge-std/console.sol";

interface IFunToken {
    function initialize(
        uint256 initialSupply,
        string memory _name,
        string memory _symbol,
        address _midDeployer,
        address _deployer
    ) external;
    function initiateDex() external;
}

contract FunPool is Ownable, ReentrancyGuard {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant HUNDRED = 100;
    uint256 public constant BASIS_POINTS = 10000;

    struct FunTokenPoolData {
        uint256 reserveTokens;
        uint256 reserveETH;
        uint256 volume;
        uint256 listThreshold;
        uint256 initialReserveEth;
        uint8 nativePer;
        bool tradeActive;
        bool royalemitted;
    }

    struct FunTokenPool {
        address creator;
        address token;
        address baseToken;
        address router;
        address lockerAddress;
        address storedLPAddress;
        address deployer;
        FunTokenPoolData pool;
    }

    // deployer allowed to create fun tokens
    mapping(address => bool) public allowedDeployers;
    // user => array of fun tokens
    mapping(address => address[]) public userFunTokens;
    // fun token => fun token details
    mapping(address => FunTokenPool) public tokenPools;

    address public implementation;
    address public feeContract;
    address public stableAddress;
    address public lpLockDeployer;
    address public eventTracker;
    uint16 public feePer;

    event LiquidityAdded(address indexed provider, uint256 tokenAmount, uint256 ethAmount);
    event sold(
        address indexed user,
        uint256 amountIn,
        uint256 amountOut,
        uint256 _time,
        uint256 reserveEth,
        uint256 reserveTokens,
        uint256 totalVolume
    );
    event bought(
        address indexed user,
        uint256 amountIn,
        uint256 amountOut,
        uint256 _time,
        uint256 reserveEth,
        uint256 reserveTokens,
        uint256 totalVolume
    );
    event funTradeCall(
        address indexed user,
        uint256 amountIn,
        uint256 amountOut,
        uint256 _time,
        uint256 reserveEth,
        uint256 reserveTokens,
        string tradeType,
        uint256 totalVolume
    );
    event listed(
        address indexed user,
        address indexed tokenAddress,
        address indexed router,
        uint256 liquidityAmount,
        uint256 tokenAmount,
        uint256 _time,
        uint256 totalVolume
    );

    constructor(
        address _implementation,
        address _feeContract,
        address _lpLockDeployer,
        address _stableAddress,
        address _eventTracker,
        uint16 _feePer
    ) payable Ownable(msg.sender) {
        implementation = _implementation;
        feeContract = _feeContract;
        lpLockDeployer = _lpLockDeployer;
        stableAddress = _stableAddress;
        eventTracker = _eventTracker;
        feePer = _feePer;
    }

    function createFun(
        string[2] memory _name_symbol,
        uint256 _totalSupply,
        address _creator,
        address _baseToken,
        address _router,
        uint256[2] memory listThreshold_initReserveEth
    ) public payable returns (address) {
        require(allowedDeployers[msg.sender], "not deployer");

        address funToken = Clones.clone(implementation);
        IFunToken(funToken).initialize(_totalSupply, _name_symbol[0], _name_symbol[1], address(this), msg.sender);

        // add tokens to the tokens user list
        userFunTokens[_creator].push(funToken);

        // create the pool data
        FunTokenPool memory pool;

        pool.creator = _creator;
        pool.token = funToken;
        pool.baseToken = _baseToken;
        pool.router = _router;
        pool.deployer = msg.sender;

        if (_baseToken == IUniswapV2Router02(_router).WETH()) {
            pool.pool.nativePer = 100;
        } else {
            pool.pool.nativePer = 50;
        }
        pool.pool.tradeActive = true;
        pool.pool.reserveTokens += _totalSupply;
        pool.pool.reserveETH += (listThreshold_initReserveEth[1] + msg.value);
        pool.pool.listThreshold = listThreshold_initReserveEth[0];
        pool.pool.initialReserveEth = listThreshold_initReserveEth[1];

        // add the fun data for the fun token
        tokenPools[funToken] = pool;
        // tokenPoolData[funToken] = funPoolData;

        emit LiquidityAdded(address(this), _totalSupply, msg.value);

        return address(funToken); // return fun token address
    }

    // Calculate amount of output tokens or ETH to give out
    function getAmountOutTokens(address funToken, uint256 amountIn) public view returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid input amount");
        FunTokenPool storage token = tokenPools[funToken];
        require(token.pool.reserveTokens > 0 && token.pool.reserveETH > 0, "Invalid reserves");

        uint256 numerator = amountIn * token.pool.reserveTokens;
        uint256 denominator = (token.pool.reserveETH) + amountIn;
        amountOut = numerator / denominator;
    }

    function getAmountOutETH(address funToken, uint256 amountIn) public view returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid input amount");
        FunTokenPool storage token = tokenPools[funToken];
        require(token.pool.reserveTokens > 0 && token.pool.reserveETH > 0, "Invalid reserves");

        uint256 numerator = amountIn * token.pool.reserveETH;
        uint256 denominator = (token.pool.reserveTokens) + amountIn;
        amountOut = numerator / denominator;
    }

    function getBaseToken(address funToken) public view returns (address) {
        FunTokenPool storage token = tokenPools[funToken];
        return address(token.baseToken);
    }

    function getWrapAddr(address funToken) public view returns (address) {
        return IUniswapV2Router02(tokenPools[funToken].router).WETH();
    }

    function getAmountsMinToken(address funToken, address _tokenAddress, uint256 _ethIN)
        public
        view
        returns (uint256)
    {
        // generate the pair path of token -> weth
        uint256[] memory amountMinArr;
        address[] memory path = new address[](2);
        path[0] = getWrapAddr(funToken);
        path[1] = address(_tokenAddress);
        amountMinArr = IUniswapV2Router02(tokenPools[funToken].router).getAmountsOut(_ethIN, path);
        return uint256(amountMinArr[1]);
    }

    function getCurrentCap(address funToken) public view returns (uint256) {
        FunTokenPool storage token = tokenPools[funToken];
        return (getAmountsMinToken(funToken, stableAddress, token.pool.reserveETH) * IERC20(funToken).totalSupply())
            / token.pool.reserveTokens;
    }

    function getFuntokenPool(address funToken) public view returns (FunTokenPool memory) {
        return tokenPools[funToken];
    }

    function getFuntokenPools(address[] memory funTokens) public view returns (FunTokenPool[] memory) {
        uint256 length = funTokens.length;
        FunTokenPool[] memory pools = new FunTokenPool[](length);
        for (uint256 i = 0; i < length;) {
            pools[i] = tokenPools[funTokens[i]];
            unchecked {
                i++;
            }
        }
        return pools;
    }

    function getUserFuntokens(address user) public view returns (address[] memory) {
        return userFunTokens[user];
    }

    function sellTokens(address funToken, uint256 tokenAmount, uint256 minEth, address _affiliate)
        public
        nonReentrant
        returns (bool, bool)
    {
        FunTokenPool storage token = tokenPools[funToken];
        require(token.pool.tradeActive, "Trading not active");

        uint256 tokenToSell = tokenAmount;
        uint256 ethAmount = getAmountOutETH(funToken, tokenToSell);
        uint256 ethAmountFee = (ethAmount * feePer) / BASIS_POINTS;
        uint256 ethAmountOwnerFee = (ethAmountFee * (IFunDeployer(token.deployer).getOwnerPer())) / BASIS_POINTS;
        uint256 affiliateFee =
            (ethAmountFee * (IFunDeployer(token.deployer).getAffiliatePer(_affiliate))) / BASIS_POINTS;
        require(ethAmount > 0 && ethAmount >= minEth, "Slippage too high");

        token.pool.reserveTokens += tokenAmount;
        token.pool.reserveETH -= ethAmount;
        token.pool.volume += ethAmount;

        IERC20(funToken).transferFrom(msg.sender, address(this), tokenToSell);
        (bool success,) = feeContract.call{value: ethAmountFee - ethAmountOwnerFee - affiliateFee}(""); // paying plat fee
        require(success, "fee ETH transfer failed");

        (success,) = _affiliate.call{value: affiliateFee}(""); // paying affiliate fee which is same amount as plat fee %
        require(success, "aff ETH transfer failed");

        (success,) = payable(owner()).call{value: ethAmountOwnerFee}(""); // paying owner fee per tx
        require(success, "ownr ETH transfer failed");

        (success,) = msg.sender.call{value: ethAmount - ethAmountFee}("");
        require(success, "seller ETH transfer failed");

        emit sold(
            msg.sender,
            tokenAmount,
            ethAmount,
            block.timestamp,
            token.pool.reserveETH,
            token.pool.reserveTokens,
            token.pool.volume
        );
        emit funTradeCall(
            msg.sender,
            tokenAmount,
            ethAmount,
            block.timestamp,
            token.pool.reserveETH,
            token.pool.reserveTokens,
            "sell",
            token.pool.volume
        );
        IFunEventTracker(eventTracker).sellEvent(msg.sender, funToken, tokenToSell, ethAmount);

        return (true, true);
    }

    function buyTokens(address funToken, uint256 minTokens, address _affiliate) public payable nonReentrant {
        require(msg.value > 0, "Invalid buy value");
        FunTokenPool storage token = tokenPools[funToken];
        require(token.pool.tradeActive, "Trading not active");

        {
            uint256 ethAmount = msg.value;
            uint256 ethAmountFee = (ethAmount * feePer) / BASIS_POINTS;
            uint256 ethAmountOwnerFee = (ethAmountFee * (IFunDeployer(token.deployer).getOwnerPer())) / BASIS_POINTS;
            uint256 affiliateFee =
                (ethAmountFee * (IFunDeployer(token.deployer).getAffiliatePer(_affiliate))) / BASIS_POINTS;

            uint256 tokenAmount = getAmountOutTokens(funToken, ethAmount - ethAmountFee);
            require(tokenAmount >= minTokens, "Slippage too high");

            token.pool.reserveETH += (ethAmount - ethAmountFee);
            token.pool.reserveTokens -= tokenAmount;
            token.pool.volume += ethAmount;

            (bool success,) = feeContract.call{value: ethAmountFee - ethAmountOwnerFee - affiliateFee}(""); // paying plat fee
            require(success, "fee ETH transfer failed");

            (success,) = _affiliate.call{value: affiliateFee}(""); // paying affiliate fee which is same amount as plat fee %
            require(success, "fee ETH transfer failed");

            (success,) = payable(owner()).call{value: ethAmountOwnerFee}(""); // paying owner fee per tx
            require(success, "fee ETH transfer failed");

            IERC20(funToken).transfer(msg.sender, tokenAmount);
            emit bought(
                msg.sender,
                msg.value,
                tokenAmount,
                block.timestamp,
                token.pool.reserveETH,
                token.pool.reserveTokens,
                token.pool.volume
            );
            emit funTradeCall(
                msg.sender,
                msg.value,
                tokenAmount,
                block.timestamp,
                token.pool.reserveETH,
                token.pool.reserveTokens,
                "buy",
                token.pool.volume
            );
            IFunEventTracker(eventTracker).buyEvent(msg.sender, funToken, msg.value, tokenAmount);
        }

        uint256 currentMarketCap = getCurrentCap(funToken);
        uint256 listThresholdCap = token.pool.listThreshold * 10 ** IERC20Metadata(stableAddress).decimals();

        // using liquidity value inside contract to check when to add liquidity to DEX
        if (currentMarketCap >= (listThresholdCap / 2) && !token.pool.royalemitted) {
            IFunDeployer(token.deployer).emitRoyal(
                funToken,
                funToken,
                token.router,
                token.baseToken,
                token.pool.reserveETH,
                token.pool.reserveTokens,
                block.timestamp,
                token.pool.volume
            );
            token.pool.royalemitted = true;
        }
        // using marketcap value of token to check when to add liquidity to DEX
        if (currentMarketCap >= listThresholdCap) {
            token.pool.tradeActive = false;
            IFunToken(funToken).initiateDex();
            token.pool.reserveETH -= token.pool.initialReserveEth;
            if (token.pool.nativePer > 0) {
                _addLiquidityETH(
                    funToken,
                    (IERC20(funToken).balanceOf(address(this)) * token.pool.nativePer) / HUNDRED,
                    (token.pool.reserveETH * token.pool.nativePer) / HUNDRED
                );
                token.pool.reserveETH -= (token.pool.reserveETH * token.pool.nativePer) / HUNDRED;
            }
            if (token.pool.nativePer < HUNDRED) {
                _swapEthToBase(funToken, token.baseToken, token.pool.reserveETH);
                _addLiquidity(
                    funToken,
                    IERC20(funToken).balanceOf(address(this)),
                    IERC20(token.baseToken).balanceOf(address(this))
                );
            }
        }
    }

    function changeNativePer(address funToken, uint8 _newNativePer) public {
        require(_isUserFunToken(funToken), "Unauthorized");
        FunTokenPool storage token = tokenPools[funToken];
        require(token.baseToken != getWrapAddr(funToken), "no custom base selected");
        require(_newNativePer >= 0 && _newNativePer <= 100, "invalid per");
        token.pool.nativePer = _newNativePer;
    }

    function _addLiquidityETH(address funToken, uint256 amountTokenDesired, uint256 nativeForDex) internal {
        uint256 amountETH = nativeForDex;
        FunTokenPool storage token = tokenPools[funToken];

        // Get wrapper address for ETH
        address wrapperAddress = getWrapAddr(funToken);

        int24 tickLower = -887272; // Min tick for full range
        int24 tickUpper = 887272; // Max tick for full range

        _approve(funToken, false);
        IERC20(wrapperAddress).approve(address(token.router), amountETH);

        // Prepare parameters for adding liquidity
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: funToken < wrapperAddress ? funToken : wrapperAddress,
            token1: funToken < wrapperAddress ? wrapperAddress : funToken,
            fee: token.poolFee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: funToken < wrapperAddress ? amountTokenDesired : amountETH,
            amount1Desired: funToken < wrapperAddress ? amountETH : amountTokenDesired,
            amount0Min: (funToken < wrapperAddress ? amountTokenDesired : amountETH) * 90 / HUNDRED,
            amount1Min: (funToken < wrapperAddress ? amountETH : amountTokenDesired) * 90 / HUNDRED,
            recipient: address(this),
            deadline: block.timestamp + 300
        });

        // Wrap ETH
        IWETH(wrapperAddress).deposit{value: amountETH}();

        // Add liquidity to V3 pool
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            INonfungiblePositionManager(token.router).mint(params);

        // Store the NFT position ID for later use
        token.lastPositionId = tokenId;

        // Refund any unused ETH
        if (amount0 < amountETH || amount1 < amountETH) {
            uint256 refundAmount = amountETH - (funToken < wrapperAddress ? amount1 : amount0);
            if (refundAmount > 0) {
                IWETH(wrapperAddress).withdraw(refundAmount);
                (bool success,) = msg.sender.call{value: refundAmount}("");
                require(success, "ETH refund failed");
            }
        }
    }

    function _addLiquidity(address funToken, uint256 amountTokenDesired, uint256 baseForDex) internal {
        uint256 amountBase = baseForDex;
        uint256 amountBaseMin = (amountBase * 90) / HUNDRED;
        uint256 amountTokenToAddLiq = amountTokenDesired;
        uint256 amountTokenMin = (amountTokenToAddLiq * 90) / HUNDRED;
        uint256 LP_WETH_exp_balance;
        uint256 LP_token_balance;
        uint256 tokenToSend = 0;

        FunTokenPool storage token = tokenPools[funToken];

        token.storedLPAddress = _getpair(funToken, funToken, token.baseToken);
        address storedLPAddress = token.storedLPAddress;

        LP_WETH_exp_balance = IERC20(token.baseToken).balanceOf(storedLPAddress);
        LP_token_balance = IERC20(funToken).balanceOf(storedLPAddress);

        if (storedLPAddress != address(0x0) && (LP_WETH_exp_balance > 0 && LP_token_balance <= 0)) {
            tokenToSend = (amountTokenToAddLiq * LP_WETH_exp_balance) / amountBase;

            IERC20(funToken).transfer(storedLPAddress, tokenToSend);

            LPToken(storedLPAddress).sync();
            // sync after adding token
        }
        _approve(funToken, false);
        _approve(funToken, true);

        IUniswapV2Router02(token.router).addLiquidity(
            funToken,
            token.baseToken,
            amountTokenToAddLiq - tokenToSend,
            amountBase - LP_WETH_exp_balance,
            amountTokenMin,
            amountBaseMin,
            address(this),
            block.timestamp + (300)
        );
        /*
            _approveLock(storedLPAddress, lpLockDeployer);
            token.lockerAddress = ILpLockDeployerInterface(lpLockDeployer)
                .createLPLocker(
                    storedLPAddress,
                    32503698000,
                    "logo",
                    IERC20(storedLPAddress).balanceOf(address(this)),
                    owner()
                );
                */

        /// TMP implementation for LP FEES

        IERC20(storedLPAddress).transfer(feeContract, IERC20(storedLPAddress).balanceOf(address(this)));

        IFunEventTracker(eventTracker).listEvent(
            msg.sender,
            funToken,
            token.router,
            amountBase - LP_WETH_exp_balance,
            amountTokenToAddLiq - tokenToSend,
            block.timestamp,
            token.pool.volume
        );
        emit listed(
            msg.sender,
            funToken,
            token.router,
            amountBase - LP_WETH_exp_balance,
            amountTokenToAddLiq - tokenToSend,
            block.timestamp,
            token.pool.volume
        );
    }

    function _swapEthToBase(address funToken, address _baseAddress, uint256 _ethIN) internal returns (uint256) {
        _approve(funToken, true);
        // generate the pair path of token -> weth
        uint256[] memory amountMinArr;
        address[] memory path = new address[](2);
        path[0] = getWrapAddr(funToken);
        path[1] = _baseAddress;
        uint256 minBase = (getAmountsMinToken(funToken, _baseAddress, _ethIN) * 90) / HUNDRED;

        amountMinArr = IUniswapV2Router02(tokenPools[funToken].router).swapExactETHForTokens{value: _ethIN}(
            minBase, path, address(this), block.timestamp + 300
        );
        return amountMinArr[1];
    }

    function _approve(address funToken, bool isBaseToken) internal returns (bool) {
        FunTokenPool storage token = tokenPools[funToken];
        IERC20 token_ = IERC20(funToken);
        if (isBaseToken) {
            token_ = IERC20(token.baseToken);
        }

        if (token_.allowance(address(this), token.router) == 0) {
            token_.approve(token.router, type(uint256).max);
        }
        return true;
    }

    function _approveLock(address _lp, address _lockDeployer) internal returns (bool) {
        IERC20 lp_ = IERC20(_lp);
        if (lp_.allowance(address(this), _lockDeployer) == 0) {
            lp_.approve(_lockDeployer, type(uint256).max);
        }
        return true;
    }

    function _getpair(address funToken, address _token1, address _token2) internal returns (address) {
        address router = tokenPools[funToken].router;
        address factory = IUniswapV2Router02(router).factory();
        address pair = IUniswapV2Factory(factory).getPair(_token1, _token2);
        if (pair != address(0)) {
            return pair;
        } else {
            return IUniswapV2Factory(factory).createPair(_token1, _token2);
        }
    }

    function _isUserFunToken(address funToken) internal view returns (bool) {
        for (uint256 i = 0; i < userFunTokens[msg.sender].length;) {
            if (funToken == userFunTokens[msg.sender][i]) {
                return true;
            }
            unchecked {
                i++;
            }
        }
        return false;
    }

    function addDeployer(address _deployer) public onlyOwner {
        allowedDeployers[_deployer] = true;
    }

    function removeDeployer(address _deployer) public onlyOwner {
        allowedDeployers[_deployer] = false;
    }

    function updateImplementation(address _implementation) public onlyOwner {
        require(_implementation != address(0));
        implementation = _implementation;
    }

    function updateFeeContract(address _newFeeContract) public onlyOwner {
        feeContract = _newFeeContract;
    }

    function updateLpLockDeployer(address _newLpLockDeployer) public onlyOwner {
        lpLockDeployer = _newLpLockDeployer;
    }

    function updateEventTracker(address _newEventTracker) public onlyOwner {
        eventTracker = _newEventTracker;
    }

    function updateStableAddress(address _newStableAddress) public onlyOwner {
        stableAddress = _newStableAddress;
    }

    function updateteamFeeper(uint16 _newFeePer) public onlyOwner {
        feePer = _newFeePer;
    }
}
