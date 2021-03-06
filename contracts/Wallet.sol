//sol Wallet
// Multi-sig, daily-limited account proxy/wallet.
// @authors:
// Gav Wood <g@ethdev.com>
// inheritable "property" contract that enables methods to be protected by requiring the acquiescence of either a
// single, or, crucially, each of a number of, designated owners.
// usage:
// use modifiers onlyowner (just own owned) or onlymanyowners(hash), whereby the same hash must be provided by
// some number (specified in constructor) of the set of owners (specified in the constructor, modifiable) before the
// interior is executed.

import "./Token.sol";
import "./SecureMath.sol";
pragma solidity ^0.4.11;

/*
The standard Wallet contract, retrievable at
https://github.com/ethereum/dapp-bin/blob/master/wallet/wallet.sol has been
modified to include additional functionality, in particular:
* An additional parent of wallet contract called tokenswap, implementing almost
all the changes:
    - Functions for starting and stopping the tokenswap
    - A set-only-once function for the token contract
    - buyTokens(), which calls mintTokens() in the token contract
    - Modifiers for enforcing tokenswap time limits, max ether cap, and max token cap
    - withdrawEther(), for withdrawing unsold tokens after time cap
* the wallet fallback function calls the buyTokens function
* the wallet contract cannot selfdestruct during the tokenswap
*/

