// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FunStorage is Ownable {

    //מאחסן נתונים על הטוקנים שנוצרו
    struct FunDetails {
        address funAddress; // כתובת החוזה החכם שמנהל את הטוקן
        address tokenAddress; // כתובת החוזה החכם של האסימון
        address funOwner; // כתובת היוצר של ה-Fun
        string name; // שם האסימון
        string symbol; // סימול האסימון (למשל "ETH")
        string data; // מידע על הטוקן
        uint256 totalSupply; // כמות הטוקנים שהונפקו
        uint256 initialLiquidity; // סכום נזילות ראשוני שהוקצה לטוקן (למשל, כמה ETH או TARA הופקדו בנזילות)
        uint256 createdOn; // חותמת זמן מתי הטוקן נוצר
    }

    //funDetails מערך מסוג אוביקט  
    FunDetails[] public funContracts;
    
    uint256 public funCount;

    mapping(address => bool) public deployer;
    mapping(address => uint256) public funContractToIndex;
    mapping(address => uint256) public tokenContractToIndex;
    mapping(address => uint256) public ownerToFunCount;
    mapping(address => mapping(uint256 => uint256)) public ownerIndexToStorageIndex;
    mapping(address => address) public funContractToOwner;
    mapping(address => uint256) public funContractToOwnerCount;

    constructor() Ownable(msg.sender) {}

    //מקבלת נתונים של חוזה של טוקן ובודקת תקינות ומעדכנת ושומרת
    function addFunContract(
        address _funOwner,
        address _funAddress,
        address _tokenAddress,
        string memory _name,
        string memory _symbol,
        string memory _data,
        uint256 _totalSupply,
        uint256 _initialLiquidity
    ) external {

        require(deployer[msg.sender], "not deployer");

        FunDetails memory newFun = FunDetails({
            funAddress: _funAddress,
            tokenAddress: _tokenAddress,
            funOwner: _funOwner,
            name: _name,
            symbol: _symbol,
            data: _data,
            totalSupply: _totalSupply,
            initialLiquidity: _initialLiquidity,
            createdOn: block.timestamp
        });

        funContracts.push(newFun);
        funContractToIndex[_funAddress] = funContracts.length - 1;
        tokenContractToIndex[_tokenAddress] = funContracts.length - 1;
        funContractToOwner[_funAddress] = _funOwner;
        funContractToOwnerCount[_funAddress] = ownerToFunCount[_funOwner]; 
        ownerIndexToStorageIndex[_funOwner][ownerToFunCount[_funOwner]] = funCount;
        ownerToFunCount[_funOwner]++;
        funCount++;
    }

    //מקבל אינדקס ומחזיר את הכתובת של החוזה
    function getFunContract(
        uint256 index
    ) public view returns (FunDetails memory) {
        return funContracts[index];
    }

    //מקבל כתובת ומחזיר את האינדקס
    function getFunContractIndex(
        address _funContract
    ) public view returns (uint256) {
        return funContractToIndex[_funContract];
    }

     // מחזיר את כמות הטוקנים שהופנקו דרך המערכת
    function getTotalContracts() public view returns (uint) {
        return funContracts.length;
    }

    // מקבל כתובת טוקן ומחזיר את הבעלים שלה
    function getFunContractOwner(
        address _funContract
    ) public view returns (address) {
        return funContractToOwner[_funContract];
    }

    // מקבל כתובת ומוסיף שותף שיכול לפרוס את החוזה 
    function addDeployer(address _deployer) public onlyOwner {
        require(!deployer[_deployer], "already added");
        deployer[_deployer] = true;
    }

    //מוחק כתובת 
    function removeDeployer(address _deployer) public onlyOwner {
        require(deployer[_deployer], "not deployer");
        deployer[_deployer] = false;
    }

    // מאפשר לבעל החוזה למשוך את יתרת החוזה במקרה חרום 
    function emergencyWithdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        payable(owner()).transfer(balance);
    }
}