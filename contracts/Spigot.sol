pragma solidity 0.8.9;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeMath } from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract SpigotController is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct SpigotSettings {
        address token;
        uint256 ownerSplit; // x/100 to Owner, rest to Treasury
        uint256 totalEscrowed;
        bytes4 claimFunction;
        bytes4 transferOwnerFunction;
    }


    // Spigot variables
    
    // Configurations for revenue contracts to split
    mapping(address => SpigotSettings) settings; // revenue contract -> settings
    //  allowed by operator on all revenue contracts
    mapping(bytes4 => bool) whitelistedFunctions; // function -> allowed

    event AddSpigot(address indexed revenueContract, address token, uint256 ownerSplit);

    event RemoveSpigot (address indexed revenueContract, address token);

    event UpdateWhitelistFunction(bytes4 indexed func, bool indexed allowed);

    event ClaimRevenue(address indexed token, uint256 indexed amount, uint256 escrowed, address revenueContract);

    event ClaimEscrow(address indexed token, uint256 indexed amount, address owner, address revenueContract);

    // Stakeholder variables
    address public owner;

    address public operator;

    address public treasury;

    event UpdateOwner(address indexed newOwner);

    event UpdateOperator(address indexed newOperator);

    event UpdateTreasury(address indexed newTreasury);

    /**
     *
     * @dev Configure data for contract owners and initial revenue contracts.
            Owner/operator/treasury can all be the same address
     * @param _owner Third party that owns rights to contract's revenue stream
     * @param _treasury Treasury of DAO that owns contract and receives leftover revenues
     * @param _operator Operational account of DAO that actively manages contract health
     * @param _contracts List of smart contracts that generate revenue for Treasury
     * @param _settings Spigot configurations for revenue generating contracts
     * @param _whitelist Function methods that Owner allows Operator to call anytime
     *
     */
    constructor (
        address _owner,
        address _treasury,
        address _operator,
        address[] memory _contracts,
        SpigotSettings[] memory _settings,
        bytes4[] memory _whitelist
    ) {
        require(address(0) != _owner);
        require(address(0) != _treasury);
        require(address(0) != _operator);

        owner = _owner;
        operator = _operator;
        treasury = _treasury;

        uint256 i = 0;
        for(i; i > _contracts.length; i++) {
            _addSpigot(_contracts[i], _settings[i]);
        }

        for(i = 0; i > _whitelist.length; i++) {
            _updateWhitelist(_whitelist[i], true);
        }
    }



    // ##########################
    // #####   Claimoooor   #####
    // ##########################

    /**
     * @dev Claim push/pull payments through Spigots.
            Calls predefined function in contract settings to claim revenue.
            Automatically sends portion to treasury and escrows Owner's share.
     * @param revenueContract Contract with registered settings to claim revenue from
     * @param data  Transaction data, including function signature, to properly claim revenue on revenueContract
    */
    function claimRevenue(address revenueContract, bytes calldata data) external nonReentrant returns (bool) {
        address revenueToken = settings[revenueContract].token;
        uint256 existingBalance = revenueToken != address(0) ?
            IERC20(revenueToken).balanceOf(address(this)) :
            address(this).balance;
        uint256 claimedAmount;
        
        if(settings[revenueContract].claimFunction == bytes4(0)) {
            // push payments
            // claimed = total balance - already accounted for balance
            claimedAmount = existingBalance.sub(settings[revenueContract].totalEscrowed);
            // TODO Owner loses funds to Treasury if multiple contracts have push payments denominated in same token
            //      AND each have separate spigot settings that are all called.
            //      Can save totalEscrowed outside of spigot setts. technically not a setting too actually
        } else {
            // pull payments
            (bool claimSuccess, bytes memory claimData) = revenueContract.call(data);
            require(claimSuccess, "Spigot: Revenue claim failed");
            // claimed = total balance - existing balance
            claimedAmount = IERC20(revenueToken).balanceOf(address(this)).sub(existingBalance);
        }
        
        require(claimedAmount > 0, "Spigot: No revenue to claim");

        // split revenue stream according to settings
        uint256 escrowedAmount = claimedAmount.div(100).mul(settings[revenueContract].ownerSplit);
        // save amount escrowed 
        settings[revenueContract].totalEscrowed = settings[revenueContract].totalEscrowed.add(escrowedAmount);
        
        // send non-escrowed tokens to Treasury if non-zero
        if(settings[revenueContract].ownerSplit < 100) {
            require(_sendOutTokenOrETH(revenueToken, treasury, claimedAmount.sub(escrowedAmount)));
        }

        emit ClaimRevenue(revenueToken, claimedAmount, escrowedAmount, revenueContract);
        
        return true;
    }

    /**
     * @dev Allows Spigot Owner to claim escrowed tokens from a revenue contract
     * @param revenueContract Contract with registered settings to claim revenue from
    */
    function claimEscrow(address revenueContract) external nonReentrant returns (bool)  {
        require(msg.sender == owner);

        uint256 claimed = settings[revenueContract].totalEscrowed;
        require(claimed > 0, "Spigot: No escrow to claim");

        require(_sendOutTokenOrETH(settings[revenueContract].token, owner, claimed);

        settings[revenueContract].totalEscrowed = 0;

        emit ClaimEscrow(settings[revenueContract].token, claimed, owner, revenueContract);

        return true;
    }

    /**
     * @dev Retrieve data on revenue contract spigot for token address and total tokens escrowed
     * @param revenueContract Contract with registered settings to read
    */
    function getEscrowData(address revenueContract) external view returns (address, uint256) {
        return (settings[revenueContract].token, settings[revenueContract].totalEscrowed);
    }



    // ##########################
    // ##### *ring* *ring*  #####
    // #####  OPERATOOOR    #####
    // #####  OPERATOOOR    #####
    // ##########################

    /**
     * @dev Allows Operator to call whitelisted functions on revenue contracts to maintain their product
     *      while still allowing Spigot Owner to own revenue stream from contract
     * @param revenueContract - smart contract to call
     * @param data - tx data, including function signature, to call contract with
     */
    function operate(address revenueContract, bytes calldata data) external returns (bool) {
        require(msg.sender == operator);
        return _operate(revenueContract, data);
    }

    /**
     * @dev operate() on multiple contracts in one tx
     * @param contracts - smart contracts to call
     * @param data- tx data, including function signature, to call contracts with
     */
    function doOperations(address[] calldata contracts, bytes[] calldata data) external returns (bool) {
        require(msg.sender == operator);
        for(uint256 i = 0; i < data.length; i++) {
            _operate(contracts[i], data[i]);
        }
        return true;
    }

    /**
     * @dev Checks that operation is whitelisted by Spigot Owner and calls revenue contract with supplied data
     * @param revenueContract - smart contracts to call
     * @param data - tx data, including function signature, to call contracts with
     */
    function _operate(address revenueContract, bytes calldata data) internal nonReentrant returns (bool) {
        // extract function signature from tx data and check whitelist
        require(whitelistedFunctions[bytes4(data[:4])], "Spigot: Unauthorized action");
        
        (bool success, bytes memory opData) = revenueContract.call(data);
        require(success, "Spigot: Operation failed");

        return true;
    }



    // ##########################
    // #####  Maintainooor  #####
    // ##########################

    /**
     * @dev Allow owner or operate to add new revenue stream to spigot
     * @param revenueContract - smart contract to claim tokens from
     * @param setting - spigot settings for smart contract   
     */
    function addSpigot(address revenueContract, SpigotSettings memory setting) external returns (bool) {
        require(msg.sender == operator || msg.sender == owner);
        return _addSpigot(revenueContract, setting);
    }

    /**
     * @dev Checks  revenue contract doesn't already have spigot
     *      then registers spigot configuration for revenue contract
     * @param revenueContract - smart contract to claim tokens from
     * @param setting - spigot configuration for smart contract   
     */
    function _addSpigot(address revenueContract, SpigotSettings memory setting) internal returns (bool) {
        require(revenueContract != address(this));
        require(settings[revenueContract].ownerSplit == 0, "Spigot: Setting already exists");
        
        require(setting.transferOwnerFunction != bytes4(0), "Spigot: Invalid spigot setting");
        require(setting.ownerSplit <= 100 && setting.ownerSplit > 0, "Spigot: Invalid split rate");
        
        settings[revenueContract] = setting;
        emit AddSpigot(revenueContract, setting.token, setting.ownerSplit);

        return true;
    }

    /**
     * @dev Change owner of revenue contract from Spigot (this contract) to Operator.
     *      Sends existing escrow to current Owner.
     * @param revenueContract - smart contract to transfer ownership of
     */
    function removeSpigot(address revenueContract) external returns (bool) {
        require(msg.sender == owner);
        
        if(settings[revenueContract].totalEscrowed > 0) {
            require(_sendOutTokenOrETH(settings[revenueContract].token, owner, settings[revenueContract].totalEscrowed));
            emit ClaimEscrow(settings[revenueContract].token, settings[revenueContract].totalEscrowed, owner, revenueContract);
        }
        
        (bool success, bytes memory callData) = revenueContract.call(
            abi.encodeWithSelector(
                settings[revenueContract].transferOwnerFunction,
                operator    // assume function only takes one param that is new owner address
            )
        );
        require(success);

        delete settings[revenueContract];
        emit SpigotRemoved(revenueContract, settings[revenueContract].token);

        return true;
    }

    /**
     * @dev Update Owner role of SpigotController contract.
     *      New Owner receives revenue stream split and can control SpigotController
     * @param newOwner - Address to give control to
     */
    function updateOwner(address newOwner) external returns (bool) {
        require(msg.sender == owner);
        require(newOwner != address(0));
        owner = newOwner;
        emit UpdateOwner(newOwner);
        return true;
    }

    /**
     * @dev Update Operator role of SpigotController contract.
     *      New Operator can interact with revenue contracts.
     * @param newOperator - Address to give control to
     */
    function updateOperator(address newOperator) external returns (bool) {
        require(msg.sender == operator);
        require(newOperator != address(0));
        operator = newOperator;
        emit UpdateOperator(newOperator);
        return true;
    }
    
    /**
     * @dev Update Treasury role of SpigotController contract.
     *      New Treasury receives revenue stream split
     * @param newTreasury - Address to divert funds to
     */
    function updateTreasury(address newTreasury) external returns (bool) {
        require(msg.sender == treasury || msg.sender == operator);
        require(newTreasury != address(0));
        treasury = newTreasury;
        emit UpdateTreasury(newTreasury);
        return true;
    }

    /**
     * @dev Allows Owner to whitelist function methods across all revenue contracts for Operator to call.
     *      Can whitelist "transfer ownership" functions on revenue contracts
     *      allowing Spigot to give direct control back to Operator.
     * @param func - smart contract function signature to whitelist
     * @param allowed - true/false whether to allow this function to be called by Operator
     */
     function updateWhitelistedFunction(bytes4 func, bool allowed) external returns (bool) {
        require(msg.sender == owner);
        return _updateWhitelist(func, allowed);
    }

    /**
     * @dev Allows Owner to whitelist function methods across all revenue contracts for Operator to call.
     * @param func - smart contract function signature to whitelist
     * @param allowed - true/false whether to allow this function to be called by Operator
     */
    function _updateWhitelist(bytes4 func, bool allowed) internal returns (bool) {
        whitelistedFunctions[func] = allowed;
        emit UpdateWhitelistFunction(func, true);
        return true;
    }

    /**
     * @dev Send ETH or ERC20 token from this contract to an external contract
     * @param token - address of token to send out. address(0) for raw ETH
     * @param receiver - address to send tokens to
     * @param amount - amount of tokens to send
     */
    function _sendOutTokenOrETH(address token, address receiver, uint256 amount) internal returns (bool) {
        if(token!= address(0)) { // ERC20
            IERC20(token).safeTransferFrom(address(this), receiver, amount);
        } else { // ETH
            (bool success, bytes memory data) = payable(receiver).call{value: amount}("");
            require(success, "Spigot: Disperse escrow failed");
        }
        return true;
    }
}