contract multiowned {

	// TYPES

    // struct for the status of a pending operation.
    struct PendingState {
        uint yetNeeded;
        uint ownersDone;
        uint index;
    }

	//
    // this contract only has six types of events: it can accept a confirmation, in which case
    // we record owner and operation (hash) alongside it.
    event Confirmation(address owner, bytes32 operation);
    event Revoke(address owner, bytes32 operation);
    // some others are in the case of an owner changing.
    event OwnerChanged(address oldOwner, address newOwner);
    event OwnerAdded(address newOwner);
    event OwnerRemoved(address oldOwner);
    // the last one is emitted if the required signatures change
    event RequirementChanged(uint newRequirement);

	// MODIFIERS

    // simple single-sig function modifier.
    modifier onlyowner {
        require (isOwner(msg.sender));
            _;
    }

    // to check if the recipient is owner
    modifier onlyWhiteListed(address _addr) {
        require (isOwner(_addr));
            _;
    }

    // multi-sig function modifier: the operation must have an intrinsic hash in order
    // that later attempts can be realised as the same underlying operation and
    // thus count as confirmations.
    modifier onlymanyowners(bytes32 _operation) {
        if (confirmAndCheck(_operation))
            _;
    }

	// METHODS

    // constructor is given number of sigs required to do protected "onlymanyowners" transactions
    // as well as the selection of addresses capable of confirming them.
    function multiowned(address[] _owners, uint _required) {
        m_numOwners = _owners.length + 1;
        m_owners[1] = uint(msg.sender);
        m_ownerIndex[uint(msg.sender)] = 1;
        for (uint i = 0; i < _owners.length; ++i)
        {
            m_owners[2 + i] = uint(_owners[i]);
            m_ownerIndex[uint(_owners[i])] = 2 + i;
        }
        m_required = _required;
    }

    // Revokes a prior confirmation of the given operation
    function revoke(bytes32 _operation) external {
        uint ownerIndex = m_ownerIndex[uint(msg.sender)];
        // make sure they're an owner
        if (ownerIndex == 0) return;
        uint ownerIndexBit = 2**ownerIndex;
        var pending = m_pending[_operation];
        if (pending.ownersDone & ownerIndexBit > 0) {
            pending.yetNeeded++;
            pending.ownersDone -= ownerIndexBit;
            Revoke(msg.sender, _operation);
        }
    }

    // Replaces an owner `_from` with another `_to`.
    function changeOwner(address _from, address _to) onlymanyowners(sha3(msg.data)) external {
        if (isOwner(_to)) return;
        uint ownerIndex = m_ownerIndex[uint(_from)];
        if (ownerIndex == 0) return;

        clearPending();
        m_owners[ownerIndex] = uint(_to);
        m_ownerIndex[uint(_from)] = 0;
        m_ownerIndex[uint(_to)] = ownerIndex;
        OwnerChanged(_from, _to);
    }

    function addOwner(address _owner) onlymanyowners(sha3(msg.data)) external {
        if (isOwner(_owner)) return;

        clearPending();
        if (m_numOwners >= c_maxOwners)
            reorganizeOwners();
        if (m_numOwners >= c_maxOwners)
            return;
        m_numOwners++;
        m_owners[m_numOwners] = uint(_owner);
        m_ownerIndex[uint(_owner)] = m_numOwners;
        OwnerAdded(_owner);
    }

    function removeOwner(address _owner) onlymanyowners(sha3(msg.data)) external {
        uint ownerIndex = m_ownerIndex[uint(_owner)];
        if (ownerIndex == 0) return;
        if (m_required > m_numOwners - 1) return;

        m_owners[ownerIndex] = 0;
        m_ownerIndex[uint(_owner)] = 0;
        clearPending();
        reorganizeOwners(); //make sure m_numOwner is equal to the number of owners and always points to the optimal free slot
        OwnerRemoved(_owner);
    }

    function changeRequirement(uint _newRequired) onlymanyowners(sha3(msg.data)) external {
        if (_newRequired > m_numOwners) return;
        m_required = _newRequired;
        clearPending();
        RequirementChanged(_newRequired);
    }

    // Gets an owner by 0-indexed position (using numOwners as the count)
    function getOwner(uint ownerIndex) external constant returns (address) {
        return address(m_owners[ownerIndex + 1]);
    }

    function isOwner(address _addr) returns (bool) {
        return m_ownerIndex[uint(_addr)] > 0;
    }

    function hasConfirmed(bytes32 _operation, address _owner) constant returns (bool) {
        var pending = m_pending[_operation];
        uint ownerIndex = m_ownerIndex[uint(_owner)];

        // make sure they're an owner
        if (ownerIndex == 0) return false;

        // determine the bit to set for this owner.
        uint ownerIndexBit = 2**ownerIndex;
        return !(pending.ownersDone & ownerIndexBit == 0);
    }

    // INTERNAL METHODS

    function confirmAndCheck(bytes32 _operation) internal returns (bool) {
        // determine what index the present sender is:
        uint ownerIndex = m_ownerIndex[uint(msg.sender)];
        // make sure they're an owner
        if (ownerIndex == 0) return;

        var pending = m_pending[_operation];
        // if we're not yet working on this operation, switch over and reset the confirmation status.
        if (pending.yetNeeded == 0) {
            // reset count of confirmations needed.
            pending.yetNeeded = m_required;
            // reset which owners have confirmed (none) - set our bitmap to 0.
            pending.ownersDone = 0;
            pending.index = m_pendingIndex.length++;
            m_pendingIndex[pending.index] = _operation;
        }
        // determine the bit to set for this owner.
        uint ownerIndexBit = 2**ownerIndex;
        // make sure we (the message sender) haven't confirmed this operation previously.
        if (pending.ownersDone & ownerIndexBit == 0) {
            Confirmation(msg.sender, _operation);
            // ok - check if count is enough to go ahead.
            if (pending.yetNeeded <= 1) {
                // enough confirmations: reset and run interior.
                delete m_pendingIndex[m_pending[_operation].index];
                delete m_pending[_operation];
                return true;
            }
            else
            {
                // not enough: record that this owner in particular confirmed.
                pending.yetNeeded--;
                pending.ownersDone |= ownerIndexBit;
            }
        }
    }

    function reorganizeOwners() private {
        uint free = 1;
        while (free < m_numOwners)
        {
            while (free < m_numOwners && m_owners[free] != 0) free++;
            while (m_numOwners > 1 && m_owners[m_numOwners] == 0) m_numOwners--;
            if (free < m_numOwners && m_owners[m_numOwners] != 0 && m_owners[free] == 0)
            {
                m_owners[free] = m_owners[m_numOwners];
                m_ownerIndex[m_owners[free]] = free;
                m_owners[m_numOwners] = 0;
            }
        }
    }

    function clearPending() internal {
        uint length = m_pendingIndex.length;
        for (uint i = 0; i < length; ++i)
            if (m_pendingIndex[i] != 0)
                delete m_pending[m_pendingIndex[i]];
        delete m_pendingIndex;
    }

   	// FIELDS

    // the number of owners that must confirm the same operation before it is run.
    uint public m_required;
    // pointer used to find a free slot in m_owners
    uint public m_numOwners;

    // list of owners
    uint[256] m_owners;
    uint constant c_maxOwners = 250;
    // index on the list of owners to allow reverse lookup
    mapping(uint => uint) m_ownerIndex;
    // the ongoing operations.
    mapping(bytes32 => PendingState) m_pending;
    bytes32[] m_pendingIndex;
}

