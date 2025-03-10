// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {FunDeployer} from "../src/FunDeployer.sol";
import {FunEventTracker} from "../src/FunEventTracker.sol";
import {FunPool} from "../src/FunPool.sol";
import {FunStorage} from "../src/Storage.sol";
import {SimpleERC20} from "../src/SimpleERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FunLPManager} from "../src/FunLPManager.sol";


contract FunTest is Test {
    FunDeployer deployer;
    FunEventTracker eventTracker;
    FunPool pool;
    FunStorage funStorage;
    SimpleERC20 implementation;
    FunLPManager lpManager;

    address owner;
    address treasury;
    address user1;
    address user2;

    function setUp() public {
        // uint256 forkId = vm.createFork("https://rpc.mainnet.taraxa.io");
        uint256 forkId = vm.createFork("https://1rpc.io/op");
        vm.selectFork(forkId);

        owner = vm.addr(1);
        treasury = vm.addr(2);
        user1 = vm.addr(3);
        user2 = vm.addr(4);

        vm.deal(owner, 1000000000 ether);
        vm.deal(user1, 1000000000 ether);
        vm.deal(user2, 1000000000 ether);

        vm.startPrank(owner);

        implementation = new SimpleERC20();
        funStorage = new FunStorage();
        eventTracker = new FunEventTracker(address(funStorage));
        

        pool = new FunPool(
            address(implementation), 
            address(treasury), 
            address(eventTracker)
        );

        deployer = new FunDeployer(address(pool), address(treasury), address(funStorage), address(eventTracker));

        lpManager = new FunLPManager(address(pool), 1000);

        pool.addDeployer(address(deployer));
        pool.setLPManager(address(lpManager));
        funStorage.addDeployer(address(deployer));
        eventTracker.addDeployer(address(deployer));
        eventTracker.addDeployer(address(pool));
    }

    function test_t() public {
        console.log("Hellow");
    }

    function test_createToken() public {
        // שולח איטריום לפונקציה עם הקריאה לה - לדוגמא אם יש עלות ליצירת הטוקן
        // הפונקציה מוגדרת כ payable ולכן אפשר לשלוח עם הקריאה לה כסף
        deployer.createFun{value: 10000000}(
            "Test", 
            "TT", 
            "Test Token", 
            1000000000 ether,
            0, 
            0,
            0
        );

        FunStorage.FunDetails memory funTokenDetail = funStorage.getFunContract(0);
                                                                                
        uint256 amountOut = pool.getAmountOutTokens(funTokenDetail.funAddress, 300 ether);

        // - שווי הטוקן עכשוי
        console.log("trade Active?", pool.getFuntokenPool(funTokenDetail.funAddress).pool.tradeActive);
        console.log("CurrentCap:", pool.getCurrentCap(funTokenDetail.funAddress));
        // pool.buyTokens{value : 500 ether}(funTokenDetail.funAddress, amountOut, address(0x0));
       
        uint256 listThresholdCap = pool.getListThresholdCap(funTokenDetail.funAddress);
        while (pool.getCurrentCap(funTokenDetail.funAddress) < listThresholdCap) {
        pool.buyTokens{value : 1000 ether}(funTokenDetail.funAddress, 0, address(0x0));
        console.log("Updated Market Cap:", pool.getCurrentCap(funTokenDetail.funAddress));
        }
        // pool.buyTokens{value : 500 ether}(funTokenDetail.funAddress, amountOut, address(0x0));

        // לקבל שווי שוק כמה הטוקן שווה
        // pool.getCurrentCap(funTokenDetail.funAddress);

        // שווי שוק = 10000
        // - שווי הטוקן עכשיו
        console.log("CurrentCap: ", pool.getCurrentCap(funTokenDetail.funAddress));

        uint currentCap = pool.getCurrentCap(funTokenDetail.funAddress);
        assertTrue(currentCap >= 500, "500 is more small.");

        // - שווי הטוקן כשהוא עולה לבורסה - הוספה
        console.log("MarketCap:", pool.getListThresholdCap(funTokenDetail.funAddress));
    
        console.log("trade Active?", pool.getFuntokenPool(funTokenDetail.funAddress).pool.tradeActive);
        
    }

    // function test_t() public {
    //     console.log("Hellow");
    // }
}
