// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ReentrancyGuard.sol";

interface IMarket {
    function FEE() external view returns (uint256);
    function minimumBalance() external view returns (uint64);
    function totalShares() external view returns (uint64);
    function resolved() external view returns (bool);
    function hoursToWinnerWithdraw() external view returns (uint256);
    function deposit(address _trader, uint8 _outcome, uint64 _amount) external payable;
    function switchToOutcome(address, uint8) external payable;
    function withdraw(address) external returns (bool, uint64);
    function delist() external;
    function appeal(address, string memory) external;
    function protocolVote(address _trader, uint8 _outcome, uint64 _amount) external;
}

interface ILend {
    function depositETH(address pool, address onBehalfOf, uint16 referralCode) external payable;
    function withdrawETH(address pool, uint256 amount, address to) external;
}

interface IWhypePool {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20 {
    function approve(address, uint256) external returns (bool);
}

contract Market is ReentrancyGuard {
    ILend public hyperLendGateway;
    IWhypePool public whypePool;
    IERC20 public whypeToken;
    address public immutable hyperLendGatewayAddr = 0x49558c794ea2aC8974C9F27886DDfAa951E99171;
    address public immutable whypeTokenAddr = 0x5555555555555555555555555555555555555555;
    address public immutable whypePoolAddr = 0x0D745EAA9E70bb8B6e2a0317f85F1d536616bD34;
    uint256 public immutable TICKET = 10 ** 17;
    uint256 public immutable FEE = 10 ** 16;
    uint256 public immutable WINDOW = 72;
    uint256 public immutable DECIMALS = 18;

    address public factoryAddr;
    string public market;
    string public rules;
    uint256 public startAt;
    uint256 public endAt;
    uint8 public outcome;
    uint8 public totalOutcomes;
    uint64 public minimumBalance;
    uint256 public totalFeeCollected;
    uint256 public totalNetBalance;
    uint64 public totalShares;
    uint16 public nextAppealId;
    mapping(uint8 => string) public outcomes;
    mapping(uint8 => uint64) public outcomeShares;
    mapping(uint8 => uint256) public outcomeWeight; // Weight only matters in a particular outcome upon which reward is distributed among winners
    mapping(uint8 => uint256) public outcomeNetBalance;
    mapping(address => uint8) public outcomeOf;
    mapping(address => uint64) public balanceOf;
    mapping(address => uint256) public balanceOfWithoutFee;
    mapping(address => uint256) public weightOf;
    mapping(address => uint256) public rewardOf;
    mapping(address => uint16) public appealOf;
    mapping(uint16 => Appeal) public appeals;
    mapping(uint8 => uint64) public protocolVotes;
    mapping(address => ProtocolVote) public addressProtocolVote;

    struct Appeal {
        string reason;
        address trader;
        uint64 amountAtStake;
    }

    struct ProtocolVote {
        bool voted;
        uint8 outcome;
        uint64 amount;
    }

    modifier isFactory() {
        require(msg.sender == factoryAddr, "Not authorized");
        _;
    }

    constructor(
        address _trader, 
        string memory _market, 
        string memory _rules, 
        uint256 _days, 
        string[] memory _outcomes, 
        uint64 _minimumBalance, 
        uint8 _outcome, 
        uint64 _amount
    ) payable {
        require(bytes(_market).length <= 100, "Out of bound");
        require(bytes(_rules).length <= 2 ** 13, "Out of bound");
        require(_days > 7, "Not enough time");
        hyperLendGateway = ILend(hyperLendGatewayAddr);
        whypePool = IWhypePool(whypePoolAddr);
        whypeToken = IERC20(whypePoolAddr);
        factoryAddr = msg.sender;
        market = _market;
        rules = _rules;
        startAt = block.timestamp;
        endAt = startAt + _days * 1 days;
        totalOutcomes = uint8(_outcomes.length);
        for (uint8 i = 1; i <= totalOutcomes; i++) {
            outcomes[i] = _outcomes[i - 1];
        }
        minimumBalance = _minimumBalance;
        nextAppealId = 1;
        _deposit(_trader, _outcome, _amount);
    }

    function contractAddress() public view returns (address) {
        return address(this);
    }

    function currentTicketPrice() public view returns (uint256) {
        uint256 _marketDuration = endAt - startAt;
        uint256 _currentPosition = block.timestamp - startAt;
        return TICKET * (_marketDuration - _currentPosition) / _marketDuration;
    }

    function prizePool() public view returns (uint256) {
        if (resolved() && outcome != 0) return whypePool.balanceOf(address(this)) - outcomeNetBalance[outcome];
        if (resolved() && outcome == 0) return 0;
        return whypePool.balanceOf(address(this)) - totalNetBalance;
    }

    /// The function both takes into consideration of the market before and after resolved
    function outcomeProbability(uint8 _outcome) public view returns (uint64) {
        if (outcome != 0) {
            if (_outcome == outcome) {
                return 100;
            } else {
                return 0;
            }
        }
        return outcomeShares[_outcome] * 100 / totalShares;
    }

    function resolved() public view returns (bool) {
        if (block.timestamp >= endAt) return true;
        return false;
    }

    function resolvedToDaysHoursMinutes() public view returns (uint256, uint256, uint256) {
        if (endAt > block.timestamp) {
            uint256 _remaining = endAt - block.timestamp;
            return (_remaining / 1 days, (_remaining / 1 hours) % 24, (_remaining / 1 minutes) % 60);
        }
        return (0, 0, 0);
    }

    function hoursToWinnerWithdraw() public view returns (uint256) {
        if (endAt + WINDOW * 1 hours > block.timestamp) {
            uint256 _remaining = endAt + WINDOW * 1 hours - block.timestamp;
            return (_remaining + 1 hours - 1) / 1 hours; // take into consideration of 1 hour left
        }
        return 0;
    }

    function getAppeal(uint16 _appealId) public view returns (string memory, address, uint64) {
        return (appeals[_appealId].reason, appeals[_appealId].trader, appeals[_appealId].amountAtStake);
    }

    function getAddressProtocolVote(address _trader) public view returns (bool, uint8, uint64) {
        return (addressProtocolVote[_trader].voted, addressProtocolVote[_trader].outcome, addressProtocolVote[_trader].amount);
    }

    function deposit(address _trader, uint8 _outcome, uint64 _amount) external payable nonReentrant isFactory {
        require(outcomeOf[_trader] == 0 || outcomeOf[_trader] == _outcome, "Switch your outcome first");
        _deposit(_trader, _outcome, _amount);
    }

    /// Traders can only stand with one outcome at a time.
    /// The protocol encourages earlier entries.
    function _deposit(address _trader, uint8 _outcome, uint64 _amount) internal {
        require(resolved() == false, "resolved");
        require(_outcome > 0 && _outcome <= totalOutcomes, "Out of bound");
        if (outcomeOf[_trader] == 0) {
            outcomeOf[_trader] = _outcome;
        }
        totalShares += _amount;
        outcomeShares[_outcome] += _amount;
        uint64 _previousBalance = balanceOf[_trader];
        balanceOf[_trader] += _amount;
        
        if (weightOf[_trader] == 0) { // only record the initial deposit
            uint256 _timeWeight = endAt - block.timestamp;
            weightOf[_trader] = _timeWeight;
            outcomeWeight[_outcome] += _timeWeight;
        }

        uint256 _totalFee = FEE;
        if (_previousBalance == 0) {
            _totalFee += currentTicketPrice();
        }
        uint256 _amountInWei = uint256(_amount) * 10 ** DECIMALS;
        balanceOfWithoutFee[_trader] += _amountInWei - _totalFee;
        outcomeNetBalance[_outcome] += _amountInWei - _totalFee;
        totalNetBalance += _amountInWei - _totalFee;
        totalFeeCollected += _totalFee;
        hyperLendGateway.depositETH{value: _amountInWei}(whypeTokenAddr, address(this), 0);
    }

    function switchToOutcome(address _trader, uint8 _outcome) external payable nonReentrant isFactory {
        require(resolved() == false, "resolved");
        require(outcomeOf[_trader] != _outcome, "current outcomeOf");
        uint8 _lastOutcomeOf = outcomeOf[_trader];
        outcomeShares[_lastOutcomeOf] -= balanceOf[_trader];
        outcomeWeight[_lastOutcomeOf] -= weightOf[_trader];

        outcomeNetBalance[_lastOutcomeOf] -= balanceOfWithoutFee[_trader];
        outcomeNetBalance[_outcome] += balanceOfWithoutFee[_trader];

        outcomeOf[_trader] = _outcome;
        outcomeShares[_outcome] += balanceOf[_trader];
        
        uint256 _timeWeight = endAt - block.timestamp;
        weightOf[_trader] = _timeWeight;
        outcomeWeight[_outcome] += _timeWeight;

        totalFeeCollected += msg.value;
        hyperLendGateway.depositETH{value: msg.value}(whypeTokenAddr, address(this), 0);
    }

    function withdraw(address _trader) external nonReentrant isFactory returns (bool deactivating, uint64 balance) {
        require(balanceOf[_trader] != 0, "No balance");
        // Here, we shouldn't change other values besides balanceOf in case of resolved
        // If protocol votes outcome 0 for uncertainty of outcome
        // outcomeProbability() will still leave the shares as they are
        uint64 _shares = balanceOf[_trader];
        balanceOf[_trader] = 0;
        uint256 _balanceInWei = balanceOfWithoutFee[_trader];
        balanceOfWithoutFee[_trader] = 0;
        uint8 _outcome = outcomeOf[_trader];
        if (resolved()) {
            require(hoursToWinnerWithdraw() == 0, "Window");
            if (nextAppealId == 1) {
                if (outcome == 0) {
                    uint64 _outcomeShares = outcomeShares[_outcome];
                    for (uint8 i = 1; i <= totalOutcomes; i++) {
                        if (outcomeShares[i] > _outcomeShares) {
                            revert notOutcome();
                        }
                    }
                    outcome = _outcome;
                }
            } else {
                uint64 _highestShares;
                uint8 _highestOutcome;
                uint8 _count;
                for (uint8 i = 1; i <= totalOutcomes; i++) {
                    if (outcomeShares[i] == _highestShares) {
                        _count++;
                    }
                    if (outcomeShares[i] > _highestShares) {
                        _highestShares = outcomeShares[i];
                        _highestOutcome = i;
                        _count = 1;
                    }
                }
                if (_count == 1) {
                    if (protocolVotes[0] > _highestShares) {
                        outcome = 0;
                    } else {
                        outcome = _highestOutcome;
                    }
                }
                if (_count > 1) {
                    uint8 _protocolCount;
                    for (uint8 i = 1; i <= totalOutcomes; i++) {
                        uint64 _votes = protocolVotes[i] + outcomeShares[i];
                        if (_votes == _highestShares) {
                            _protocolCount++;
                        }
                        if (_votes > _highestShares) {
                            _highestShares = _votes;
                            _highestOutcome = i;
                            _protocolCount = 1;
                        }
                    }
                    if (_protocolCount == 1) {
                        outcome = _highestOutcome;
                    } else {
                        outcome = 0;
                    }
                }
            }
            if (outcomeOf[_trader] == outcome) {
                uint256 _prize = prizePool();
                outcomeNetBalance[_outcome] -= _balanceInWei;
                uint256 _reward = weightOf[_trader] * _prize / outcomeWeight[outcome];
                outcomeWeight[outcome] -= weightOf[_trader];
                rewardOf[_trader] = _reward;
                whypeToken.approve(hyperLendGatewayAddr, _reward + _balanceInWei);
                hyperLendGateway.withdrawETH(whypeTokenAddr, _reward + _balanceInWei, _trader);
                return (true, _shares);
            }
            if (outcome == 0) {
                _balanceInWei = uint256(_shares) * 10 ** DECIMALS;
                whypeToken.approve(hyperLendGatewayAddr, _balanceInWei);
                hyperLendGateway.withdrawETH(whypeTokenAddr, _balanceInWei, _trader);
                return (true, _shares);
            }
            return (true, _shares);
        }

        totalShares -= _shares;
        outcomeOf[_trader] = 0;
        outcomeShares[_outcome] -= _shares;

        uint256 _weight = weightOf[_trader];
        weightOf[_trader] = 0;
        outcomeWeight[_outcome] -= _weight;

        outcomeNetBalance[_outcome] -= _balanceInWei;
        totalNetBalance -= _balanceInWei;
        _balanceInWei = _balanceInWei - FEE;
        totalFeeCollected += FEE;
        whypeToken.approve(hyperLendGatewayAddr, _balanceInWei);
        hyperLendGateway.withdrawETH(whypeTokenAddr, _balanceInWei, _trader);
        return (false, _shares);
    }

    function delist() external isFactory {
        outcome = totalOutcomes + 1;
    }

    function appeal(address _trader, string memory _reason) external isFactory {
        require(resolved() && hoursToWinnerWithdraw() != 0, "Expired");
        require(bytes(_reason).length >= 100 && bytes(_reason).length <= 1000, "Out of bound");
        uint8 _traderOutcome = outcomeOf[_trader];
        uint64 _outcomeShares = outcomeShares[_traderOutcome];
        uint8 _count;
        for (uint8 i = 1; i <= totalOutcomes; i++) {
            if (_outcomeShares <= outcomeShares[i]) _count++;
        }
        if (_count == 1) revert winningOutcome();

        uint16 _currentAppealId;
        if (appealOf[_trader] == 0) {
            _currentAppealId = nextAppealId;
            nextAppealId++;
        } else {
            _currentAppealId = appealOf[_trader];
        }
        appealOf[_trader] = _currentAppealId;
        appeals[_currentAppealId].reason = _reason;
        appeals[_currentAppealId].trader = _trader;
        appeals[_currentAppealId].amountAtStake = balanceOf[_trader];
    }

    function protocolVote(address _trader, uint8 _outcome, uint64 _amount) external nonReentrant isFactory {
        require(resolved() && hoursToWinnerWithdraw() != 0, "Unavailable");
        require(_outcome >= 0 && _outcome <= totalOutcomes, "Out of bound");
        require(nextAppealId != 1, "No dispute");
        ProtocolVote memory _protocolVote = addressProtocolVote[_trader];
        if (_protocolVote.voted) {
            protocolVotes[_protocolVote.outcome] -= _protocolVote.amount;
        }
        protocolVotes[_outcome] += _amount;
        addressProtocolVote[_trader].voted = true;
        addressProtocolVote[_trader].outcome = _outcome;
        addressProtocolVote[_trader].amount = _amount;
    }

    error notOutcome();
    error winningOutcome();
}

contract Clouded is ReentrancyGuard {
    uint64 public totalBalance;
    address[] public activeMarkets;
    uint64 public nextMarketId;
    mapping(uint64 => address) public marketAddr;
    mapping(address => bool) public isActive;
    mapping(address => uint64) public votesToDelist;
    mapping(address => address[]) public hasBalanceOf;
    mapping(address => uint64) public balanceOf;
    mapping(address => mapping(address => uint64)) public addressHasVotedToDelist;
    uint256 public immutable DECIMALS = 18;

    modifier isActiveMarket(address _marketAddr) {
        require(isActive[_marketAddr], "Not active");
        _;
    }

    constructor() {}

    function getCurrentMinimumBalance() public view returns (uint64) {
        if (totalBalance / 100 > 100) return totalBalance / 100;
        return 100;
    }

    function getMarketMinimumBalance(address _marketAddr) public view returns (uint64) {
        IMarket _market = IMarket(_marketAddr);
        return _market.minimumBalance();
    }

    function createMarket(
        string memory _name, 
        string memory _rules, 
        uint256 _days, 
        string[] memory _outcomes, 
        uint8 _outcome, 
        uint64 _amount
    ) public payable nonReentrant {
        uint256 _amountInWei = uint256(_amount) * 10 ** DECIMALS;
        require(msg.value == _amountInWei, "Must equivalent");
        Market _market = new Market{value: _amountInWei}(
            msg.sender, 
            _name, 
            _rules, 
            _days, 
            _outcomes, 
            getCurrentMinimumBalance(), 
            _outcome, 
            _amount
        );
        nextMarketId++;
        marketAddr[nextMarketId] = address(_market);
        activeMarkets.push(address(_market));
        isActive[address(_market)] = true;
        totalBalance += _amount;
        hasBalanceOf[msg.sender].push(address(_market));
        balanceOf[msg.sender] += _amount;
    }

    function deposit(address _marketAddr, uint8 _outcome, uint64 _amount) public payable nonReentrant isActiveMarket(_marketAddr) {
        uint256 _amountInWei = uint256(_amount) * 10 ** DECIMALS;
        require(msg.value == _amountInWei, "Must equivalent");
        IMarket _market = IMarket(_marketAddr);
        _market.deposit{value: _amountInWei}(msg.sender, _outcome, _amount);
        (bool _has, ) = _getTraderMarketIndexSafe(msg.sender, _marketAddr);
        if (!_has) {
            hasBalanceOf[msg.sender].push(_marketAddr);
        }
        totalBalance += _amount;
        balanceOf[msg.sender] += _amount;
    }

    function switchToOutcome(address _marketAddr, uint8 _outcome) public payable nonReentrant isActiveMarket(_marketAddr) {
        IMarket _market = IMarket(_marketAddr);
        uint256 _fee = _market.FEE();
        require(msg.value == _fee, "Must equivalent");
        _market.switchToOutcome{value: _fee}(msg.sender, _outcome);
    }

    function withdraw(address _marketAddr) public nonReentrant {
        _withdraw(msg.sender, _marketAddr);
    }

    function withdrawFromAllInactiveMarkets() public nonReentrant {
        address[] memory _marketAddrs = hasBalanceOf[msg.sender];
        for (uint256 i = 0; i < _marketAddrs.length; i++) {
            if (!isActive[_marketAddrs[i]]) {
                _withdraw(msg.sender, _marketAddrs[i]);
            }
        }
    }

    function _withdraw(address _trader, address _marketAddr) internal {
        IMarket _market = IMarket(_marketAddr);
        (bool _ended, uint64 _balanceOf) = _market.withdraw(_trader);
        if (_ended && isActive[_marketAddr]) {
            _deactivateMarket(_marketAddr);
        }
        (bool _has, uint256 _index) = _getTraderMarketIndexSafe(_trader, _marketAddr);
        if (_has) {
            hasBalanceOf[_trader][_index] = hasBalanceOf[_trader][hasBalanceOf[_trader].length - 1];
            hasBalanceOf[_trader].pop();
        }
        totalBalance -= _balanceOf;
        balanceOf[_trader] -= _balanceOf;
    }

    function _getTraderMarketIndexSafe(address _trader, address _market) internal view returns (bool has, uint256 index) {
        for (uint256 i = 0; i < hasBalanceOf[_trader].length; i++) {
            if (hasBalanceOf[_trader][i] == _market) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function _deactivateMarket(address _marketAddr) internal {
        isActive[_marketAddr] = false;
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            if (activeMarkets[i] == _marketAddr) {
                activeMarkets[i] = activeMarkets[activeMarkets.length - 1];
                break;
            }
        }
        activeMarkets.pop();
    }

    /// Only those who are on the side of the losing outcome or a draw can appeal
    function appeal(address _marketAddr, string memory _reason) public nonReentrant isActiveMarket(_marketAddr) {
        IMarket _market = IMarket(_marketAddr);
        _market.appeal(msg.sender, _reason);
    }

    function protocolVote(address _marketAddr, uint8 _outcome) public nonReentrant isActiveMarket(_marketAddr) {
        IMarket _market = IMarket(_marketAddr);
        _market.protocolVote(msg.sender, _outcome, balanceOf[msg.sender]);
    }

    function delist(address _marketAddr) public nonReentrant {
        IMarket _market = IMarket(_marketAddr);
        require(_market.resolved() == false, "Market resolved");
        require(balanceOf[msg.sender] != 0, "No balance");
        if (addressHasVotedToDelist[msg.sender][_marketAddr] != 0) {
            votesToDelist[_marketAddr] -= addressHasVotedToDelist[msg.sender][_marketAddr];
        }
        votesToDelist[_marketAddr] += balanceOf[msg.sender];
        addressHasVotedToDelist[msg.sender][_marketAddr] = balanceOf[msg.sender];
        uint64 _minimumBalance = _market.minimumBalance();
        uint64 _totalShares = _market.totalShares();
        if (votesToDelist[_marketAddr] >= totalBalance / 2) {
            if (_totalShares < _minimumBalance) {
                _deactivateMarket(_marketAddr);
                _market.delist();
            }
        }
    }
}