// inheritable "property" contract that enables methods to be protected by placing a linear limit (specifiable)
// on a particular resource per calendar day. is multiowned to allow the limit to be altered. resource that method
// uses is specified in the modifier.
contract daylimit is multiowned {

	// MODIFIERS

    // simple modifier for daily limit.
    modifier limitedDaily(uint _value) {
        if (underLimit(_value))
            _;
    }

	// METHODS

    // constructor - stores initial daily limit and records the present day's index.
    function daylimit(uint _limit) {
        m_dailyLimit = _limit;
        m_lastDay = today();
    }
    // (re)sets the daily limit. needs many of the owners to confirm. doesn't alter the amount already spent today.
    function setDailyLimit(uint _newLimit) onlymanyowners(sha3(msg.data)) external {
        m_dailyLimit = _newLimit;
    }
    // resets the amount already spent today. needs many of the owners to confirm.
    function resetSpentToday() onlymanyowners(sha3(msg.data)) external {
        m_spentToday = 0;
    }

    // INTERNAL METHODS

    // checks to see if there is at least `_value` left from the daily limit today. if there is, subtracts it and
    // returns true. otherwise just returns false. For test purposes, the daily limit is not set.
    function underLimit(uint _value) internal onlyowner returns (bool) {
        // reset the spend limit if we're on a different day to last time.
        return true;
    }
    // determines today's index.
    function today() internal constant returns (uint) { return now / 1 days; }

	// FIELDS

    uint public m_dailyLimit;
    uint public m_spentToday;
    uint public m_lastDay;
}

// interface contract for multisig proxy contracts; see below for docs.
contract multisig {

	// EVENTS

    // logged events:
    // Funds has arrived into the wallet (record how much).
    event Deposit(address _from, uint value);
    // Single transaction going out of the wallet (record who signed for it, how much, and to whom it's going).
    event SingleTransact(address owner, uint value, address to, bytes data);
    // Multi-sig transaction going out of the wallet (record who signed for it last, the operation hash, how much, and to whom it's going).
    event MultiTransact(address owner, bytes32 operation, uint value, address to, bytes data);
    // Confirmation still needed for a transaction.
    event ConfirmationNeeded(bytes32 operation, address initiator, uint value, address to, bytes data);

    // FUNCTIONS

    // TODO: document
    function changeOwner(address _from, address _to) external;
    function execute(address _to, uint _value, bytes _data) internal returns (bytes32);
    function confirm(bytes32 _h) returns (bool);
}

