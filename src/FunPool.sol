// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Clones} from "./libraries/Clones.sol";
import {IFunDeployer} from "./interfaces/IFunDeployer.sol";
import {IFunEventTracker} from "./interfaces/IFunEventTracker.sol";
import {IFunLPManager} from "./interfaces/IFunLPManager.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IFunToken} from "./interfaces/IFunToken.sol";
import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol";

// velodrome-finance
import {IRouter} from "@velodrome/interfaces/IRouter.sol";
// velodrome-finance
import {IPoolFactory} from "@velodrome/interfaces/factories/IPoolFactory.sol";

// import {INonfungiblePositionManager} from "@v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
// import {IUniswapV3Factory} from "@v3-core/contracts/interfaces/IUniswapV3Factory.sol";
// import {IUniswapV3Pool} from "@v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {console} from "forge-std/console.sol";
contract FunPool is Ownable, ReentrancyGuard {
    using FixedPointMathLib for uint256;

    struct FunTokenPoolData {
        uint256 reserveTokens;
        uint256 reserveTARA;
        uint256 volume;
        uint256 listThreshold;
        uint256 initialReserveTARA;
        uint256 maxBuyPerWallet;
        bool tradeActive;
        bool royalemitted;
    }

    struct FunTokenPool {
        address creator; // כתובת היוצר של הבריכה
        address token;  // כתובת הטוקן המסוים
        address baseToken; // המטבע הבסיסי (לדוגמה, USDT, ETH וכו')
        address router; // כתובת ה-Router למסחר (כגון Uniswap)
        address lockerAddress; // כתובת החוזה לנעילת נזילות
        address storedLPAddress; // כתובת LP (נזילות)
        address deployer; // כתובת היוצר שהפעיל את הבריכה
        FunTokenPoolData pool;
    }

    //  ערך סטנדרטי למדידת עמלות (10000 = 100%).
    uint256 public constant BASIS_POINTS = 10000;
    // כתובות לחוזים על Uniswap או פלטפורמה דומה
    // uint24  public uniswapPoolFee = 10000;

    address public wtara           = 0x5d0Fa4C5668E5809c83c95A7CeF3a9dd7C68d4fE; // כתובת הטוקן שמנהל את החוזים והטוקנים?
    address public stable          = 0x69D411CbF6dBaD54Bfe36f81d0a39922625bC78c; // כתובת של מטבע יציב?
    // החוזה הזה אחראי על יצירת בריכות נזילות בין אסימונים שונים ומנהל את תהליך יצירתם.
    address public factory         = 0x5EFAc029721023DD6859AFc8300d536a2d6d4c82; // חוזה יצירת בריכות נזילות
    address public router          = 0x705d6bcc8aF1732C9Cb480347aF8F62Cbfa3C671; // אחראי על תכנון הנתיב הטוב ביותר להמיר בין אסימונים
    address public positionManager = 0x1C5A295E9860d127D8A3E7af138Bb945c4377ae7; // אחראי על ניהול הפוזיציות (כמו אוסף אסימונים או הימורים במערכת כלשהי) של המשתמשים.
    address public oracle          = 0xe03e2C41c8c044192b3CE2d7AFe49370551c7f80; // חוזה שמספק נתוני שוק/מחיר

    address public implementation;
    address public feeContract;// חוזה שאחראי על גביית עמלות
    address public LPManager; // מנהל נזילות של הבריכה
    address public eventTracker; // חוזה שעוקב אחרי אירועים ועסקאות.
 

    // deployer allowed to create fun tokens
    mapping(address => bool) public allowedDeployers; // מי רשאי להפעיל בריכות נזילות
    // user => array of fun tokens
    mapping(address => address[]) public userFunTokens; // משתמשים וכתובות של הטוקנים שיצרו
    // fun token => fun token details
    mapping(address => FunTokenPool) public tokenPools; // שמירת מידע על כל בריכה לפי כתובת הטוקן.
    /// represents the tick spacing for each fee tier
    mapping(uint24 => int256) public tickSpacing; //  אין שימוש בחוזה זה

    
    // לבדוק אם הבריכה קבועה
    bool public stable1 = true;

    // נפלט כאשר מוסיפים נזילות לבריכה.
    event LiquidityAdded(address indexed provider, uint256 tokenAmount, uint256 taraAmount);

    // נפלט כאשר טוקן נרשם למסחר
    event listed(
        address indexed tokenAddress,
        address indexed router,
        address indexed pair, // הצמדה לטוקן / מטבע
        uint256 liquidityAmount,
        uint256 tokenAmount,
        uint256 time,
        uint256 totalVolume
    );

    // נועד לתעד עסקאות שמתבצעות בפלטפורמה
    event tradeCall(
        address indexed caller, // הכתובת של מבצע העסקה
        address indexed funContract, // הכתובת של החוזה שדרכו בוצעה העסקה
        uint256 inAmount, // כמות הטוקנים שהוזנו לעסקה
        uint256 outAmount, //כמות הטוקנים שהתקבלה
        uint256 reserveTARA, // תרת המטבע TARA במאגר הנזילות
        uint256 reserveTokens, // יתרת הטוקנים הזמינים במאגר
        uint256 timestamp, //  חותמת זמן של העסקה
        string tradeType //  סוג העסקה (למשל "buy" או "sell")
    );

    constructor(
        address _implementation,
        address _feeContract,
        address _eventTracker
    ) Ownable(msg.sender) {

        implementation = _implementation; // כתובת של חוזה המימוש
        feeContract    = _feeContract; // כתובת חוזה העמלות
        eventTracker   = _eventTracker; // כתובת חוזה המעקב אחר האירועים
    }

    function initFun(
        string[2] memory _name_symbol,
        uint256 _totalSupply,
        address _creator,
        uint256[2] memory listThreshold_initReserveTARA,
        uint256 _maxBuyPerWallet
    ) public payable returns (address) {
        require(allowedDeployers[msg.sender], "not deployer");

        address funToken = Clones.clone(implementation); // יצירת חוזה טוקן חדש
        IFunToken(funToken).initialize(_totalSupply, _name_symbol[0], _name_symbol[1], address(this), msg.sender);

        // add tokens to the tokens user list
        userFunTokens[_creator].push(funToken);

        // create the pool data
        FunTokenPool memory pool;

        pool.creator = _creator;
        pool.token = funToken;
        pool.baseToken = wtara;
        pool.router = router;
        pool.deployer = msg.sender;

        pool.pool.tradeActive = true;
        pool.pool.reserveTokens += _totalSupply;
        pool.pool.reserveTARA += (listThreshold_initReserveTARA[1] + msg.value);
        pool.pool.listThreshold = listThreshold_initReserveTARA[0];
        pool.pool.initialReserveTARA = listThreshold_initReserveTARA[1];
        pool.pool.maxBuyPerWallet = _maxBuyPerWallet;

        // add the fun data for the fun token
        tokenPools[funToken] = pool;

        emit LiquidityAdded(address(this), _totalSupply, msg.value);

        return address(funToken); 
    }

    // Calculate amount of output tokens based on input TARA
    //מחשבת כמה טוקנים מהמאגר המשתמש יקבל כאשר הוא מזרים כמות מסוימת של TARA.
    function getAmountOutTokens(address _funToken, uint256 _amountIn) public view returns (uint256 amountOut) {
        require(_amountIn > 0, "Invalid input amount");
        FunTokenPool storage token = tokenPools[_funToken];
        require(token.pool.reserveTokens > 0 && token.pool.reserveTARA > 0, "Invalid reserves");

        uint256 numerator = _amountIn * token.pool.reserveTokens;
        uint256 denominator = (token.pool.reserveTARA) + _amountIn;
        amountOut = numerator / denominator;
    }

    // Calculate amount of output TARA based on input tokens
    //  מחשבת כמה TARA המשתמש יקבל כאשר הוא מזרים כמות מסוימת של טוקנים
    function getAmountOutTARA(address _funToken, uint256 _amountIn) public view returns (uint256 amountOut) {
        require(_amountIn > 0, "Invalid input amount");
        FunTokenPool storage token = tokenPools[_funToken];
        require(token.pool.reserveTokens > 0 && token.pool.reserveTARA > 0, "Invalid reserves");

        uint256 numerator = _amountIn * token.pool.reserveTARA;
        uint256 denominator = (token.pool.reserveTokens) + _amountIn;
        amountOut = numerator / denominator;
    }

    function getBaseToken(address _funToken) public view returns (address) {
        FunTokenPool storage token = tokenPools[_funToken];
        return address(token.baseToken);
    }


    function getCurrentCap(address _funToken) public view returns (uint256) {
        FunTokenPool storage token = tokenPools[_funToken];

        // latestPrice() is in 1e8 format
        uint256 latestPrice = uint(IChainlinkAggregator(oracle).latestAnswer() / 1e2);

        uint256 amountMinToken = FixedPointMathLib.mulWadDown(token.pool.reserveTARA, latestPrice);

        return (amountMinToken * IERC20(_funToken).totalSupply()) / token.pool.reserveTokens;
    }

    function getFuntokenPool(address _funToken) public view returns (FunTokenPool memory) {
        return tokenPools[_funToken];
    }

    // שמשתמשת במערך של כתובות טוקנים (המיוצגות על ידי _funTokens), ומחזירה את המאגרים (FunTokenPool) עבור כל אחד מהטוקנים.
    function getFuntokenPools(address[] memory _funTokens) public view returns (FunTokenPool[] memory) {
        uint256 length = _funTokens.length;
        FunTokenPool[] memory pools = new FunTokenPool[](length);
        for (uint256 i = 0; i < length;) {
            pools[i] = tokenPools[_funTokens[i]];
            unchecked {
                i++;
            }
        }
        return pools;
    }

// מקבל תכתובת משתמש ומחזיר מערך של כל הטוקנים של הכתובת שלו
    function getUserFuntokens(address _user) public view returns (address[] memory) {
        return userFunTokens[_user];
    }

    // לבדוק אם משתמש יכול לקנות כמות מסוימת של FUN Token מבלי לעבור את הגבול המקסימלי שנקבע עבורו במאגר הנזילות.
    function checkMaxBuyPerWallet(address _funToken, uint256 _amount) public view returns (bool) {
        FunTokenPool memory token = tokenPools[_funToken];
        uint256 userBalance = IERC20(_funToken).balanceOf(msg.sender);
        return userBalance + _amount <= token.pool.maxBuyPerWallet;
    }

    // מכירת טוקנים וקבלת TARA וחישוב העמלות הכרוחות בכך
    function sellTokens(address _funToken, uint256 _tokenAmount, uint256 _minEth, address _affiliate)
        public
        nonReentrant // בדיקה שלא קוראים לפונקציה זו יותר מפעם אחת בטרנזקציה
    {
        FunTokenPool storage token = tokenPools[_funToken];
        require(token.pool.tradeActive, "Trading not active");
    
        //כמות טוקנים שמוכרים
        uint256 tokenToSell = _tokenAmount;
        // מחשב כמה TARA מקבלים על הטוקנים שרוצים למכור
        uint256 taraAmount = getAmountOutTARA(_funToken, tokenToSell);
        // חישוב העמלה על הטרנזקציה
        uint256 taraAmountFee = (taraAmount * IFunDeployer(token.deployer).getTradingFeePer()) / BASIS_POINTS;
        // מחשבת את העמלה שתינתן ל OWNER
        uint256 taraAmountOwnerFee = (taraAmountFee * IFunDeployer(token.deployer).getDevFeePer()) / BASIS_POINTS;
        uint256 affiliateFee =
            (taraAmountFee * (IFunDeployer(token.deployer).getAffiliatePer(_affiliate))) / BASIS_POINTS;
        require(taraAmount > 0 && taraAmount >= _minEth, "Slippage too high");

        token.pool.reserveTokens += _tokenAmount;
        token.pool.reserveTARA -= taraAmount;
        token.pool.volume += taraAmount;

        IERC20(_funToken).transferFrom(msg.sender, address(this), tokenToSell);
        (bool success,) = feeContract.call{value: taraAmountFee - taraAmountOwnerFee - affiliateFee}("");
        require(success, "fee TARA transfer failed");

        (success,) = _affiliate.call{value: affiliateFee}(""); 
        require(success, "aff TARA transfer failed");

        (success,) = payable(owner()).call{value: taraAmountOwnerFee}(""); 
        require(success, "ownr TARA transfer failed");

        (success,) = msg.sender.call{value: taraAmount - taraAmountFee}("");
        require(success, "seller TARA transfer failed");

        emit tradeCall(
            msg.sender,
            _funToken,
            tokenToSell,
            taraAmount,
            token.pool.reserveTARA,
            token.pool.reserveTokens,
            block.timestamp,
            "sell"
        );

        IFunEventTracker(eventTracker).sellEvent(msg.sender, _funToken, tokenToSell, taraAmount);
    }

    // קניית טוקנים
    // בדיקה שהפונקציה הקראית פעם אחת באותה טרנזקציה
    // אם שווי שוק של הטוקנים הגיע לסכום שסוכם מראש שיעבור לבורסה , מעבירים את המסחר לבורסה ומהתחלים את כל המשתנים ובירכת הנזילות והמסחר הופל בה ללא פעיל
    function buyTokens(address _funToken, uint256 _minTokens, address _affiliate) public payable nonReentrant {
        require(msg.value > 0, "Invalid buy value");
        FunTokenPool storage token = tokenPools[_funToken];
        require(token.pool.tradeActive, "Trading not active");

        uint256 taraAmount = msg.value;
        uint256 taraAmountFee = (taraAmount * IFunDeployer(token.deployer).getTradingFeePer()) / BASIS_POINTS;
        uint256 taraAmountOwnerFee = (taraAmountFee * (IFunDeployer(token.deployer).getDevFeePer())) / BASIS_POINTS;
        uint256 affiliateFee = (taraAmountFee * (IFunDeployer(token.deployer).getAffiliatePer(_affiliate))) / BASIS_POINTS;

        uint256 tokenAmount = getAmountOutTokens(_funToken, taraAmount - taraAmountFee);
        require(tokenAmount >= _minTokens, "Slippage too high");
        require(checkMaxBuyPerWallet(_funToken, tokenAmount), "Max buy per wallet exceeded");

        token.pool.reserveTARA += (taraAmount - taraAmountFee);
        token.pool.reserveTokens -= tokenAmount;
        token.pool.volume += taraAmount;

        (bool success,) = feeContract.call{value: taraAmountFee - taraAmountOwnerFee - affiliateFee}("");
        require(success, "fee TARA transfer failed");

        (success,) = _affiliate.call{value: affiliateFee}("");
        require(success, "fee TARA transfer failed");

        (success,) = payable(owner()).call{value: taraAmountOwnerFee}(""); 
        require(success, "fee TARA transfer failed");

        IERC20(_funToken).transfer(msg.sender, tokenAmount);

        emit tradeCall(
            msg.sender,
            _funToken,
            taraAmount,
            tokenAmount,
            token.pool.reserveTARA,
            token.pool.reserveTokens,
            block.timestamp,
            "buy"
        );
        
        IFunEventTracker(eventTracker).buyEvent(
            msg.sender, 
            _funToken, 
            msg.value, 
            tokenAmount
        );

        uint256 currentMarketCap = getCurrentCap(_funToken);

        uint256 listThresholdCap = token.pool.listThreshold * (10 ** IERC20Metadata(stable).decimals());

        /// royal emit when marketcap is half of listThresholdCap
        if (currentMarketCap >= (listThresholdCap / 2) && !token.pool.royalemitted) {
            IFunDeployer(token.deployer).emitRoyal(
                _funToken, token.pool.reserveTARA, token.pool.reserveTokens, block.timestamp, token.pool.volume
            );
            token.pool.royalemitted = true;
        }
        // using marketcap value of token to check when to add liquidity to DEX
        if (currentMarketCap >= listThresholdCap) {
            token.pool.tradeActive = false;
            IFunToken(_funToken).initiateDex();
            token.pool.reserveTARA -= token.pool.initialReserveTARA;

            _addLiquidityVelodrome(_funToken, IERC20(_funToken).balanceOf(address(this)), token.pool.reserveTARA);

            uint256 reserveTARA = token.pool.reserveTARA;
            token.pool.reserveTARA = 0;

            emit listed(
                token.token,
                token.router,
                token.storedLPAddress,
                reserveTARA,
                token.pool.reserveTokens,
                block.timestamp,
                token.pool.volume
            );
        }
    }

    // מבצעת הוספת נזילות (liquidity) לפלטפורמת velodrom עבור טוקן מסוג _funToken ו-WETH
    function _addLiquidityVelodrome(address _funToken, uint256 _amountTokenDesired, uint256 _nativeForDex) internal {
        FunTokenPool storage token = tokenPools[_funToken];

        // נקבע אילו שני טוקנים ייכנסו לבריכת הנזילות
        //כתובות מהקטן לגדול - בדיקה של גודל כתובות החוזים כדי להתאים לתקן של יוניסוואפ
        // גם בולדרום
        address tokenA = _funToken; // = _funToken < wtara ? _funToken : wtara;
        address tokenB = wtara; // _funToken < wtara ? wtara : _funToken;

        // console.log("token0: %s", tokenA);
        // console.log("token1: %s", tokenB);

        uint256 price_numerator;
        uint256 price_denominator;

        // if (tokenA == wtara) {
        //     price_numerator = _amountTokenDesired;
        //     price_denominator = _nativeForDex;
        // } else {
        //     price_numerator = _nativeForDex;
        //     price_denominator = _amountTokenDesired;
        // }

        // console.log("price_numerator: %s", price_numerator);
        // console.log("price_denominator: %s", price_denominator);

    // יצירת ואיתחול בריכת נזילות אם לא קיימת
        // if (token.storedLPAddress == address(0)) {
        //     // INonfungiblePositionManager(positionManager).createAndInitializePoolIfNecessary(
        //     //     token0, token1, uniswapPoolFee, encodePriceSqrtX96(price_numerator, price_denominator)
        //     // );
        //     IPoolFactory(positionManager).createPool(token0, token1, Fee?);
        //     token.storedLPAddress = IPoolFactory(factory).getPool(token0, token1, fee?);
        //     require(token.storedLPAddress != address(0), "Pool creation failed");
        // }

        // אישור המטבעות
        // IWETH(wtara).deposit{value: _nativeForDex}();

         IERC20(wtara).approve(positionManager, _nativeForDex);
         IERC20(_funToken).approve(positionManager, _amountTokenDesired);

        // // תחום זה קובע את המחיר שיחול על המיקום המינתי בבריכה ב-Uniswap V3.
        // // קובע את טווח הנזילות המקסימלי ביוניסוואפ
        // int24 tickLower = -887200;
        // int24 tickUpper = 887200;

        // כמות הטוקנים שצריך להפקיד בכל צד של הבריכה, תלוי באיזה טוקן הוא token0 ו-token1.
        uint256 amountADesired = (tokenA == _funToken ? _amountTokenDesired : _nativeForDex);
        uint256 amountBDesired = (tokenA == _funToken ? _nativeForDex : _amountTokenDesired);

        // הגדרת מינימום שמותר להפקיד בכל צד של הבריכה. במקרה זה, 98% מהסכום שצוין יתקבל.
        // המשתמש לא יפסיד יותר מ2 אחוז מהערך הצפוי - אם תוך כדי העיסקה הערך ירד ביותר משתי אחוז העיסקה לא תתבצע
        uint256 amountAMin = (amountADesired * 98) / 100;
        uint256 amountBMin = (amountBDesired * 98) / 100;

        IRouter(positionManager).addLiquidity(tokenA, tokenB, stable1, amountADesired, amountBDesired, amountAMin, amountBMin, address(this), block.timestamp + 1);
        // מוגדרים כל הפרמטרים שדורשים יצירה של מיקום בבריכה ב-Uniswap, כולל כמות הטוקנים, fees, ה-ticks, ועוד.
        // INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
        //     token0: token0,
        //     token1: token1,
        //     fee: uniswapPoolFee,
        //     tickLower: tickLower,
        //     tickUpper: tickUpper,
        //     amount0Desired : amount0Desired,
        //     amount1Desired : amount1Desired,
        //     amount0Min : amount0Min,
        //     amount1Min : amount1Min,
        //     recipient: address(this),
        //     deadline: block.timestamp + 1 // מה זה בדיוק?
        // });

    // המערכת מבצעת את פעולת ה-Mint, כלומר יוצרת את ה-NFT שמייצג את המיקום בבריכהד
        // (uint256 tokenId,,,) = INonfungiblePositionManager(positionManager).mint(params);
    // אישור ה-NFT
        // IERC721(positionManager).approve(LPManager, tokenId);
    // הפקדה של ה-NFT שנוצר עבור המיקום בבריכה אל LPManager.
        // IFunLPManager(LPManager).depositNFTPosition(tokenId, msg.sender);
     }

    // המטרה היא לחשב ולהחזיר את שורש המחיר ברמה של דיוק גבוהה
    // חישוב של שורש ריבועי של המחיר
    function encodePriceSqrtX96(uint256 price_numerator, uint256 price_denominator) internal pure returns (uint160) {
        require(price_denominator > 0, "Invalid price denominator");
    // חילוק מונה במכנה
        uint256 sqrtPrice = sqrt(price_numerator.divWadDown(price_denominator));
    //הדפסת התוצאה
        console.log("sqrtPrice: %s", sqrtPrice);
        
        // Q64.96 fixed-point number divided by 1e9 for underflow prevention
        return uint160((sqrtPrice * 2**96) / 1e9);
    }


    // חישוב שורש ריבועי של מספר
    // פונקציה עזר לחישוב השורש הריבועי של מספר y
    // Helper function to calculate square root
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
     // פונקציה זו מוסיפה כתובת (_deployer) לרשימה של "deployer" שמורשים לפעול על החוזה. 
    function addDeployer(address _deployer) public onlyOwner {
        allowedDeployers[_deployer] = true;
    }

    // פונקציה זו מסירה כתובת (_deployer) מהרשימה של "deployer" המורשים.
    function removeDeployer(address _deployer) public onlyOwner {
        allowedDeployers[_deployer] = false;
    }

    // קובעת את כתובת החוזה של היישום החדש
    function setImplementation(address _implementation) public onlyOwner {
        require(_implementation != address(0), "Invalid implementation");
        implementation = _implementation;
    }
     // קובעת את כתובת החוזה של חוזה העמלות
    function setFeeContract(address _newFeeContract) public onlyOwner {
        require(_newFeeContract != address(0), "Invalid fee contract");
        feeContract = _newFeeContract;
    }
     // קובעת את כתובת מנהל ה LP
    function setLPManager(address _newLPManager) public onlyOwner {
        require(_newLPManager != address(0), "Invalid LP lock deployer");
        LPManager = _newLPManager;
    }

    // קובעת את כתובת המעקב אחרי אירועים
    function setEventTracker(address _newEventTracker) public onlyOwner {
        require(_newEventTracker != address(0), "Invalid event tracker");
        eventTracker = _newEventTracker;
    }

    // קובעת את כתובת המטבע היציב
    function setStableAddress(address _newStableAddress) public onlyOwner {
        require(_newStableAddress != address(0), "Invalid stable address");
        stable = _newStableAddress;
    }

    function setWTARA(address _newwtara) public onlyOwner {
        require(_newwtara != address(0), "Invalid wtara");
        wtara = _newwtara;
    }

    function setFactory(address _newFactory) public onlyOwner {
        require(_newFactory != address(0), "Invalid factory");
        factory = _newFactory;
    }

    function setRouter(address _newRouter) public onlyOwner {
        require(_newRouter != address(0), "Invalid router");
        router = _newRouter;
    }

    function setPositionManager(address _newPositionManager) public onlyOwner {
        require(_newPositionManager != address(0), "Invalid position manager");
        positionManager = _newPositionManager;
    }

    // // קובעת את כתובת מנהל המיקומים 
    // function setUniswapPoolFee(uint24 _newuniswapPoolFee) public onlyOwner {
    //     require(_newuniswapPoolFee > 0, "Invalid pool fee");
    //     uniswapPoolFee = _newuniswapPoolFee;
    // }

    // מאפשרת לבעלים של החוזה למשוך טוקנים (ERC-20) מתוך החוזה במקרה חירום. 
    // זה לא משיחת שטיח?
    function emergencyWithdrawToken(address _token, uint256 _amount) public onlyOwner {
        IERC20(_token).transfer(owner(), _amount);
    }

    // מאפשרת לבעלים של החוזה למשוך Ether או TARA  מתוך החוזה במקרה חירום.
    // הפונקציה משתמשת בפקודת call .
    //כדי לשלוח את האיטריום לבעלים של החוזה ותוך כדי מבצעת בדיקת הצלחה על מנת לוודא שההעברה בוצעה כראוי.
    function emergencyWithdrawTARA(uint256 _amount) public onlyOwner {
        (bool success,) = payable(owner()).call{value: _amount}("");
        require(success, "TARA transfer failed");
    }

    // מאפשרת לקבל איטריום 
    receive() external payable { }
}