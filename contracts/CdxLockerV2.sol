// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/MathUtil.sol";
import "./interfaces/IStakingProxy.sol";
import "./interfaces/IRewardStaking.sol";
import "./interfaces/BoringMath.sol";

/*
CDX Locking contract for Codex
CDX locked in this contract will be entitled to voting rights for the Codex platform
Based on EPS Staking contract for http://ellipsis.finance/
Based on SNX MultiRewards by iamdefinitelyahuman - https://github.com/iamdefinitelyahuman/multi-rewards

V2:
- change locking mechanism to lock to a future epoch instead of current
- pending lock getter
- relocking allocates weight to the current epoch instead of future,
    thus allows keeping voting weight in the same epoch a lock expires by relocking before a vote begins
- balanceAtEpoch and supplyAtEpoch return proper values for future epochs
- do not allow relocking directly to a new address
*/
contract CdxLockerV2 is ReentrancyGuard, Ownable {
    using BoringMath for uint256;
    using BoringMath224 for uint224;
    using BoringMath112 for uint112;
    using BoringMath32 for uint32;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    struct Reward {
        bool useBoost;
        uint40 periodFinish;
        uint208 rewardRate;
        uint40 lastUpdateTime;
        uint208 rewardPerTokenStored;
    }
    struct Balances {
        uint112 locked;
        uint112 boosted;
        uint32 nextUnlockIndex;
    }
    struct LockedBalance {
        uint112 amount;
        uint112 boosted;
        uint32 unlockTime;
    }
    struct EarnedData {
        address token;
        uint256 amount;
    }
    struct Epoch {
        uint224 supply; //epoch boosted supply
        uint32 date; //epoch start date
    }

    //token constants
    IERC20 public immutable stakingToken; // CDX
    address public immutable cdxLit; // cdxLIT

    //rewards
    address[] public rewardTokens;
    mapping(address => Reward) public rewardData;

    // Duration that rewards are streamed over
    uint256 public constant rewardsDuration = 86400 * 7;

    // Duration of lock/earned penalty period
    uint256 public constant lockDuration = rewardsDuration * 16;

    // reward token -> distributor -> is approved to add rewards
    mapping(address => mapping(address => bool)) public rewardDistributors;

    // user -> reward token -> amount
    mapping(address => mapping(address => uint256))
        public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    //supplies and epochs
    uint256 public lockedSupply;
    uint256 public boostedSupply;
    Epoch[] public epochs;

    //mappings for balance data
    mapping(address => Balances) public balances;
    mapping(address => LockedBalance[]) public userLocks;

    //boost
    address public boostPayment;
    uint256 public maximumBoostPayment = 0;
    uint256 public boostRate = 10000;
    uint256 public nextMaximumBoostPayment = 0;
    uint256 public nextBoostRate = 10000;
    uint256 public constant denominator = 10000;

    //staking
    uint256 public minimumStake = 10000;
    uint256 public maximumStake = 10000;
    address public stakingProxy;
    address public immutable cdxlitStaking; // BaseRewardPool
    uint256 public constant stakeOffsetOnLock = 500; //allow broader range for staking when depositing

    //management
    uint256 public kickRewardPerEpoch = 100;
    uint256 public kickRewardEpochDelay = 4;

    //shutdown
    bool public isShutdown = false;

    //erc20-like interface
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _stakingToken,
        address _cdxLit,
        address _boostPayment,
        address _cdxlitStaking
    ) Ownable() {
        _name = "Vote Locked Codex Token";
        _symbol = "vlCDX";
        _decimals = 18;

        stakingToken = IERC20(_stakingToken);
        cdxLit = _cdxLit;
        boostPayment = _boostPayment;
        cdxlitStaking = _cdxlitStaking;

        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(
            rewardsDuration
        );
        epochs.push(Epoch({supply: 0, date: uint32(currentEpoch)}));
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function version() public pure returns (uint256) {
        return 2;
    }

    /* ========== ADMIN CONFIGURATION ========== */

    // Add a new reward token to be distributed to stakers
    function addReward(
        address _rewardsToken,
        address _distributor,
        bool _useBoost
    ) public onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime == 0);
        require(_rewardsToken != address(stakingToken));
        rewardTokens.push(_rewardsToken);
        rewardData[_rewardsToken].lastUpdateTime = uint40(block.timestamp);
        rewardData[_rewardsToken].periodFinish = uint40(block.timestamp);
        rewardData[_rewardsToken].useBoost = _useBoost;
        rewardDistributors[_rewardsToken][_distributor] = true;
    }

    // Modify approval for an address to call notifyRewardAmount
    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime > 0);
        rewardDistributors[_rewardsToken][_distributor] = _approved;
    }

    //Set the staking contract for the underlying cdx
    function setStakingContract(address _staking) external onlyOwner {
        require(stakingProxy == address(0), "!assign");

        stakingProxy = _staking;
    }

    //set staking limits. will stake the mean of the two once either ratio is crossed
    function setStakeLimits(
        uint256 _minimum,
        uint256 _maximum
    ) external onlyOwner {
        require(_minimum <= denominator, "min range");
        require(_maximum <= denominator, "max range");
        require(_minimum <= _maximum, "min range");
        minimumStake = _minimum;
        maximumStake = _maximum;
        updateStakeRatio(0);
    }

    //set boost parameters
    function setBoost(
        uint256 _max,
        uint256 _rate,
        address _receivingAddress
    ) external onlyOwner {
        require(_max < 1500, "over max payment"); //max 15%
        require(_rate < 30000, "over max rate"); //max 3x
        require(_receivingAddress != address(0), "invalid address"); //must point somewhere valid
        nextMaximumBoostPayment = _max;
        nextBoostRate = _rate;
        boostPayment = _receivingAddress;
    }

    //set kick incentive
    function setKickIncentive(
        uint256 _rate,
        uint256 _delay
    ) external onlyOwner {
        require(_rate <= 500, "over max rate"); //max 5% per epoch
        require(_delay >= 2, "min delay"); //minimum 2 epochs of grace
        kickRewardPerEpoch = _rate;
        kickRewardEpochDelay = _delay;
    }

    //shutdown the contract. unstake all tokens. release all locks
    function shutdown() external onlyOwner {
        if (stakingProxy != address(0)) {
            uint256 stakeBalance = IStakingProxy(stakingProxy).getBalance();
            IStakingProxy(stakingProxy).withdraw(stakeBalance);
        }
        isShutdown = true;
    }

    //set approvals for staking cdx and cdxlit
    function setApprovals() external {
        IERC20(cdxLit).safeApprove(cdxlitStaking, 0);
        IERC20(cdxLit).safeApprove(cdxlitStaking, type(uint256).max);

        IERC20(stakingToken).safeApprove(stakingProxy, 0);
        IERC20(stakingToken).safeApprove(stakingProxy, type(uint256).max);
    }

    /* ========== VIEWS ========== */

    function _rewardPerToken(
        address _rewardsToken
    ) internal view returns (uint256) {
        if (boostedSupply == 0) {
            return rewardData[_rewardsToken].rewardPerTokenStored;
        }
        return
            uint256(rewardData[_rewardsToken].rewardPerTokenStored).add(
                _lastTimeRewardApplicable(
                    rewardData[_rewardsToken].periodFinish
                )
                    .sub(rewardData[_rewardsToken].lastUpdateTime)
                    .mul(rewardData[_rewardsToken].rewardRate)
                    .mul(1e18)
                    .div(
                        rewardData[_rewardsToken].useBoost
                            ? boostedSupply
                            : lockedSupply
                    )
            );
    }

    function _earned(
        address _user,
        address _rewardsToken,
        uint256 _balance
    ) internal view returns (uint256) {
        return
            _balance
                .mul(
                    _rewardPerToken(_rewardsToken).sub(
                        userRewardPerTokenPaid[_user][_rewardsToken]
                    )
                )
                .div(1e18)
                .add(rewards[_user][_rewardsToken]);
    }

    function _lastTimeRewardApplicable(
        uint256 _finishTime
    ) internal view returns (uint256) {
        return Math.min(block.timestamp, _finishTime);
    }

    function lastTimeRewardApplicable(
        address _rewardsToken
    ) public view returns (uint256) {
        return
            _lastTimeRewardApplicable(rewardData[_rewardsToken].periodFinish);
    }

    function rewardPerToken(
        address _rewardsToken
    ) external view returns (uint256) {
        return _rewardPerToken(_rewardsToken);
    }

    function getRewardForDuration(
        address _rewardsToken
    ) external view returns (uint256) {
        return
            uint256(rewardData[_rewardsToken].rewardRate).mul(rewardsDuration);
    }

    // Address and claimable amount of all reward tokens for the given account
    function claimableRewards(
        address _account
    ) external view returns (EarnedData[] memory userRewards) {
        userRewards = new EarnedData[](rewardTokens.length);
        Balances storage userBalance = balances[_account];
        uint256 boostedBal = userBalance.boosted;
        for (uint256 i = 0; i < userRewards.length; i++) {
            address token = rewardTokens[i];
            userRewards[i].token = token;
            userRewards[i].amount = _earned(
                _account,
                token,
                rewardData[token].useBoost ? boostedBal : userBalance.locked
            );
        }
        return userRewards;
    }

    // Total BOOSTED balance of an account, including unlocked but not withdrawn tokens
    function rewardWeightOf(
        address _user
    ) external view returns (uint256 amount) {
        return balances[_user].boosted;
    }

    // total token balance of an account, including unlocked but not withdrawn tokens
    function lockedBalanceOf(
        address _user
    ) external view returns (uint256 amount) {
        return balances[_user].locked;
    }

    //BOOSTED balance of an account which only includes properly locked tokens as of the most recent eligible epoch
    function balanceOf(address _user) external view returns (uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];
        Balances storage userBalance = balances[_user];
        uint256 nextUnlockIndex = userBalance.nextUnlockIndex;

        //start with current boosted amount
        amount = balances[_user].boosted;

        uint256 locksLength = locks.length;
        //remove old records only (will be better gas-wise than adding up)
        for (uint i = nextUnlockIndex; i < locksLength; i++) {
            if (locks[i].unlockTime <= block.timestamp) {
                amount = amount.sub(locks[i].boosted);
            } else {
                //stop now as no futher checks are needed
                break;
            }
        }

        //also remove amount locked in the next epoch
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(
            rewardsDuration
        );
        if (
            locksLength > 0 &&
            uint256(locks[locksLength - 1].unlockTime).sub(lockDuration) >
            currentEpoch
        ) {
            amount = amount.sub(locks[locksLength - 1].boosted);
        }

        return amount;
    }

    //BOOSTED balance of an account which only includes properly locked tokens at the given epoch
    function balanceAtEpochOf(
        uint256 _epoch,
        address _user
    ) external view returns (uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];

        //get timestamp of given epoch index
        uint256 epochTime = epochs[_epoch].date;
        //get timestamp of first non-inclusive epoch
        uint256 cutoffEpoch = epochTime.sub(lockDuration);

        //need to add up since the range could be in the middle somewhere
        //traverse inversely to make more current queries more gas efficient
        for (uint i = locks.length - 1; i + 1 != 0; i--) {
            uint256 lockEpoch = uint256(locks[i].unlockTime).sub(lockDuration);
            //lock epoch must be less or equal to the epoch we're basing from.
            if (lockEpoch <= epochTime) {
                if (lockEpoch > cutoffEpoch) {
                    amount = amount.add(locks[i].boosted);
                } else {
                    //stop now as no futher checks matter
                    break;
                }
            }
        }

        return amount;
    }

    //return currently locked but not active balance
    function pendingLockOf(
        address _user
    ) external view returns (uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];

        uint256 locksLength = locks.length;

        //return amount if latest lock is in the future
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(
            rewardsDuration
        );
        if (
            locksLength > 0 &&
            uint256(locks[locksLength - 1].unlockTime).sub(lockDuration) >
            currentEpoch
        ) {
            return locks[locksLength - 1].boosted;
        }

        return 0;
    }

    function pendingLockAtEpochOf(
        uint256 _epoch,
        address _user
    ) external view returns (uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];

        //get next epoch from the given epoch index
        uint256 nextEpoch = uint256(epochs[_epoch].date).add(rewardsDuration);

        //traverse inversely to make more current queries more gas efficient
        for (uint i = locks.length - 1; i + 1 != 0; i--) {
            uint256 lockEpoch = uint256(locks[i].unlockTime).sub(lockDuration);

            //return the next epoch balance
            if (lockEpoch == nextEpoch) {
                return locks[i].boosted;
            } else if (lockEpoch < nextEpoch) {
                //no need to check anymore
                break;
            }
        }

        return 0;
    }

    //supply of all properly locked BOOSTED balances at most recent eligible epoch
    function totalSupply() external view returns (uint256 supply) {
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(
            rewardsDuration
        );
        uint256 cutoffEpoch = currentEpoch.sub(lockDuration);
        uint256 epochindex = epochs.length;

        //do not include next epoch's supply
        if (uint256(epochs[epochindex - 1].date) > currentEpoch) {
            epochindex--;
        }

        //traverse inversely to make more current queries more gas efficient
        for (uint i = epochindex - 1; i + 1 != 0; i--) {
            Epoch storage e = epochs[i];
            if (uint256(e.date) <= cutoffEpoch) {
                break;
            }
            supply = supply.add(e.supply);
        }

        return supply;
    }

    //supply of all properly locked BOOSTED balances at the given epoch
    function totalSupplyAtEpoch(
        uint256 _epoch
    ) external view returns (uint256 supply) {
        uint256 epochStart = uint256(epochs[_epoch].date)
            .div(rewardsDuration)
            .mul(rewardsDuration);
        uint256 cutoffEpoch = epochStart.sub(lockDuration);

        //traverse inversely to make more current queries more gas efficient
        for (uint i = _epoch; i + 1 != 0; i--) {
            Epoch storage e = epochs[i];
            if (uint256(e.date) <= cutoffEpoch) {
                break;
            }
            supply = supply.add(epochs[i].supply);
        }

        return supply;
    }

    //find an epoch index based on timestamp
    function findEpochId(uint256 _time) external view returns (uint256 epoch) {
        uint256 max = epochs.length - 1;
        uint256 min = 0;

        //convert to start point
        _time = _time.div(rewardsDuration).mul(rewardsDuration);

        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) break;

            uint256 mid = (min + max + 1) / 2;
            uint256 midEpochBlock = epochs[mid].date;
            if (midEpochBlock == _time) {
                //found
                return mid;
            } else if (midEpochBlock < _time) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    // Information on a user's locked balances
    function lockedBalances(
        address _user
    )
        external
        view
        returns (
            uint256 total,
            uint256 unlockable,
            uint256 locked,
            LockedBalance[] memory lockData
        )
    {
        LockedBalance[] storage locks = userLocks[_user];
        Balances storage userBalance = balances[_user];
        uint256 nextUnlockIndex = userBalance.nextUnlockIndex;
        uint256 idx;
        for (uint i = nextUnlockIndex; i < locks.length; i++) {
            if (locks[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    lockData = new LockedBalance[](locks.length - i);
                }
                lockData[idx] = locks[i];
                idx++;
                locked = locked.add(locks[i].amount);
            } else {
                unlockable = unlockable.add(locks[i].amount);
            }
        }
        return (userBalance.locked, unlockable, locked, lockData);
    }

    //number of epochs
    function epochCount() external view returns (uint256) {
        return epochs.length;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function checkpointEpoch() external {
        _checkpointEpoch();
    }

    //insert a new epoch if needed. fill in any gaps
    function _checkpointEpoch() internal {
        //create new epoch in the future where new non-active locks will lock to
        uint256 nextEpoch = block
            .timestamp
            .div(rewardsDuration)
            .mul(rewardsDuration)
            .add(rewardsDuration);
        uint256 epochindex = epochs.length;

        //first epoch add in constructor, no need to check 0 length

        //check to add
        if (epochs[epochindex - 1].date < nextEpoch) {
            //fill any epoch gaps
            while (epochs[epochs.length - 1].date != nextEpoch) {
                uint256 nextEpochDate = uint256(epochs[epochs.length - 1].date)
                    .add(rewardsDuration);
                epochs.push(Epoch({supply: 0, date: uint32(nextEpochDate)}));
            }

            //update boost parameters on a new epoch
            if (boostRate != nextBoostRate) {
                boostRate = nextBoostRate;
            }
            if (maximumBoostPayment != nextMaximumBoostPayment) {
                maximumBoostPayment = nextMaximumBoostPayment;
            }
        }
    }

    // Locked tokens cannot be withdrawn for lockDuration and are eligible to receive stakingReward rewards
    function lock(
        address _account,
        uint256 _amount,
        uint256 _spendRatio
    ) external nonReentrant updateReward(_account) {
        //pull tokens
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        //lock
        _lock(_account, _amount, _spendRatio, false);
    }

    //lock tokens
    function _lock(
        address _account,
        uint256 _amount,
        uint256 _spendRatio,
        bool _isRelock
    ) internal {
        require(_amount > 0, "Cannot stake 0");
        require(_spendRatio <= maximumBoostPayment, "over max spend");
        require(!isShutdown, "shutdown");

        Balances storage bal = balances[_account];

        //must try check pointing epoch first
        _checkpointEpoch();

        //calc lock and boosted amount
        uint256 spendAmount = _amount.mul(_spendRatio).div(denominator);
        uint256 boostRatio = boostRate.mul(_spendRatio).div(
            maximumBoostPayment == 0 ? 1 : maximumBoostPayment
        );
        uint112 lockAmount = _amount.sub(spendAmount).to112();
        uint112 boostedAmount = _amount
            .add(_amount.mul(boostRatio).div(denominator))
            .to112();

        //add user balances
        bal.locked = bal.locked.add(lockAmount);
        bal.boosted = bal.boosted.add(boostedAmount);

        //add to total supplies
        lockedSupply = lockedSupply.add(lockAmount);
        boostedSupply = boostedSupply.add(boostedAmount);

        //add user lock records or add to current
        uint256 lockEpoch = block.timestamp.div(rewardsDuration).mul(
            rewardsDuration
        );
        //if a fresh lock, add on an extra duration period
        if (!_isRelock) {
            lockEpoch = lockEpoch.add(rewardsDuration);
        }
        uint256 unlockTime = lockEpoch.add(lockDuration);
        uint256 idx = userLocks[_account].length;

        //if the latest user lock is smaller than this lock, always just add new entry to the end of the list
        if (idx == 0 || userLocks[_account][idx - 1].unlockTime < unlockTime) {
            userLocks[_account].push(
                LockedBalance({
                    amount: lockAmount,
                    boosted: boostedAmount,
                    unlockTime: uint32(unlockTime)
                })
            );
        } else {
            //else add to a current lock

            //if latest lock is further in the future, lower index
            //this can only happen if relocking an expired lock after creating a new lock
            if (userLocks[_account][idx - 1].unlockTime > unlockTime) {
                idx--;
            }

            //if idx points to the epoch when same unlock time, update
            //(this is always true with a normal lock but maybe not with relock)
            if (userLocks[_account][idx - 1].unlockTime == unlockTime) {
                LockedBalance storage userL = userLocks[_account][idx - 1];
                userL.amount = userL.amount.add(lockAmount);
                userL.boosted = userL.boosted.add(boostedAmount);
            } else {
                //can only enter here if a relock is made after a lock and there's no lock entry
                //for the current epoch.
                //ex a list of locks such as "[...][older][current*][next]" but without a "current" lock
                //length - 1 is the next epoch
                //length - 2 is a past epoch
                //thus need to insert an entry for current epoch at the 2nd to last entry
                //we will copy and insert the tail entry(next) and then overwrite length-2 entry

                //reset idx
                idx = userLocks[_account].length;

                //get current last item
                LockedBalance storage userL = userLocks[_account][idx - 1];

                //add a copy to end of list
                userLocks[_account].push(
                    LockedBalance({
                        amount: userL.amount,
                        boosted: userL.boosted,
                        unlockTime: userL.unlockTime
                    })
                );

                //insert current epoch lock entry by overwriting the entry at length-2
                userL.amount = lockAmount;
                userL.boosted = boostedAmount;
                userL.unlockTime = uint32(unlockTime);
            }
        }

        //update epoch supply, epoch checkpointed above so safe to add to latest
        uint256 eIndex = epochs.length - 1;
        //if relock, epoch should be current and not next, thus need to decrease index to length-2
        if (_isRelock) {
            eIndex--;
        }
        Epoch storage e = epochs[eIndex];
        e.supply = e.supply.add(uint224(boostedAmount));

        //send boost payment
        if (spendAmount > 0) {
            stakingToken.safeTransfer(boostPayment, spendAmount);
        }

        //update staking, allow a bit of leeway for smaller deposits to reduce gas
        updateStakeRatio(stakeOffsetOnLock);

        emit Staked(_account, lockEpoch, _amount, lockAmount, boostedAmount);
    }

    // Withdraw all currently locked tokens where the unlock time has passed
    function _processExpiredLocks(
        address _account,
        bool _relock,
        uint256 _spendRatio,
        address _withdrawTo,
        address _rewardAddress,
        uint256 _checkDelay
    ) internal updateReward(_account) {
        LockedBalance[] storage locks = userLocks[_account];
        Balances storage userBalance = balances[_account];
        uint112 locked;
        uint112 boostedAmount;
        uint256 length = locks.length;
        uint256 reward = 0;

        if (
            isShutdown ||
            locks[length - 1].unlockTime <= block.timestamp.sub(_checkDelay)
        ) {
            //if time is beyond last lock, can just bundle everything together
            locked = userBalance.locked;
            boostedAmount = userBalance.boosted;

            //dont delete, just set next index
            userBalance.nextUnlockIndex = length.to32();

            //check for kick reward
            //this wont have the exact reward rate that you would get if looped through
            //but this section is supposed to be for quick and easy low gas processing of all locks
            //we'll assume that if the reward was good enough someone would have processed at an earlier epoch
            if (_checkDelay > 0) {
                uint256 currentEpoch = block
                    .timestamp
                    .sub(_checkDelay)
                    .div(rewardsDuration)
                    .mul(rewardsDuration);
                uint256 epochsover = currentEpoch
                    .sub(uint256(locks[length - 1].unlockTime))
                    .div(rewardsDuration);
                uint256 rRate = MathUtil.min(
                    kickRewardPerEpoch.mul(epochsover + 1),
                    denominator
                );
                reward = uint256(locks[length - 1].amount).mul(rRate).div(
                    denominator
                );
            }
        } else {
            //use a processed index(nextUnlockIndex) to not loop as much
            //deleting does not change array length
            uint32 nextUnlockIndex = userBalance.nextUnlockIndex;
            for (uint i = nextUnlockIndex; i < length; i++) {
                //unlock time must be less or equal to time
                if (locks[i].unlockTime > block.timestamp.sub(_checkDelay))
                    break;

                //add to cumulative amounts
                locked = locked.add(locks[i].amount);
                boostedAmount = boostedAmount.add(locks[i].boosted);

                //check for kick reward
                //each epoch over due increases reward
                if (_checkDelay > 0) {
                    uint256 currentEpoch = block
                        .timestamp
                        .sub(_checkDelay)
                        .div(rewardsDuration)
                        .mul(rewardsDuration);
                    uint256 epochsover = currentEpoch
                        .sub(uint256(locks[i].unlockTime))
                        .div(rewardsDuration);
                    uint256 rRate = MathUtil.min(
                        kickRewardPerEpoch.mul(epochsover + 1),
                        denominator
                    );
                    reward = reward.add(
                        uint256(locks[i].amount).mul(rRate).div(denominator)
                    );
                }
                //set next unlock index
                nextUnlockIndex++;
            }
            //update next unlock index
            userBalance.nextUnlockIndex = nextUnlockIndex;
        }
        require(locked > 0, "no exp locks");

        //update user balances and total supplies
        userBalance.locked = userBalance.locked.sub(locked);
        userBalance.boosted = userBalance.boosted.sub(boostedAmount);
        lockedSupply = lockedSupply.sub(locked);
        boostedSupply = boostedSupply.sub(boostedAmount);

        emit Withdrawn(_account, locked, _relock);

        //send process incentive
        if (reward > 0) {
            //if theres a reward(kicked), it will always be a withdraw only
            //preallocate enough cdx from stake contract to pay for both reward and withdraw
            allocateCDXForTransfer(uint256(locked));

            //reduce return amount by the kick reward
            locked = locked.sub(reward.to112());

            //transfer reward
            transferCDX(_rewardAddress, reward, false);

            emit KickReward(_rewardAddress, _account, reward);
        } else if (_spendRatio > 0) {
            //preallocate enough cdx to transfer the boost cost
            allocateCDXForTransfer(
                uint256(locked).mul(_spendRatio).div(denominator)
            );
        }

        //relock or return to user
        if (_relock) {
            _lock(_withdrawTo, locked, _spendRatio, true);
        } else {
            transferCDX(_withdrawTo, locked, true);
        }
    }

    // withdraw expired locks to a different address
    function withdrawExpiredLocksTo(address _withdrawTo) external nonReentrant {
        _processExpiredLocks(msg.sender, false, 0, _withdrawTo, msg.sender, 0);
    }

    // Withdraw/relock all currently locked tokens where the unlock time has passed
    function processExpiredLocks(bool _relock) external nonReentrant {
        _processExpiredLocks(msg.sender, _relock, 0, msg.sender, msg.sender, 0);
    }

    function kickExpiredLocks(address _account) external nonReentrant {
        //allow kick after grace period of 'kickRewardEpochDelay'
        _processExpiredLocks(
            _account,
            false,
            0,
            _account,
            msg.sender,
            rewardsDuration.mul(kickRewardEpochDelay)
        );
    }

    //pull required amount of cdx from staking for an upcoming transfer
    function allocateCDXForTransfer(uint256 _amount) internal {
        uint256 balance = stakingToken.balanceOf(address(this));
        if (_amount > balance) {
            IStakingProxy(stakingProxy).withdraw(_amount.sub(balance));
        }
    }

    //transfer helper: pull enough from staking, transfer, updating staking ratio
    function transferCDX(
        address _account,
        uint256 _amount,
        bool _updateStake
    ) internal {
        //allocate enough cdx from staking for the transfer
        allocateCDXForTransfer(_amount);
        //transfer
        stakingToken.safeTransfer(_account, _amount);

        //update staking
        if (_updateStake) {
            updateStakeRatio(0);
        }
    }

    //calculate how much cdx should be staked. update if needed
    function updateStakeRatio(uint256 _offset) internal {
        if (isShutdown) return;

        //get balances
        uint256 local = stakingToken.balanceOf(address(this));
        uint256 staked = IStakingProxy(stakingProxy).getBalance();
        uint256 total = local.add(staked);

        if (total == 0) return;

        //current staked ratio
        uint256 ratio = staked.mul(denominator).div(total);
        //mean will be where we reset to if unbalanced
        uint256 mean = maximumStake.add(minimumStake).div(2);
        uint256 max = maximumStake.add(_offset);
        uint256 min = Math.min(minimumStake, minimumStake - _offset);
        if (ratio > max) {
            //remove
            uint256 remove = staked.sub(total.mul(mean).div(denominator));
            IStakingProxy(stakingProxy).withdraw(remove);
        } else if (ratio < min) {
            //add
            uint256 increase = total.mul(mean).div(denominator).sub(staked);
            stakingToken.safeTransfer(stakingProxy, increase);
            IStakingProxy(stakingProxy).stake();
        }
    }

    // Claim all pending rewards
    function getReward(
        address _account,
        bool _stake
    ) public nonReentrant updateReward(_account) {
        for (uint i; i < rewardTokens.length; i++) {
            address _rewardsToken = rewardTokens[i];
            uint256 reward = rewards[_account][_rewardsToken];
            if (reward > 0) {
                rewards[_account][_rewardsToken] = 0;
                if (_rewardsToken == cdxLit && _stake) {
                    IRewardStaking(cdxlitStaking).stakeFor(_account, reward);
                } else {
                    IERC20(_rewardsToken).safeTransfer(_account, reward);
                }
                emit RewardPaid(_account, _rewardsToken, reward);
            }
        }
    }

    // claim all pending rewards
    function getReward(address _account) external {
        getReward(_account, false);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function _notifyReward(address _rewardsToken, uint256 _reward) internal {
        Reward storage rdata = rewardData[_rewardsToken];

        if (block.timestamp >= rdata.periodFinish) {
            rdata.rewardRate = _reward.div(rewardsDuration).to208();
        } else {
            uint256 remaining = uint256(rdata.periodFinish).sub(
                block.timestamp
            );
            uint256 leftover = remaining.mul(rdata.rewardRate);
            rdata.rewardRate = _reward
                .add(leftover)
                .div(rewardsDuration)
                .to208();
        }

        rdata.lastUpdateTime = block.timestamp.to40();
        rdata.periodFinish = block.timestamp.add(rewardsDuration).to40();
    }

    function notifyRewardAmount(
        address _rewardsToken,
        uint256 _reward
    ) external updateReward(address(0)) {
        require(rewardDistributors[_rewardsToken][msg.sender]);
        require(_reward > 0, "No reward");

        _notifyReward(_rewardsToken, _reward);

        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the _reward amount
        IERC20(_rewardsToken).safeTransferFrom(
            msg.sender,
            address(this),
            _reward
        );

        emit RewardAdded(_rewardsToken, _reward);

        if (_rewardsToken == cdxLit) {
            //update staking ratio if main reward
            updateStakeRatio(0);
        }
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(
        address _tokenAddress,
        uint256 _tokenAmount
    ) external onlyOwner {
        require(
            _tokenAddress != address(stakingToken),
            "Cannot withdraw staking token"
        );
        require(
            rewardData[_tokenAddress].lastUpdateTime == 0,
            "Cannot withdraw reward token"
        );
        IERC20(_tokenAddress).safeTransfer(owner(), _tokenAmount);
        emit Recovered(_tokenAddress, _tokenAmount);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address _account) {
        {
            //stack too deep
            Balances storage userBalance = balances[_account];
            uint256 boostedBal = userBalance.boosted;
            for (uint i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                rewardData[token].rewardPerTokenStored = _rewardPerToken(token)
                    .to208();
                rewardData[token].lastUpdateTime = _lastTimeRewardApplicable(
                    rewardData[token].periodFinish
                ).to40();
                if (_account != address(0)) {
                    //check if reward is boostable or not. use boosted or locked balance accordingly
                    rewards[_account][token] = _earned(
                        _account,
                        token,
                        rewardData[token].useBoost
                            ? boostedBal
                            : userBalance.locked
                    );
                    userRewardPerTokenPaid[_account][token] = rewardData[token]
                        .rewardPerTokenStored;
                }
            }
        }
        _;
    }

    /* ========== EVENTS ========== */
    event RewardAdded(address indexed _token, uint256 _reward);
    event Staked(
        address indexed _user,
        uint256 indexed _epoch,
        uint256 _paidAmount,
        uint256 _lockedAmount,
        uint256 _boostedAmount
    );
    event Withdrawn(address indexed _user, uint256 _amount, bool _relocked);
    event KickReward(
        address indexed _user,
        address indexed _kicked,
        uint256 _reward
    );
    event RewardPaid(
        address indexed _user,
        address indexed _rewardsToken,
        uint256 _reward
    );
    event Recovered(address _token, uint256 _amount);
}