contract tokenswap is secureMath, multisig, multiowned {

    Token public tokenCtr;
    bool public tokenSwap;
    uint public constant PRESALE_LENGTH = 3 days;
    uint public constant SWAP_LENGTH = PRESALE_LENGTH + 6 weeks + 6 days + 3 hours;
    uint public constant MAX_ETH = 75000 ether; // Hard cap, capped otherwise by total tokens sold (max 7.5M FYN)
    uint public amountRaised;

    // array to store the addresses of the depositors.
    uint[] depositorAccounts;

    // boolean to store the status of the refund process,
    // in control of the owners of the contract.
    bool public refundInitiated;

    // to store token buyer status. Stores if the buyer has
    // bought tokens before as true or false.
    mapping (uint => bool) existingDepositor;

    // to store the addresses of beneficiaries corresponding to
    // each depositor
    mapping (uint => uint[]) beneficiaries;

    // to store if the beneficiary corresponding to a depositor
    // already exists.
    mapping (uint => mapping(uint => bool)) existingBeneficiary;

    // to store the amount corresponding to each beneficiary, corresponding
    // to each depositor.
    mapping (uint => mapping(uint => uint)) etherAmountDeposited;

    // to store the refund status each each beneficiary corresponding
    // to the depositor
    mapping (uint => mapping(uint => bool)) refundReceived;

    // to check if the refund process has started,
    // i.e after the owner initiates the refund process.
    modifier refundProcessStarted {
        require (refundInitiated);
        _;
    }

    // to check if the refund process has not started,
    // i.e before the owner initiates the refund process.
    modifier refundProcessNotStarted {
        require (!refundInitiated);
        _;
    }

    // to check if the Beneficiary that the depositor claims refund for
    // is a Beneficiary.
    modifier isBeneficiary (address _addr) {
        require (existingBeneficiary[uint(msg.sender)][uint(_addr)]);
        _;
    }

    // to check if the user making the refund request is a depositor.
    modifier isDepositor {
        require (existingDepositor[uint(msg.sender)]);
        _;
    }

    // to check the refund has already been claimed for the particular beneficiary
    // by the depositor.
    modifier refundNotClaimed (address _addr) {
        require (!refundReceived[uint(msg.sender)][uint(_addr)]);
        _;
    }

    modifier isUnderPresaleMinimum {
        if (tokenCtr.creationTime() + PRESALE_LENGTH > now) {
            require (msg.value >= 20 ether);
        }
        _;
    }

    modifier isZeroValue {
        require (msg.value != 0);
        _;
    }

    modifier isOverCap {
    	require (amountRaised + msg.value <= MAX_ETH);
        _;
    }

    modifier isOverTokenCap {
        require (safeToMultiply(tokenCtr.currentSwapRate(), msg.value));
        uint tokensAmount = tokenCtr.currentSwapRate() * msg.value;
        require (safeToAdd(tokenCtr.totalSupply(),tokensAmount));
        require (tokenCtr.totalSupply() + tokensAmount <= tokenCtr.tokenCap());
        _;
    }

    modifier isSwapStopped {
        require (tokenSwap);
        _;
    }

    modifier areConditionsSatisfied {
        _;
        // End token swap if sale period ended
        // We can't throw to reverse the amount sent in or we will lose state
        // , so we will accept it even though if it is after crowdsale
        if (tokenCtr.creationTime() + SWAP_LENGTH < now) {
            tokenCtr.disableTokenSwapLock();
            tokenSwap = false;
        }
        // Check if cap has been reached in this tx
        if (amountRaised == MAX_ETH) {
            tokenCtr.disableTokenSwapLock();
            tokenSwap = false;
        }

        // Check if token cap has been reach in this tx
        if (tokenCtr.totalSupply() == tokenCtr.tokenCap()) {
            tokenCtr.disableTokenSwapLock();
            tokenSwap = false;
        }
    }

    function startTokenSwap() onlyowner {
        tokenSwap = true;
    }

    function stopTokenSwap() onlyowner {
        tokenSwap = false;
    }

    function setTokenContract(address newTokenContractAddr) onlyowner {
        require (newTokenContractAddr != address(0x0));
        // Allow setting only once
        require (tokenCtr == address(0x0));
        tokenCtr = Token(newTokenContractAddr);
    }

    // to record the transaction for the buyTokens function.
    // Stores the ether amount deposited correspoding to each depositor, correspoding
    // to a particular beneficiary.
    function recordDepositor (address _addr, uint _value) internal {

      if (existingDepositor[uint(msg.sender)]) {
        if (existingBeneficiary[uint(msg.sender)][uint(_addr)]) {
          etherAmountDeposited[uint(msg.sender)][uint(_addr)] += _value;
        }

        else {
            beneficiaries[uint(msg.sender)].push(uint(_addr));
            existingBeneficiary[uint(msg.sender)][uint(_addr)] = true;
            etherAmountDeposited[uint(msg.sender)][uint(_addr)] += _value;

        }
      }
      else {
            depositorAccounts.push(uint(msg.sender));
            beneficiaries[uint(msg.sender)].push(uint(_addr));
            existingDepositor[uint(msg.sender)] = true;
            existingBeneficiary[uint(msg.sender)][uint(_addr)] = true;
            etherAmountDeposited[uint(msg.sender)][uint(_addr)] += _value;
        }
    }


    function buyTokens(address _beneficiary)
    payable
    isUnderPresaleMinimum
    isZeroValue
    isOverCap
    isOverTokenCap
    isSwapStopped
    areConditionsSatisfied {

        Deposit(msg.sender, msg.value);
        tokenCtr.mintTokens(_beneficiary, msg.value);
        require (safeToAdd(amountRaised, msg.value));
        amountRaised += msg.value;
        recordDepositor (_beneficiary, msg.value); //records the deposit.
    }


    function withdrawReserve(address _beneficiary) onlyowner {
	    if (tokenCtr.creationTime() + SWAP_LENGTH < now) {
            tokenCtr.mintReserve(_beneficiary);
        }
    }
}


