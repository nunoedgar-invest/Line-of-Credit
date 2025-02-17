pragma solidity 0.8.9;

import { ReentrancyGuard } from "openzeppelin/security/ReentrancyGuard.sol";
import {LineLib} from "../utils/LineLib.sol";
import {ISpigot} from "../interfaces/ISpigot.sol";

struct SpigotState {
    address owner;
    address operator;
    address treasury;
    // Total amount of revenue tokens escrowed by the Spigot and available to be claimed
    mapping(address => uint256) escrowed; // token  -> amount escrowed
    // Functions that the operator is allowed to run on all revenue contracts controlled by the Spigot
    mapping(bytes4 => bool) whitelistedFunctions; // function -> allowed
    // Configurations for revenue contracts related to the split of revenue, access control to claiming revenue tokens and transfer of Spigot ownership
    mapping(address => ISpigot.Setting) settings; // revenue contract -> settings
}


library SpigotLib {
    // Maximum numerator for Setting.ownerSplit param to ensure that the Owner can't claim more than 100% of revenue
    uint8 constant MAX_SPLIT = 100;
    // cap revenue per claim to avoid overflows on multiplication when calculating percentages
    uint256 constant MAX_REVENUE = type(uint256).max / MAX_SPLIT;

    function _claimRevenue(SpigotState storage self, address revenueContract, address token, bytes calldata data)
        public
        returns (uint256 claimed)
    {
        uint256 existingBalance = LineLib.getBalance(token);
        if(self.settings[revenueContract].claimFunction == bytes4(0)) {
            // push payments
            // claimed = total balance - already accounted for balance
            claimed = existingBalance - self.escrowed[token];
        } else {
            // pull payments
            if(bytes4(data) != self.settings[revenueContract].claimFunction) { revert BadFunction(); }
            (bool claimSuccess,) = revenueContract.call(data);
            if(!claimSuccess) { revert ClaimFailed(); }
            // claimed = total balance - existing balance
            claimed = LineLib.getBalance(token) - existingBalance;
        }

        if(claimed == 0) { revert NoRevenue(); }

        // cap so uint doesnt overflow in split calculations.
        // can sweep by "attaching" a push payment spigot with same token
        if(claimed > MAX_REVENUE) claimed = MAX_REVENUE;

        return claimed;
    }

    function operate(SpigotState storage self, address revenueContract, bytes calldata data) external returns (bool) {
        if(msg.sender != self.operator) { revert CallerAccessDenied(); }
        bytes4 func = bytes4(data);
        // extract function signature from tx data and check whitelist
        if(!self.whitelistedFunctions[func]) { revert BadFunction(); }
        // cant claim revenue via operate() because that fucks up accounting logic. Owner shouldn't whitelist it anyway but just in case
        if(
          func == self.settings[revenueContract].claimFunction ||
          func == self.settings[revenueContract].transferOwnerFunction
        ) { revert BadFunction(); }

        (bool success,) = revenueContract.call(data);
        if(!success) { revert BadFunction(); }

        return true;
    }

    function claimRevenue(SpigotState storage self, address revenueContract, address token, bytes calldata data)
        external
        returns (uint256 claimed)
    {
        claimed = _claimRevenue(self, revenueContract, token, data);

        // splits revenue stream according to Spigot settings
        uint256 escrowedAmount = claimed * self.settings[revenueContract].ownerSplit / 100;
        // update escrowed balance
        self.escrowed[token] = self.escrowed[token] + escrowedAmount;
        
        // send non-escrowed tokens to Treasury if non-zero
        if(claimed > escrowedAmount) {
            require(LineLib.sendOutTokenOrETH(token, self.treasury, claimed - escrowedAmount));
        }

        emit ClaimRevenue(token, claimed, escrowedAmount, revenueContract);
        
        return claimed;
    }
     // Transfers revenue tokens from escrow to a the Spigot Owner (effectively this is LineOf Credit, representing Lenders.
     function claimEscrow(SpigotState storage self, address token)
        external
        returns (uint256 claimed) 
    {
        if(msg.sender != self.owner) { revert CallerAccessDenied(); }
        
        claimed = self.escrowed[token];

        if(claimed == 0) { revert ClaimFailed(); }

        LineLib.sendOutTokenOrETH(token, self.owner, claimed);

        self.escrowed[token] = 0; // keep 1 in escrow for recurring call gas optimizations?

        emit ClaimEscrow(token, claimed, self.owner);

        return claimed;
    }

    function addSpigot(SpigotState storage self, address revenueContract, ISpigot.Setting memory setting) external returns (bool) {
        if(msg.sender != self.owner) { revert CallerAccessDenied(); }

        require(revenueContract != address(this));
        // spigot setting already exists
        require(self.settings[revenueContract].transferOwnerFunction == bytes4(0));
        
        // must set transfer func
        if(setting.transferOwnerFunction == bytes4(0)) { revert BadSetting(); }
        if(setting.ownerSplit > MAX_SPLIT) { revert BadSetting(); }
        
        self.settings[revenueContract] = setting;
        emit AddSpigot(revenueContract, setting.ownerSplit);

        return true;
    }

    function removeSpigot(SpigotState storage self, address revenueContract)
        external
        returns (bool)
    {
        if(msg.sender != self.owner) { revert CallerAccessDenied(); }

        (bool success,) = revenueContract.call(
            abi.encodeWithSelector(
                self.settings[revenueContract].transferOwnerFunction,
                self.operator    // assume function only takes one param that is new owner address
            )
        );
        require(success);

        delete self.settings[revenueContract];
        emit RemoveSpigot(revenueContract);

        return true;
    }

    function updateOwnerSplit(SpigotState storage self, address revenueContract, uint8 ownerSplit)
        external
        returns(bool)
    {
      if(msg.sender != self.owner) { revert CallerAccessDenied(); }
      if(ownerSplit > MAX_SPLIT) { revert BadSetting(); }

      self.settings[revenueContract].ownerSplit = ownerSplit;
      emit UpdateOwnerSplit(revenueContract, ownerSplit);
      
      return true;
    }

    function updateOwner(SpigotState storage self, address newOwner) external returns (bool) {
        if(msg.sender != self.owner) { revert CallerAccessDenied(); }
        require(newOwner != address(0));
        self.owner = newOwner;
        emit UpdateOwner(newOwner);
        return true;
    }

    function updateOperator(SpigotState storage self, address newOperator) external returns (bool) {
        if(msg.sender != self.operator) { revert CallerAccessDenied(); }
        require(newOperator != address(0));
        self.operator = newOperator;
        emit UpdateOperator(newOperator);
        return true;
    }

    function updateTreasury(SpigotState storage self, address newTreasury) external returns (bool) {
        if(msg.sender != self.operator && msg.sender != self.treasury) {
          revert CallerAccessDenied();
        }

        require(newTreasury != address(0));
        self.treasury = newTreasury;
        emit UpdateTreasury(newTreasury);
        return true;
    }

    /**
    A function of the Spigot, called by updateWhitelist() in SpigotedLine which is only callable by the Arbiter.
    Allows the Owner (the Line) to tell the Spigot to whitelist what the Operator is allowed to do on its revenue contracts
    so that the Operator can still use the contracts whilst they are providing revenue tokens to repay credit. 
   (remember Operator = Borrower)
    */
    function updateWhitelistedFunction(SpigotState storage self, bytes4 func, bool allowed) external returns (bool) {
        if(msg.sender != self.owner) { revert CallerAccessDenied(); }
        self.whitelistedFunctions[func] = allowed;
        emit UpdateWhitelistFunction(func, allowed);
        return true;
    }
    // Returns the amount of revenue tokens in escrow ready to be withdrawn
    function getEscrowed(SpigotState storage self, address token) external view returns (uint256) {
        return self.escrowed[token];
    }

    // Returns the list of whitelisted functions that a Borrower [Operator] is allowed to perform 
    // on the revenue generating smart contracts whilst the Spigot is attached.
    function isWhitelisted(SpigotState storage self, bytes4 func) external view returns(bool) {
      return self.whitelistedFunctions[func];
    }

 
    function getSetting(SpigotState storage self, address revenueContract)
        external view
        returns(uint8, bytes4, bytes4)
    {
        return (
            self.settings[revenueContract].ownerSplit,
            self.settings[revenueContract].claimFunction,
            self.settings[revenueContract].transferOwnerFunction
        );
    }


    // Spigot Events

    event AddSpigot(
        address indexed revenueContract,
        uint256 ownerSplit
    );

    event RemoveSpigot(address indexed revenueContract);

    event UpdateWhitelistFunction(bytes4 indexed func, bool indexed allowed);

    event UpdateOwnerSplit(
        address indexed revenueContract,
        uint8 indexed split
    );

    event ClaimRevenue(
        address indexed token,
        uint256 indexed amount,
        uint256 escrowed,
        address revenueContract
    );

    event ClaimEscrow(
        address indexed token,
        uint256 indexed amount,
        address owner
    );

    // Stakeholder Events

    event UpdateOwner(address indexed newOwner);

    event UpdateOperator(address indexed newOperator);

    event UpdateTreasury(address indexed newTreasury);

    // Errors
    error BadFunction();

    error ClaimFailed();

    error NoRevenue();

    error UnclaimedRevenue();

    error CallerAccessDenied();

    error BadSetting();
}
