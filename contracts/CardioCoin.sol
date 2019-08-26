pragma solidity >= 0.5.0;

import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";

contract CardioCoin is ERC20, Ownable {
    using SafeMath for uint256;

    uint public constant UNLOCK_PERIOD = 30 days;

    string public name = "CardioCoin";
    string public symbol = "CRDC";

    uint8 public decimals = 18;

    uint256 internal totalSupply_ = 33049129350 * (10 ** uint256(decimals));

    struct locker {
        bool isLocker;
        string role;
        uint lockUpPeriod;
        uint unlockCount;
    }

    mapping (address => locker) internal lockerList;

    event AddToLocker(address indexed owner, string role, uint lockUpPeriod, uint unlockCount);

    event TokenLocked(address indexed owner, uint256 amount);
    event TokenUnlocked(address indexed owner, uint256 amount);

    constructor() public Ownable() {
        balance memory b;

        b.available = totalSupply_;
        balances[msg.sender] = b;
    }

    function addLockedUpTokens(address _owner, uint256 amount, uint lockUpPeriod, uint unlockCount)
    internal {
        balance storage b = balances[_owner];
        lockUp memory l;

        l.amount = amount;
        l.unlockTimestamp = now + lockUpPeriod;
        l.unlockCount = unlockCount;
        b.lockedUp += amount;
        b.lockUpData[b.lockUpCount] = l;
        b.lockUpCount += 1;
        emit TokenLocked(_owner, amount);
    }

    // ERC20 Custom

    struct lockUp {
        uint256 amount;
        uint unlockTimestamp;
        uint unlockedCount;
        uint unlockCount;
    }

    struct balance {
        uint256 available;
        uint256 lockedUp;
        mapping (uint => lockUp) lockUpData;
        uint lockUpCount;
        uint unlockIndex;
    }

    mapping(address => balance) internal balances;

    function unlockBalance(address _owner) internal {
        balance storage b = balances[_owner];

        if (b.lockUpCount > 0 && b.unlockIndex < b.lockUpCount) {
            for (uint i = b.unlockIndex; i < b.lockUpCount; i++) {
                lockUp storage l = b.lockUpData[i];

                if (l.unlockTimestamp <= now) {
                    uint count = calculateUnlockCount(l.unlockTimestamp, l.unlockedCount, l.unlockCount);
                    uint256 unlockedAmount = l.amount.mul(count).div(l.unlockCount);

                    b.available = b.available.add(unlockedAmount);
                    b.lockedUp = b.lockedUp.sub(unlockedAmount);
                    l.unlockedCount += count;
                    if (l.unlockedCount == l.unlockCount) {
                        b.available = b.available.add(b.lockedUp);
                        unlockedAmount = unlockedAmount.add(b.lockedUp);

                        lockUp memory tempA = b.lockUpData[i];
                        lockUp memory tempB = b.lockUpData[b.unlockIndex];

                        b.lockUpData[i] = tempB;
                        b.lockUpData[b.unlockIndex] = tempA;
                        b.unlockIndex += 1;
                    } else {
                        l.unlockTimestamp += UNLOCK_PERIOD * count;
                    }
                    emit TokenUnlocked(_owner, unlockedAmount);
                }
            }
        }
    }

    function calculateUnlockCount(uint timestamp, uint unlockedCount, uint unlockCount) view internal returns (uint) {
        uint count = 0;
        uint nowFixed = now;

        while (timestamp < nowFixed && unlockedCount + count < unlockCount) {
            count++;
            timestamp += UNLOCK_PERIOD;
        }

        return count;
    }

    function totalSupply() public view returns (uint256) {
        return totalSupply_;
    }

    function _transfer(address from, address to, uint256 value) internal {
        locker storage l = lockerList[from];

        unlockBalance(from);

        require(value <= balances[from].available);
        require(to != address(0));
        if (l.isLocker) {
            balances[from].available = balances[from].available.sub(value);
            addLockedUpTokens(to, value, l.lockUpPeriod, l.unlockCount);
        } else {
            balances[from].available = balances[from].available.sub(value);
            balances[to].available = balances[to].available.add(value);
        }
        emit Transfer(from, to, value);
    }

    function balanceOf(address _owner) public view returns (uint256) {
        return balances[_owner].available.add(balances[_owner].lockedUp);
    }

    function lockedUpBalanceOf(address _owner) public view returns (uint256) {
        balance storage b = balances[_owner];
        uint256 lockedUpBalance = b.lockedUp;

        if (b.lockUpCount > 0 && b.unlockIndex < b.lockUpCount) {
            for (uint i = b.unlockIndex; i < b.lockUpCount; i++) {
                lockUp storage l = b.lockUpData[i];

                if (l.unlockTimestamp <= now) {
                    uint count = calculateUnlockCount(l.unlockTimestamp, l.unlockedCount, l.unlockCount);
                    uint256 unlockedAmount = l.amount.mul(count).div(l.unlockCount);

                    lockedUpBalance = lockedUpBalance.sub(unlockedAmount);
                }
            }
        }

        return lockedUpBalance;
    }

    // Burnable

    event Burn(address indexed burner, uint256 value);

    function burn(uint256 _value) public {
        _burn(msg.sender, _value);
    }

    function _burn(address _who, uint256 _value) internal {
        require(_value <= balances[_who].available);

        balances[_who].available = balances[_who].available.sub(_value);
        totalSupply_ = totalSupply_.sub(_value);
        emit Burn(_who, _value);
        emit Transfer(_who, address(0), _value);
    }

    // 락업

    function addAddressToLockerList(address _operator, string memory role, uint lockUpPeriod, uint unlockCount)
    public
    onlyOwner {
        locker storage existsLocker = lockerList[_operator];

        require(!existsLocker.isLocker);
        require(unlockCount > 0);

        locker memory l;

        l.isLocker = true;
        l.role = role;
        l.lockUpPeriod = lockUpPeriod;
        l.unlockCount = unlockCount;
        lockerList[_operator] = l;
        emit AddToLocker(_operator, role, lockUpPeriod, unlockCount);
    }

    function lockerInfo(address _operator) public view returns (string memory, uint, uint) {
        locker memory l = lockerList[_operator];

        return (l.role, l.lockUpPeriod, l.unlockCount);
    }

    // Refund

    event RefundRequested(address indexed requester, uint256 tokenAmount, uint256 paidAmount);
    event RefundCanceled(address indexed requester);
    event RefundAccepted(address indexed requester, address indexed tokenReceiver, uint256 tokenAmount, uint256 paidAmount);

    struct refundRequest {
        bool active;
        uint256 tokenAmount;
        uint256 paidAmount;
    }

    mapping (address => refundRequest) internal refundRequests;

    function requestRefund(uint256 paidAmount) public {
        require(!refundRequests[msg.sender].active);

        refundRequest memory r;

        r.active = true;
        r.tokenAmount = balanceOf(msg.sender);
        r.paidAmount = paidAmount;
        refundRequests[msg.sender] = r;

        emit RefundRequested(msg.sender, r.tokenAmount, r.paidAmount);
    }

    function cancelRefund() public {
        require(refundRequests[msg.sender].active);
        refundRequests[msg.sender].active = false;
        emit RefundCanceled(msg.sender);
    }

    function acceptRefundForOwner(address payable requester, address receiver) public payable onlyOwner {
        require(requester != address(0));
        require(receiver != address(0));

        refundRequest storage r = refundRequests[requester];

        require(r.active);
        require(balanceOf(requester) == r.tokenAmount);
        require(msg.value == r.paidAmount);
        requester.call.value(msg.value);
//        requester.transfer(msg.value);
        transferForRefund(requester, receiver, r.tokenAmount);
        r.active = false;
        emit RefundAccepted(requester, receiver, r.tokenAmount, msg.value);
    }

    function refundInfo(address requester) public view returns (bool, uint256, uint256) {
        refundRequest memory r = refundRequests[requester];

        return (r.active, r.tokenAmount, r.paidAmount);
    }

    function transferForRefund(address from, address to, uint256 amount) internal {
        unlockBalance(from);

        balance storage fromBalance = balances[from];
        balance storage toBalance = balances[to];

        fromBalance.available = 0;
        fromBalance.lockedUp = 0;
        fromBalance.unlockIndex = fromBalance.lockUpCount;
        toBalance.available = toBalance.available.add(amount);

        emit Transfer(from, to, amount);
    }
}