contract amountWithdrawalStrategy is secureMath, daylimit, tokenswap {

    uint[256] fynAccounts;
    mapping (uint => uint) fynAccountIndex;
    uint totalMilestones;

    // MileStone structure to remember details of the milestone strategy.
    struct MileStone {
        uint date;
        uint percentage;
    }

    // To store Milestone information.
    mapping (uint => MileStone) milestoneStorage;

    // Variable to store total withdrawal till date.
    uint public withdrawnTillToday;

    // Variable to store percentage immediately withdrawable.
    uint public immediateQuantum;

    // Boolean to store if a withdrawal has been made.
    bool public withdrawalStatus;

    //to check if the withdrawal is under the milestone limit
    modifier isUnderMilestoneLimit (uint _amount) {
        require (mileStoneChecker(_amount));
        _;
    }

    //modifier to check FYN accounts
    modifier onlyFYN (address accountToCheck) {
        require (isFYN(accountToCheck));
        _;
    }

    // to check if the dates being entered are in chronological
    // order. Calls checkDateOrder to verify.
    modifier onlyCorrectDateOrder (uint[] _datesToCheck) {
        require (checkDateOrder (_datesToCheck));
        _;
    }

    // to check if the sum of all the percentages being entered
    // adds up to 100. Calls Percentage Check to verfiy.
    modifier percentageSumComplete (uint[] _percentagesToCheck) {
        require (percentageCheck (_percentagesToCheck));
        _;
    }

    modifier withdrawalNotMade () {
      require (!withdrawalStatus);
      _;
    }

    // to get the FYN account corresponding an index,according to zero indexing.
    function getFynAccount (uint fynAccountIndex) external constant returns (address) {
        return address(fynAccounts[fynAccountIndex]);
    }

    // for use in modifier onlyFYN.
    function isFYN (address _addr) internal returns (bool) {
        return fynAccountIndex[uint(_addr)] >= 0;
    }

    // for use in modifier onlyCorrectDateOrder
    function checkDateOrder (uint[] _datesToCheck) internal returns (bool) {
        for (uint i = 0; i < _datesToCheck.length-1; i++) {
            if(_datesToCheck[i] > _datesToCheck[i+1]) {
                return false;
            }
        }
        return true;
    }

    //for use in modifier percentageSumComplete
    function percentageCheck (uint[] _percentagesToCheck) internal returns (bool) {
        uint sum;
        for (uint i = 0; i < _percentagesToCheck.length; i++) {
        require (_percentagesToCheck[i] > 0);
        sum += _percentagesToCheck[i];
        }
        if(sum == 100) {
            return true;
        }
        return false;
    }


    // constructor to initialize the FYN accounts, milestone dates and corresponding
    // percentages. Dates must be entered in chronological order. Percentages
    // must add upto 100 for successful initialization.
    function amountWithdrawalStrategy (address[] _FYN, uint[] _dates, uint[] _percentage ) internal
    onlyCorrectDateOrder(_dates)
    percentageSumComplete(_percentage) {

        require (_dates.length + 1 == _percentage.length);
        uint i = 0;
        for (i; i < _FYN.length; i++ ) {
            fynAccounts [i] = uint(_FYN[i]);
            fynAccountIndex[uint(_FYN[i])] = i;
        }

        immediateQuantum = _percentage[0];

        i = 0;
        for(i; i < _dates.length; i++) {
            milestoneStorage[i].date = _dates[i];
            milestoneStorage[i].percentage = _percentage[i+1];
        }
        totalMilestones = i+1;
    }

    // to record the transaction after each successful withdrawal.
    function recordTransaction (uint _amount) internal {
      withdrawnTillToday += _amount;
      withdrawalStatus = true;
    }

    // to check if the amount being withdrawn follows the
    // milestone strategy. For use in modifier isUnderMilestoneLimit.
    function mileStoneChecker (uint _amount) internal returns (bool) {

        if(_amount == 0 ) return false;
        uint sumPercentage = immediateQuantum;

        uint i;
        for (i = 0; i < totalMilestones; i++) {
          if(today() < milestoneStorage[i].date) {

            return (withdrawnTillToday + _amount <= (sumPercentage * amountRaised/100) && safeToAdd(withdrawnTillToday,_amount));
          }

          else {
            sumPercentage += milestoneStorage[i].percentage;
          }
        }

        return (withdrawnTillToday + _amount <= amountRaised && safeToAdd(withdrawnTillToday,_amount));
    }
}

