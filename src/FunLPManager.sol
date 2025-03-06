// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import {INonfungiblePositionManager} from "@v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

//velodrom
import {IRouter} from "@velodrome/interfaces/IRouter.sol";
//velodrom
import {IPoolFactory} from "@velodrome/interfaces/factories/IPoolFactory.sol";
// velodrom
import {IPool} from "@velodrome/interfaces/IPool.sol";

import {IFunStorageInterface} from "./interfaces/IFunStorageInterface.sol";

// החוזה מאפשר לנהל את הפוזיציות של ה-LP, לאסוף עמלות (fees) מהן ולחלק את העמלות בין המפתחים ובעל החוזה, תוך שמירה על ניהול מותאם לפוזיציות מסוג ERC721 (NFTs). 
//בנוסף, החוזה מספק את האפשרות לשנות את שיעור העמלה וכולל גם אפשרות למשיכה חירומית של NFTs.
contract FunLPManager is Ownable, IERC721Receiver {

    struct LPPosition {
        address dev;
        uint256 tokenACollected;
        uint256 tokenBCollected;
    }

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public feePer;

    address public positionManager = 0x1C5A295E9860d127D8A3E7af138Bb945c4377ae7;

    address public funPool;

    mapping(uint256 => LPPosition) public tokenIdToLPPosition;
    mapping(address => uint256[])  public devToTokenIds;

    event PositionDeposited(
        uint256 tokenId, 
        address dev, 
        uint256 timestamp
    );

    event FeesCollected(
        uint256 tokenId, 
        address dev,
        address token,
        uint256 amount,
        uint256 timestamp
    );

    constructor(
        address _funPool,
        uint256 _feePer
    ) Ownable(msg.sender) {
        funPool = _funPool;
        feePer = _feePer;
    }

    // מאפשר להפקיד פוזיציה חדשה של NFT.
    // רק ה-funPool מורשה לקרוא לפונקציה זו
    function depositNFTPosition(uint256 _tokenId, address _dev) external {
        require(msg.sender == funPool, "LPManager: Only FunPool can call this function");

        IERC721(positionManager).transferFrom(funPool, address(this), _tokenId);

        LPPosition memory lpPosition = LPPosition({
            dev: _dev,
            tokenACollected: 0,
            tokenBCollected: 0
        });

        tokenIdToLPPosition[_tokenId] = lpPosition;
        devToTokenIds[_dev].push(_tokenId);

        emit PositionDeposited(_tokenId, _dev, block.timestamp);
    }

    // איסוף עמלות
    // מאשרת שרק המפתח (dev) או בעל החוזה (owner) יכולים לאסוף את העמלות.
    // משיכה של העמלות נעשית עבור שני סוגי המטבעות (אם יש) והשארת אחוז העמלה עבור בעל החוזה.
    function collectFees(uint256 _tokenId) external {

        LPPosition storage lpPosition = tokenIdToLPPosition[_tokenId];

        require(IERC721(positionManager).ownerOf(_tokenId) == address(this), "LPManager: LP Token not owned by LPManager"); // בודק האם שייך למנהל של החוזה הנוכחי
        require((msg.sender == lpPosition.dev) || (msg.sender == owner()), "LPManager: Only Dev or Owner can collect fees"); // בודקת אם מי שמבצע את הפעולה מפתח או בעל החוזה

    //איסוף העמלות
    // המשתנים amountB ו-amountA מייצגים את הכמויות של שני סוגי הטוקנים שמתקבלים בעת איסוף העמלות מתוך הפוזיציה הבלתי ניתנת להחלפה (LP Position).
    // amountA: מייצג את כמות הטוקן הראשון שנאסף. זה יכול להיות, למשל, ERC-20 טוקן כמו USDC, ETH, או כל טוקן אחר שמוזן לפוזיציה.
    //amountB: מייצג את כמות הטוקן השני שנאסף, שיכול להיות טוקן אחר (למשל, DAI, WBTC או כל טוקן אחר במערכת).

        // (uint256 amountA, uint256 amountB) = INonfungiblePositionManager(positionManager).collect(INonfungiblePositionManager.CollectParams({
        //     tokenId: _tokenId,
        //     recipient: address(this),
        //     tokenAMax: type(uint128).max,
        //     tokenBMax: type(uint128).max
        // }));


        // כתובת ה-token0 ואת כתובת ה-token1, 
        //שהם שני הטוקנים שהעמדה אוחזת בהם. את כתובות אלה ניתן להשתמש כדי להבין אילו נכסים נמצאים בעמדה הזו.
        // (,,address tokenA, address tokenB,,,,,,,,) = INonfungiblePositionManager(positionManager).positions(_tokenId);

        // tokenA ו-tokenB מייצגים את כמות הטוקנים שנאספו לכל אחד מהטוקנים 
        (uint256 amountA, uint256 amountB) = IPool(positionManager).claimFees();
        (address tokenA, address tokenB) = IPool(positionManager).tokens();

        // איסוף הסכומים (עם collect).
        // חישוב העמלות והעברתן (מה שנעשה בקוד שלך אחרי ה-collect).

        // קודם את אוסף הסכומים, ורק לאחר מכן את החישוב של העמלות והעברות היתרות, כך שאין פה חפיפות.
        // כלומר, הסכומים שמשתמשים בהם לעמלות הם אלו שנאספו קודם, ולא מתבצע חישוב נוסף על סכומים אחרים.

        // יש safeTransfer ב collect של UniswapV3Pool.sol
        // ההעברה אינה מתבצעת פעמיים על אותם הסכומים – קודם מתבצע האיסוף של המטבעות באמצעות collect,
        // ולאחר מכן העברות העמלות והיתרות לכל הגורמים הרלוונטיים.
        // בעצם כספים מועברים לבעלים, מפתחים - או כל מי שקשור לפוזיציה, ולמי שם את הנזילות - מפעיל הפונקציה
        // סה"כ 3 גורמים? 
        if (amountA > 0) {
            uint256 feeAmountA = (amountA * feePer) / BASIS_POINTS;
            IERC20(tokenA).transfer(owner(), feeAmountA); // מעביר את סכום העמלה  לכתובת של ה-owner של החוזה. 
            IERC20(tokenA).transfer(lpPosition.dev, amountA - feeAmountA); // מעביר את יתרת הסכום לאחר ניכוי העמלה למפתח או מישהו הקשור לפוזיציה
            // פוזיציה - כמות אחזקות בנכסים פיננסיים

            emit FeesCollected(_tokenId, lpPosition.dev, tokenA, amountA, block.timestamp);
        }

        if (amountB > 0) {
            uint256 feeAmountB = (amountB * feePer) / BASIS_POINTS;
            IERC20(tokenB).transfer(owner(), feeAmountB);
            IERC20(tokenB).transfer(lpPosition.dev, amountB - feeAmountB);

            emit FeesCollected(_tokenId, lpPosition.dev, tokenB, amountB, block.timestamp);
        }
    }

    // פונקציה לקבלת NFT (onERC721Received)
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    //  הגדרת שיעור העמלה
    function setFeePer(uint256 _feePer) external onlyOwner {
        require(_feePer > 0, "LPManager: Fee Per must be greater than 0");
        feePer = _feePer;
    }

    // משיכת NFT במצב חירום
    function emergencyWithdrawERC721(address _token, uint256 _tokenId) external onlyOwner {
        IERC721(_token).transferFrom(address(this), owner(), _tokenId);
    }
}