// usage:
// bytes32 h = Wallet(w).from(oneOwner).transact(to, value, data);
// Wallet(w).from(anotherOwner).confirm(h);
contract Wallet is secureMath, multisig, multiowned, daylimit, tokenswap, amountWithdrawalStrategy {

	// TYPES

    // Transaction structure to remember details of transaction lest it need be saved for a later call.
    struct Transaction {
        address to;
        uint value;
        bytes data;
    }

    // METHODS

    // constructor - just pass on the owner array to the multiowned and
    // the limit to daylimit
    // the FYN addresses, the milestone dates in the correct order, and the percentage breakup
    // ex- there are 3 milestones. There will be 4 percentage breakups, immediate withdrawal percentage,
    // and percentages corresponding to the milstones. If the dates in uint are 17371, 17372, 17373 and
    // the percentages are 40(for immediate) and 20,20,20 corresponding  to each milestone, enter
    // [17371, 17372, 17373] and [40,20,20,20] in the _dates and _percentage arrays respectively.

    function Wallet(address[] _owners,  uint _required, uint _daylimit, address[] _FYN, uint[] _dates, uint[] _percentage)
            multiowned(_owners, _required) daylimit(_daylimit) amountWithdrawalStrategy(_FYN, _dates, _percentage)
            {

    }

    // kills the contract sending everything to `_to`.
    function kill(address _to) onlymanyowners(sha3(msg.data)) external {
        // ensure owners can't prematurely stop token sale
        require (!tokenSwap);
        // ensure owners can't kill wallet without stopping token
        //  otherwise token can never be stopped
        require (tokenCtr.transferStop() == true);
        suicide(_to);
    }

    // Activates Emergency Stop for Token
    function stopToken() onlymanyowners(sha3(msg.data)) external {
       tokenCtr.stopToken();
    }

    // gets called when no other function matches
    function()
    payable {
        buyTokens(msg.sender);
    }

    // function to transfer to any owner,
    // according to the milestone strategy.
    // Can only be called by the owner.
    function withdrawForOwner (address _addr, uint _value, bytes _data)
    onlyowner
    onlyWhiteListed (_addr)
    isUnderMilestoneLimit (_value) {
        recordTransaction(_value);
        execute(_addr, _value, _data);
    }

    // Outside-visible transact entry point. Executes transaction immediately if below daily spend limit.
    // If not, goes into multisig process. We provide a hash on return to allow the sender to provide
    // shortcuts for the other confirmations (allowing them to avoid replicating the _to, _value
    // and _data arguments). They still get the option of using them if they want, anyways.


    function execute(address _to, uint _value, bytes _data) internal
    returns (bytes32 _r) {
        // Disallow the wallet contract from calling token contract once it's set
        // so tokens can't be minted arbitrarily once the sale starts.
        // Tokens can be minted for premine before the sale opens and tokenCtr is set.
        require (_to != address(tokenCtr));

        // first, take the opportunity to check that we're under the daily limit.

        SingleTransact(msg.sender, _value, _to, _data);
        // yes - just execute the call.
        if(!_to.call.value(_value)(_data))
        return 0;


        // determine our operation hash.
        _r = sha3(msg.data, block.number);
        if (!confirm(_r) && m_txs[_r].to == 0) {
            m_txs[_r].to = _to;
            m_txs[_r].value = _value;
            m_txs[_r].data = _data;
            ConfirmationNeeded(_r, msg.sender, _value, _to, _data);
        }
    }

    // confirm a transaction through just the hash. we use the previous transactions map, m_txs, in order
    // to determine the body of the transaction from the hash provided.
    function confirm(bytes32 _h) onlymanyowners(_h) returns (bool) {
        if (m_txs[_h].to != 0) {
            if (!m_txs[_h].to.call.value(m_txs[_h].value)(m_txs[_h].data))   // Bugfix: If successful, MultiTransact event should fire; if unsuccessful, we should throw
                throw;
            MultiTransact(msg.sender, _h, m_txs[_h].value, m_txs[_h].to, m_txs[_h].data);
            delete m_txs[_h];
            return true;
        }
    }

    // function to start the refund process. Only accesisble by the
    // owner.
    function startRefundProcess () external
    onlyowner
    withdrawalNotMade {   // cannot start refund process if a withdrawal has been made
      refundInitiated = true;
    }

    // function to change the stored values of etherAmountDeposited
    // and amountRaised after a refund is claimed. Also clears the
    // token balances of the msg.sender.
    function recordRefund (address beneficiary) internal {
      refundReceived[uint(msg.sender)][uint(beneficiary)] = true;
      amountRaised -= etherAmountDeposited[uint(msg.sender)][uint(beneficiary)];
      etherAmountDeposited[uint(msg.sender)][uint(beneficiary)] = 0;
      tokenCtr.clearBalance(beneficiary);
    }

    // function to claim refund. Can only be called after the owner starts
    // the refund process. Only accesisble by depositors.
    // Calls the record refund function.
    function claimRefund (address _addr) external
    refundProcessStarted
    isDepositor
    refundNotClaimed (_addr)
    isBeneficiary (_addr) {
      require (safeToSub(amountRaised, etherAmountDeposited[uint(msg.sender)][uint(_addr)] ));
      recordRefund (_addr);
      execute (msg.sender, etherAmountDeposited[uint(msg.sender)][uint(_addr)], "");
    }

    // INTERNAL METHODS

    function clearPending() internal {
        uint length = m_pendingIndex.length;
        for (uint i = 0; i < length; ++i)
            delete m_txs[m_pendingIndex[i]];
        super.clearPending();
    }

	// FIELDS

    // pending transactions we have at present.
    mapping (bytes32 => Transaction) m_txs;
}
