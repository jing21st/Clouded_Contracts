// SPDX-License-Identifier: MIT
// Test Commit

pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IDAO {
    function founderToken() external view returns (IERC20Metadata);
    function token() external view returns (IERC20Metadata);
    function factoryAddr() external view returns (address);
    function pointProgramAddr() external view returns (address);
    function isBlacklisted(uint256) external view returns (bool);
    function getCurrentAccumulatedRevenue(uint256) external view returns (uint256);
    function claim(uint256) external returns (uint256);
    function receiveRevenue() external payable returns (uint256);
}

interface IClouded {
    function nextMarketId() external view returns (uint256);
    function updateURI(string memory) external;
    function receiveRevenue() external payable;
}

interface IPoint {
    function updateCreatorAddr(uint256, address) external;
    function updateBuyPoint(address, uint256, uint256) external;
    function updateSellPoint(address, uint256, uint256) external;
    function activateEpoch(address) external;
}

interface IToken { function mint(address, uint256) external; }

library UserMarket {
    struct Set {
        uint256[] ids;
        mapping(uint256 => uint256) positions;
    }

    function add(Set storage set, uint256 _marketId) internal {
        if (set.positions[_marketId] == 0) {
            set.ids.push(_marketId);
            set.positions[_marketId] = set.ids.length; // skip index 0 for non existing element
        }
    }

    function remove(Set storage set, uint256 _marketId) internal {
        uint256 _position = set.positions[_marketId];
        if (_position != 0) {
            uint256 _index = _position - 1;
            uint256 _lastIndexId = set.ids[set.ids.length - 1];
            set.ids[_index] = _lastIndexId;
            set.positions[_lastIndexId] = _position;
            set.ids.pop();
            delete set.positions[_marketId];
        }
    }

    function getAll(Set storage set) internal view returns (uint256[] memory) { return set.ids; }
}

library UserAddr {
    struct Set {
        address[] addrs;
        mapping(address => uint256) positions;
    }

    function add(Set storage set, address _addr) internal {
        if (set.positions[_addr] == 0) {
            set.addrs.push(_addr);
            set.positions[_addr] = set.addrs.length;
        }
    }

    function remove(Set storage set, address _addr) internal {
        uint256 _position = set.positions[_addr];
        if (_position != 0) {
            uint256 _index = _position - 1;
            address _lastIndexAddr = set.addrs[set.addrs.length - 1];
            set.addrs[_index] = _lastIndexAddr;
            set.positions[_lastIndexAddr] = _position;
            set.addrs.pop();
            delete set.positions[_addr];
        }
    }

    function getLength(Set storage set) internal view returns (uint256) { return set.addrs.length; }

    function getAddrs(Set storage set, uint256 _offset, uint256 _limit) internal view returns (address[] memory addrs) {
        uint256 _totalAddrs = set.addrs.length;
        if (_offset >= _totalAddrs) return new address[](0);

        uint256 _end = _offset + _limit > _totalAddrs ? _totalAddrs : _offset + _limit;
        uint256 _len = _end - _offset;
        addrs = new address[](_len);
        for (uint256 i = 0; i < _len; i++) {
            addrs[i] = set.addrs[_offset + i];
        }
    }
}

contract CloudedFounderToken is ERC20 { constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) { _mint(msg.sender, 1e8 * 10 ** decimals()); } }

contract CloudedDAO is ReentrancyGuardTransient {
    using UserMarket for UserMarket.Set;
    using UserAddr for UserAddr.Set;

    event Stake(address indexed voter, uint256 indexed marketId, uint256 amount);
    event Unstake(address indexed voter, uint256 indexed marketId, uint256 amount);
    event FounderStake(uint256 indexed marketId, uint256 amount);
    event FounderUnstake(uint256 indexed marketId, uint256 amount);
    event Blacklist(uint256 indexed marketId, bool blacklisted);
    event Claim(uint256 indexed marketId, uint256 reward);
    event ReceiveRevenue(uint256 rewardPerTokenAt, uint256 undistributedReward);

    // Founder token is the holder token before initial token launch. But even after token launch, 
    // the founder token is still useful for the team to claim tokens and update the erc1155 token uri
    IERC20Metadata public token;
    IERC20Metadata public founderToken;
    address public factoryAddr;
    address public pointProgramAddr;

    uint256 public totalStaked; // the amounts represent the total deposits and votes of the DAO
    uint256 public rewardPerTokenAt;
    uint256 public undistributedReward;

    // Markets info
    mapping(uint256 => uint256) public marketStakeOf;
    mapping(uint256 => uint256) public rewardPerTokenFrom;
    mapping(uint256 => uint256) public accumulatedRewardOf;
    UserMarket.Set private stakedMarkets_;
    UserMarket.Set private blacklisted_;

    // Stakers info
    mapping(address => mapping(uint256 => uint256)) public stakeOf;
    mapping(address => UserMarket.Set) private marketIds_;
    UserAddr.Set private stakerAddrs_; // used to track founder stakes

    modifier inBound(uint256 _marketId) {
        uint256 _nextMarketId = IClouded(factoryAddr).nextMarketId();
        require(_marketId > 0 && _marketId < _nextMarketId, "MarketId out of bound");
        _;
    }

    modifier beforeTokenLaunch() {
        require(address(token) == address(0), "Token is launched");
        _;
    }

    modifier isFounderTokenHalfOf() {
        require(founderToken.balanceOf(msg.sender) > founderToken.totalSupply() / 2, "Not authorized");
        _;
    }

    modifier isFactory() {
        require(msg.sender == factoryAddr, "Not authorized");
        _;
    }

    constructor(address _founderTokenAddr) { founderToken = IERC20Metadata(_founderTokenAddr); }

    // Used for getting all founder staked markets before token initial launch
    function getAllStakedMarket() external view returns (uint256[] memory) { return stakedMarkets_.getAll(); }

    function getAllStakedInfo(uint256[] calldata _marketIds) external view returns (uint256[] memory marketStakes) {
        uint256 _marketLength = _marketIds.length;
        marketStakes = new uint256[](_marketLength);
        for (uint256 i = 0; i < _marketLength; i++) {
            uint256 _marketId = _marketIds[i];
            marketStakes[i] = marketStakeOf[_marketId];
        }
    }

    function getStakerMarket(address _addr) external view returns (uint256[] memory) { return marketIds_[_addr].getAll(); }

    function getStakerInfo(address _addr, uint256[] calldata _marketIds) external view returns (uint256[] memory, uint256[] memory) {
        uint256 _marketLength = _marketIds.length;
        uint256[] memory _marketBalances = new uint256[](_marketLength);
        uint256[] memory _balances = new uint256[](_marketLength);

        for (uint256 i = 0; i < _marketLength; i++) {
            uint256 _marketId = _marketIds[i];
            _marketBalances[i] = marketStakeOf[_marketId];
            _balances[i] = stakeOf[_addr][_marketId];
        }

        return (_marketBalances, _balances);
    }

    function getBlacklistedMarket() external view returns (uint256[] memory) { return blacklisted_.getAll(); }

    function isBlacklisted(uint256 _marketId) external view returns (bool) {
        uint256 _position = blacklisted_.positions[_marketId];
        if (_position == 0) return false;
        return true;
    }

    function getCurrentAccumulatedRevenue(uint256 _marketId) external view returns (uint256) {
        uint256 _pending = (rewardPerTokenAt - rewardPerTokenFrom[_marketId]) * marketStakeOf[_marketId];
        return accumulatedRewardOf[_marketId] + _pending;
    }

    function stake(uint256 _marketId, uint256 _amount) public nonReentrant inBound(_marketId) {
        uint256 _amountInWei = _amount * 10 ** token.decimals();
        require(_amountInWei > 0, "Please enter amount");
        require(token.balanceOf(msg.sender) >= _amountInWei, "Insufficient balance");

        token.transferFrom(msg.sender, address(this), _amountInWei);

        _stake(_marketId, _amount);

        emit Stake(msg.sender, _marketId, _amount);
    }

    function unstake(uint256 _marketId, uint256 _amount) public nonReentrant inBound(_marketId) {
        uint256 _amountInWei = _amount * 10 ** token.decimals();
        require(_amountInWei > 0, "Please enter amount");

        require(marketStakeOf[_marketId] >= _amount, "Market insufficient balance");
        require(stakeOf[msg.sender][_marketId] >= _amount, "Insufficient balance");

        _unstake(_marketId, _amount);

        token.transfer(msg.sender, _amountInWei);

        emit Unstake(msg.sender, _marketId, _amount);
    }

    function _stake(uint256 _marketId, uint256 _amount) private {
        _settle(_marketId);

        totalStaked += _amount;
        marketStakeOf[_marketId] += _amount;
        stakeOf[msg.sender][_marketId] += _amount;

        stakedMarkets_.add(_marketId);
        marketIds_[msg.sender].add(_marketId);
    }

    function _unstake(uint256 _marketId, uint256 _amount) private {
        _settle(_marketId);

        totalStaked -= _amount;
        marketStakeOf[_marketId] -= _amount;
        stakeOf[msg.sender][_marketId] -= _amount;

        if (marketStakeOf[_marketId] == 0) stakedMarkets_.remove(_marketId);
        if (stakeOf[msg.sender][_marketId] == 0) marketIds_[msg.sender].remove(_marketId);
    }

    function founderStake(uint256 _marketId, uint256 _amount) public nonReentrant beforeTokenLaunch inBound(_marketId) {
        uint256 _amountInWei = _amount * 10 ** founderToken.decimals();
        require(_amountInWei > 0, "Please enter amount");
        require(founderToken.balanceOf(msg.sender) >= _amountInWei, "Insufficient balance");

        _stake(_marketId, _amount);
        stakerAddrs_.add(msg.sender);

        founderToken.transferFrom(msg.sender, address(this), _amountInWei);

        emit FounderStake(_marketId, _amount);
    }

    function founderUnstake(uint256 _marketId, uint256 _amount) public nonReentrant beforeTokenLaunch inBound(_marketId) {
        uint256 _amountInWei = _amount * 10 ** founderToken.decimals();
        require(_amountInWei > 0, "Please enter amount");

        require(marketStakeOf[_marketId] >= _amount, "Market insufficient balance");
        require(stakeOf[msg.sender][_marketId] >= _amount, "Insufficient balance");

        _unstake(_marketId, _amount);
        if (marketIds_[msg.sender].ids.length == 0) stakerAddrs_.remove(msg.sender);

        founderToken.transfer(msg.sender, _amountInWei);

        emit FounderUnstake(_marketId, _amount);
    }

    function updateFactoryAddr(address _factoryAddr) public nonReentrant beforeTokenLaunch isFounderTokenHalfOf {
        require(factoryAddr == address(0), "Already updated");
        factoryAddr = _factoryAddr;
    }

    function updatePointProgramAddr(address _pointProgramAddr) public nonReentrant beforeTokenLaunch isFounderTokenHalfOf {
        require(pointProgramAddr == address(0), "Already updated");
        pointProgramAddr = _pointProgramAddr;
    }

    // This function should be called when after the founder token is updated and unstaked
    function clearAddr(uint256 _offset, uint256 _limit) public nonReentrant beforeTokenLaunch isFounderTokenHalfOf {
        uint256 _maxAddrLength = stakerAddrs_.getLength();
        if (_limit > _maxAddrLength) _limit = _maxAddrLength;
        address[] memory _addrs = stakerAddrs_.getAddrs(_offset, _limit);
        for (uint256 i = 0; i < _addrs.length; i++) {
            uint256[] memory _marketIds = marketIds_[_addrs[i]].getAll();
            _clearMarket(_addrs[i], _marketIds);
            stakerAddrs_.remove(_addrs[i]);
        }
    }

    function clearAddrMarket(address _addr, uint256 _limit) public nonReentrant beforeTokenLaunch isFounderTokenHalfOf {
        uint256 _total = marketIds_[_addr].ids.length;
        if (_limit > _total) _limit = _total;
        uint256[] memory _subset = new uint256[](_limit);
        for (uint256 i = 0; i < _limit; i++) { _subset[i] = marketIds_[_addr].ids[i]; }
        _clearMarket(_addr, _subset);
        if (_limit == _total) stakerAddrs_.remove(_addr);
    }

    function _clearMarket(address _addr, uint256[] memory _marketIds) private {
        for (uint256 j = 0; j < _marketIds.length; j++) {
            uint256 _marketId = _marketIds[j];
            _settle(_marketId);
            uint256 _stakeOf = stakeOf[_addr][_marketId];
            totalStaked -= _stakeOf;
            marketStakeOf[_marketId] -= _stakeOf;
            if (marketStakeOf[_marketId] == 0) stakedMarkets_.remove(_marketId);
            stakeOf[_addr][_marketId] -= _stakeOf;
            marketIds_[_addr].remove(_marketId);
        }
    }

    // In case one of the team members private key is leaked
    function emergencyUpdateFounderToken(address _founderTokenAddr) public nonReentrant isFounderTokenHalfOf { founderToken = IERC20Metadata(_founderTokenAddr); }

    function updateURI(string memory _uri) public nonReentrant isFounderTokenHalfOf { IClouded(factoryAddr).updateURI(_uri); }

    // Token will be updated both for the DAO contract and the point program contract
    // The function is expected only called once and the point contract will revert
    // Unstake all founder token before calling or they will be locked
    function launchToken(address _tokenAddr) public nonReentrant isFounderTokenHalfOf {
        require(totalStaked == 0, "Founder token still staked");
        token = IERC20Metadata(_tokenAddr);
        IPoint(pointProgramAddr).activateEpoch(_tokenAddr);
    }

    // The function can be used conveniently for frontend purpose
    function blacklist(uint256 _marketId, bool _blacklist) public nonReentrant {
        require(founderToken.balanceOf(msg.sender) > founderToken.totalSupply() / 3, "Not authorized");
        if (_blacklist) blacklisted_.add(_marketId);
        if (!_blacklist) blacklisted_.remove(_marketId);
        emit Blacklist(_marketId, _blacklist);
    }

    // MarketId is checked by the factoryAddr
    function claim(uint256 _marketId) external nonReentrant isFactory returns (uint256 reward) {
        _settle(_marketId);

        reward = accumulatedRewardOf[_marketId];
        accumulatedRewardOf[_marketId] = 0;

        IClouded(factoryAddr).receiveRevenue{value: reward}();

        emit Claim(_marketId, reward);
    }

    // Through undistributedReward, the function will save dust for next distribution
    function receiveRevenue() external payable nonReentrant isFactory returns (uint256 revenue) {
        revenue = msg.value;
        undistributedReward += revenue;

        if (totalStaked > 0) {
            rewardPerTokenAt += undistributedReward / totalStaked;
            undistributedReward = undistributedReward % totalStaked;
        }

        emit ReceiveRevenue(rewardPerTokenAt, undistributedReward);
    }

    function _settle(uint256 _marketId) private {
        uint256 _pending = (rewardPerTokenAt - rewardPerTokenFrom[_marketId]) * marketStakeOf[_marketId];
        accumulatedRewardOf[_marketId] += _pending;
        rewardPerTokenFrom[_marketId] = rewardPerTokenAt;
    }

    receive() external payable { revert("Direct transfer not allowed"); }

    fallback() external payable { revert("Direct transfer not allowed"); }
}

contract MultisigWallet is ReentrancyGuardTransient {

    IERC20Metadata public token;
    address[] public owners;
    uint256 public requiredSigns;
    bool public locked;

    mapping(address => Proposal) public proposalOf;
    mapping(address => address) public hasSigned;
    mapping(address => bool) public isOwner;

    enum ActionType { None, Withdraw, AddOwner, RemoveOwner, Locked }

    struct Proposal {
        ActionType actionType;
        address to;          // Withdraw: received address / AddOwner: new address / RemoveOwner: to be removed address
        uint256 amount;      // Withdraw: amount
        uint256 signCount;
    }

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not owner");
        _;
    }

    constructor(address _tokenAddr, address[] memory _owners) {
        token = IERC20Metadata(_tokenAddr);
        for (uint256 i = 0; i < _owners.length; i++) {
            owners.push(_owners[i]);
            isOwner[_owners[i]] = true;
        }
        requiredSigns = _owners.length - 1;
    }

    function deposit(uint256 _amount) public nonReentrant onlyOwner {
        uint256 _amountInWei = _amount * 10 ** token.decimals();
        token.transferFrom(msg.sender, address(this), _amountInWei);
    }

    function propose(ActionType _type, address _to, uint256 _amount) public nonReentrant onlyOwner {
        _withdrawProposal(); // the hasSign and signCount must both be cleared before an owner makes a new proposal

        proposalOf[msg.sender] = Proposal({ actionType: _type, to: _to, amount: _amount, signCount: 0 });

        address _previousSign = hasSigned[msg.sender];
        hasSigned[msg.sender] = msg.sender;
        _settle(_previousSign, msg.sender);
    }

    function withdrawProposal() public nonReentrant onlyOwner {
        _withdrawProposal();
    }

    function _withdrawProposal() internal {
        for (uint256 i = 0; i < owners.length; i++) { if (hasSigned[owners[i]] == msg.sender) hasSigned[owners[i]] = address(0); }
        delete proposalOf[msg.sender];
    }

    function sign(address _proposerAddr, ActionType _type) public nonReentrant onlyOwner {
        require(isOwner[_proposerAddr], "Not authorized");
        require(proposalOf[_proposerAddr].actionType != ActionType.None, "Currently no proposal");
        require(proposalOf[_proposerAddr].actionType == _type, "ActionType not matched");

        address _previousSign = hasSigned[msg.sender];
        hasSigned[msg.sender] = _proposerAddr;
        _settle(_previousSign, _proposerAddr);

        if (proposalOf[_proposerAddr].signCount >= requiredSigns) _execute(_proposerAddr);
    }

    function _settle(address _previousSign, address _newSign) private {
        if (_previousSign != address(0)) proposalOf[_previousSign].signCount--;
        proposalOf[_newSign].signCount++;
    }

    function _execute(address _addr) private {
        ActionType _type = proposalOf[_addr].actionType;
        address _to = proposalOf[_addr].to;
        uint256 _amount = proposalOf[_addr].amount;

        _clearAllProposal();

        if (_type == ActionType.Withdraw) {
            require(!locked, "Fund locked");
            uint256 _amountInWei = _amount * 10 ** token.decimals();
            require(token.balanceOf(address(this)) >= _amountInWei, "Insufficient balance");
            token.transfer(_to, _amountInWei);
        }

        if (_type == ActionType.AddOwner) {
            require(!isOwner[_to], "Already owner");
            owners.push(_to);
            isOwner[_to] = true;
        }

        if (_type == ActionType.RemoveOwner) {
            require(isOwner[_to], "Not owner");
            require(owners.length - 1 >= requiredSigns, "Would break quorum");
            for (uint256 i = 0; i < owners.length; i++) {
                if (owners[i] == _to) {
                    owners[i] = owners[owners.length - 1];
                    owners.pop();
                    break;
                }
            }
            isOwner[_to] = false;
        }

        if (_type == ActionType.Locked) {
            locked = true;
        }
    }

    function _clearAllProposal() private {
        for (uint256 i = 0; i < owners.length; i++) {
            hasSigned[owners[i]] = address(0);
            delete proposalOf[owners[i]];
        }
    }
}

contract Clouded is ERC1155, ReentrancyGuardTransient {
    using UserMarket for UserMarket.Set;
    
    event CreateMarket(
        address indexed creator, 
        uint256 indexed marketId, 
        string name, 
        string description, 
        uint256 shares, 
        uint256 executionPrice, 
        uint256 marketCurrentPrice
    );

    event BuyShare(
        address indexed buyer, 
        uint256 indexed marketId, 
        uint256 shares, 
        uint256 executionPrice, 
        uint256 slippageBPS, 
        uint256 msgValue, 
        uint256 refund, 
        uint256 marketFeePerShareAt, 
        uint256 marketCurrentPrice
    );

    event SellShare(
        address indexed seller, 
        uint256 indexed marketId, 
        uint256 shares, 
        uint256 slippageBPS
    );

    event SellerNetProfit(
        uint256 indexed marketId, 
        address indexed seller, 
        uint256 refund, 
        uint256 feeReward, // traders first rewarded by current marketFee
        uint256 tradingFee, // then traders pay to marketFee
        uint256 Payout
    );

    event FeeStack(
        uint256 indexed marketId, 
        uint256 sentinelReward, // extract a little amount from the trading fee
        uint256 protocolRevenue, // then a fee back to the protocol
        uint256 marketLastUndistributedFee, // fee collected in last sell
        uint256 marketFeePerShareAt, 
        uint256 marketCurrentPrice
    );

    uint256 constant B = 100; // slope of the bonding curve
    uint256 constant SENTINEL = 20;
    uint256 constant DECIMALS = 1e18;
    address constant DAO = 0xB3690c850d5a4Bc0b7eB1Aa952D3c6854cacad99;

    // Overall market conditions
    uint256 public totalShares; // total hypes deposited by traders
    uint256 public nextMarketId;
    uint256 public sentiment;
    uint256 public lastUpdatedAt; // last time minimum balance is updated

    // Current market conditions
    mapping(uint256 => Market) public markets;
    mapping(uint256 => uint256) public marketFeePerShareAt;
    mapping(uint256 => uint256) private marketUndistributedFee_;
    mapping(uint256 => Share[]) private shareStack_;

    // Track active markets for the entire protocol and traders
    UserMarket.Set private activeMarkets_;
    mapping(address => UserMarket.Set) private marketIds_;

    // Track epoch active market id and buying shares for updating Sentiment
    uint256 private nextEpochId_;
    uint256 private epochActiveMarketShares_;
    mapping(uint256 => UserMarket.Set) private epochActiveMarkets_;

    // Track traders average buy price
    mapping(address => mapping(uint256 => BuyPrice)) private buyPriceOf_;

    struct Market {
        string name;
        string description;
        uint256 totalShares;
    }

    struct Share {
        uint256 amount;
        uint256 feePerShareFrom;
        uint256 timestamp;
    }

    struct BuyPrice{
        uint256 amount;
        uint256 avgPrice;
    }

    modifier inBound(uint256 _marketId) {
        require(_marketId > 0 && _marketId < nextMarketId, "MarketId out of bound");
        _;
    }

    modifier isBuySell(uint256 _shares, uint256 _slippageBPS) {
        require(_shares > 0, "Share zero");
        require(_slippageBPS <= 2000, "Exceed max slippage");
        _;
    }

    modifier isDAO() {
        require(msg.sender == DAO, "Not authorized");
        _;
    }

    constructor(string memory _uri) ERC1155(_uri) {
        nextMarketId = 1;
        lastUpdatedAt = block.timestamp;
    }

    function getSentimentUpdateCountdown() external view returns (uint256, uint256, uint256) {
        uint256 _nextUpdateTimestamp = lastUpdatedAt + 12 hours;
        if (block.timestamp > _nextUpdateTimestamp) return (0, 0, 0);
        uint256 _timeLeft = _nextUpdateTimestamp - block.timestamp;
        uint256 _hours = _timeLeft / 1 hours;
        uint256 _minutes = _timeLeft / 1 minutes % 60;
        uint256 _seconds = _timeLeft / 1 seconds % 60;
        return (_hours, _minutes, _seconds);
    }

    function getNextSentiment() external view returns (int8) {
        uint256 _totalMarketLength = epochActiveMarkets_[nextEpochId_].ids.length;
        uint256 _weightedShares;
        if (_totalMarketLength != 0) _weightedShares = epochActiveMarketShares_ / _totalMarketLength;
        if (_weightedShares > sentiment) return 1;
        if (_weightedShares < sentiment) return -1;
        return 0;
    }

    // These functions are used for displaying market info on frontend
    function getActiveMarketIds() external view returns (uint256[] memory) { return activeMarkets_.getAll(); }

    function getActiveMarketPrice(uint256[] calldata _marketIds) external view returns (uint256[] memory prices) {
        prices = new uint256[](_marketIds.length);
        for (uint256 i = 0; i < _marketIds.length; i++) { prices[i] = (10000 + B * markets[_marketIds[i]].totalShares) * DECIMALS / 10000; }
    }

    function getActiveMarketName(uint256[] calldata _marketIds) external view returns (string[] memory names) {
        names = new string[](_marketIds.length);
        for (uint256 i = 0; i < _marketIds.length; i++) { names[i] = markets[_marketIds[i]].name; }
    }

    function getActiveMarketDescription(uint256 _marketId) external view returns (string memory) { return markets[_marketId].description; }

    function getMarketUndistributedReward(uint256 _marketId) external view returns (uint256 totalUndistributedReward) {
        uint256 _protocolRevenue = IDAO(DAO).getCurrentAccumulatedRevenue(_marketId);
        totalUndistributedReward = _protocolRevenue + marketUndistributedFee_[_marketId];
    }

    function getMarketFeeStack(uint256 _marketId) external view returns (uint256[] memory feeAmounts, uint256[] memory feePerShares) {
        Share[] storage shares = shareStack_[_marketId];
        feeAmounts = new uint256[](shares.length);
        feePerShares = new uint256[](shares.length);
        uint256 _fps = marketFeePerShareAt[_marketId];
        for (uint256 i = 0; i < shares.length; i++) {
            feeAmounts[i] = shares[i].amount;
            feePerShares[i] = _fps - shares[i].feePerShareFrom;
        }
    }

    // These functions are used for displaying trader info on frontend
    function getTraderMarketIds(address _addr) external view returns (uint256[] memory) { return marketIds_[_addr].getAll(); }

    function getTraderMarketInfo(address _addr, uint256[] calldata _marketIds) external view returns (
        string[] memory marketNames, 
        uint256[] memory marketPrices, 
        uint256[] memory avgPrices, 
        uint256[] memory balances
    ) {
        marketNames = new string[](_marketIds.length);
        marketPrices = new uint256[](_marketIds.length);
        avgPrices = new uint256[](_marketIds.length);
        balances = new uint256[](_marketIds.length);

        for (uint256 i = 0; i < _marketIds.length; i++) {
            Market storage market = markets[_marketIds[i]];
            marketNames[i] = market.name;
            marketPrices[i] = (10000 + B * market.totalShares) * DECIMALS / 10000;
            avgPrices[i] = buyPriceOf_[_addr][_marketIds[i]].avgPrice;
            balances[i] = balanceOf(_addr, _marketIds[i]);
        }
    }

    function createMarket(string memory _name, string memory _description, uint256 _shares) public payable nonReentrant {
        // Check parameters
        require(bytes(_name).length >= 10 && bytes(_name).length <= 100, "Name out of bound");
        require(bytes(_description).length <= 1000, "Description out of bound");

        uint256 _currentMarketId = nextMarketId;
        markets[_currentMarketId].name = _name;
        markets[_currentMarketId].description = _description;

        uint256 _priceInWei = _getPrice(_currentMarketId, true, _shares); // Price read directly from contract, not frontend, so slippage is not considered
        _buyShare(_currentMarketId, _shares, _priceInWei, _priceInWei, 0);

        uint256 _currentPrice = (10000 + B * markets[_currentMarketId].totalShares) * DECIMALS / 10000;
        nextMarketId++;

        emit CreateMarket(
            msg.sender, 
            _currentMarketId, 
            _name, 
            _description, 
            _shares, 
            _priceInWei, 
            _currentPrice
        );
    }

    function buyShare(uint256 _marketId, uint256 _shares, uint256 _frontendPriceInWei, uint256 _slippageBPS) public payable nonReentrant inBound(_marketId) {
        uint256 _executionPriceInWei = _getPrice(_marketId, true, _shares);
        uint256 _refundInWei = _buyShare(_marketId, _shares, _executionPriceInWei, _frontendPriceInWei, _slippageBPS);
        uint256 _marketFeePerShareAt = marketFeePerShareAt[_marketId];
        uint256 _currentPrice = (10000 + B * markets[_marketId].totalShares) * DECIMALS / 10000;

        emit BuyShare(
            msg.sender, 
            _marketId, 
            _shares, 
            _executionPriceInWei, 
            _slippageBPS, 
            msg.value, 
            _refundInWei, 
            _marketFeePerShareAt, 
            _currentPrice
        );
    }

    // A private function is separated for different requirements when creating a market or simply buying shares.
    // NextMarketId, _frontendPriceInWei, _slippageBPS are treated differently depending on whichever the caller functions.
    // _frontendPriceInWei is the price read in frontend.
    function _buyShare(
        uint256 _marketId, 
        uint256 _shares, 
        uint256 _executionPriceInWei, 
        uint256 _frontendPriceInWei, 
        uint256 _slippageBPS
    ) private isBuySell(_shares, _slippageBPS) returns (uint256 refundInWei) {
        require(markets[_marketId].totalShares + _shares >= sentiment, "Market currently below minimum balance");

        // In the case of createMarket(), _frontendPriceInWei will always be equal to _executionPriceInWei
        // Since the market is not tradable if it's not created first, thus will not experience price change at all
        uint256 _maxPrice = _frontendPriceInWei * (10000 + _slippageBPS) / 10000;
        require(msg.value >= _executionPriceInWei && msg.value <= _maxPrice, "Exceed slippage");

        _collectProtocolRevenue(_marketId);

        // Update market current conditions
        totalShares += _shares;
        markets[_marketId].totalShares += _shares;

        _calculateMinimumBalance(_marketId, _shares);

        _pushShare(_marketId, _shares);

        // Update protocol active markets and Trader active markets
        activeMarkets_.add(_marketId);
        marketIds_[msg.sender].add(_marketId);

        _calculateTraderAverageBuyPrice(msg.sender, _marketId, true, _shares, _executionPriceInWei);

        // Record points earned by users
        // If _marketId == nextMarketId, the function is called from createMarket() and brfore nextMarketId is Incremented
        address _pointProgramAddr = IDAO(DAO).pointProgramAddr();
        if (_marketId == nextMarketId) IPoint(_pointProgramAddr).updateCreatorAddr(_marketId, msg.sender);
        IPoint(_pointProgramAddr).updateBuyPoint(msg.sender, _marketId, _shares);

        _mint(msg.sender, _marketId, _shares, "");

        refundInWei = msg.value - _executionPriceInWei;
        if (refundInWei > 0) {
            (bool _success, ) = msg.sender.call{value: refundInWei}("");
            require(_success, "Refund failed");
        }
    }

    // Unlike trading fee, protocol revenue generate continuously in DAO contract
    // Revenue generated before new buys should belong to former shares
    // marketUndistributedFee_ will be recorded if there is still revenue left to be claimed
    // and before _marketTotalShares is updated and _pushShare is called
    function _collectProtocolRevenue(uint256 _marketId) private {
        uint256 _marketTotalShares = markets[_marketId].totalShares;
        uint256 _protocolRevenue = IDAO(DAO).claim(_marketId);
        if (_marketTotalShares == 0) marketUndistributedFee_[_marketId] += _protocolRevenue;
        if (_marketTotalShares > 0) {
            _protocolRevenue += marketUndistributedFee_[_marketId];
            marketFeePerShareAt[_marketId] += _protocolRevenue / _marketTotalShares;
            marketUndistributedFee_[_marketId] = _protocolRevenue % _marketTotalShares;
        }
    }

    function _calculateMinimumBalance(uint256 _marketId, uint256 _shares) private {
        _updateSentiment();
        epochActiveMarkets_[nextEpochId_].add(_marketId);
        epochActiveMarketShares_ += _shares;
    }

    function _pushShare(uint256 _marketId, uint256 _shares) private {
        Share[] storage stack = shareStack_[_marketId];
        uint256 _fps = marketFeePerShareAt[_marketId];

        stack.push(Share({
            amount: _shares, 
            feePerShareFrom: _fps, 
            timestamp: block.timestamp
        }));
    }

    // Anyone can always call this function to update Sentinel, 
    // especially if the price gets too high to update it through buyShare()
    function updateSentiment() public { _updateSentiment(); }

    function _updateSentiment() private {
        uint256 _timePassed = block.timestamp - lastUpdatedAt;
        uint256 _totalMarketLength = epochActiveMarkets_[nextEpochId_].ids.length;
        if (_timePassed > 12 hours) {
            uint256 _weightedShares;
            if (_totalMarketLength != 0) _weightedShares = epochActiveMarketShares_ / _totalMarketLength;
            if (_weightedShares > sentiment) sentiment++;
            if (_weightedShares < sentiment) sentiment--;
            nextEpochId_++;
            epochActiveMarketShares_ = 0;
            lastUpdatedAt = block.timestamp;
        }
    }

    function sellShare(
        uint256 _marketId, 
        uint256 _shares, 
        uint256 _frontendPriceInWei, 
        uint256 _slippageBPS
    ) public nonReentrant inBound(_marketId) isBuySell(_shares, _slippageBPS) {
        require(_shares <= balanceOf(msg.sender, _marketId), "Insufficient shares");

        uint256 _refund = _getPrice(_marketId, false, _shares);
        uint256 _minPrice = _frontendPriceInWei * (10000 - _slippageBPS) / 10000;
        require(_refund >= _minPrice, "Exceed slippage");

        (uint256 _netProfit, uint256 _tradingFee, uint256 _points) = _calculateProfit(_marketId, _shares, _refund);

        _updateMarket(_marketId, _shares, _points);

        _calculateRewardFee(_marketId, _tradingFee);

        // Send refund to seller
        (bool _success, ) = msg.sender.call{value: _netProfit}("");
        require(_success, "Refund failed");

        emit SellShare(
            msg.sender, 
            _marketId, 
            _shares, 
            _slippageBPS
        );
    }

    function _getPrice(uint256 _marketId, bool _buy, uint256 _shares) private view returns (uint256 priceInWei) {
        uint256 _term1 = 1 * _shares * DECIMALS; // The initial price is always 1 $HYPE
        uint256 _term2 = _getPriceAppreciation(_marketId, _buy, _shares);
        priceInWei =  _term1 + _term2;
    }

    function _getPriceAppreciation(uint256 _marketId, bool _buy, uint256 _shares) private view returns (uint256) {
        uint256 _sharesAfter = _buy ? markets[_marketId].totalShares + _shares : markets[_marketId].totalShares - _shares;
        uint256 _sharesAfterSquared  = _sharesAfter * _sharesAfter;
        uint256 _sharesBeforeSquared = markets[_marketId].totalShares * markets[_marketId].totalShares;
        return _buy ? B * (_sharesAfterSquared - _sharesBeforeSquared) * DECIMALS / 2 / 10000 : B * (_sharesBeforeSquared - _sharesAfterSquared) * DECIMALS / 2 / 10000;
    }

    function _calculateProfit(uint256 _marketId, uint256 _shares, uint256 _refund) private returns (uint256, uint256, uint256) {
        // Calculate trader reward. This constitutes sell price and past trading fee
        (uint256 _feeReward, uint256 _points) = _popLots(_marketId, _shares);

        // Fees that trader needs to pay
        uint256 _term2 = _getPriceAppreciation(_marketId, false, _shares);
        uint256 _tradingFee = _term2 / 2;

        // Trader net profit
        uint256 _netProfit = _refund + _feeReward - _tradingFee;

        emit SellerNetProfit(
            _marketId, 
            msg.sender, 
            _refund, 
            _feeReward, 
            _tradingFee, 
            _netProfit
        );

        return (_netProfit, _tradingFee, _points);
    }

    function _popLots(uint256 _marketId, uint256 _shares) private returns (uint256 feeReward, uint256 points) {
        Share[] storage stack = shareStack_[_marketId];
        uint256 _remaining = _shares;
        uint256 _fps = marketFeePerShareAt[_marketId];

        while (_remaining > 0) {
            Share storage top = stack[stack.length - 1];
            uint256 _stackRemaining = _remaining < top.amount ? _remaining : top.amount;

            feeReward += _stackRemaining * (_fps - top.feePerShareFrom);
            
            uint256 _days = (block.timestamp - top.timestamp) / 1 days;
            points += _days * _stackRemaining * 100;

            top.amount -= _stackRemaining;
            if (top.amount == 0) stack.pop();
            _remaining -= _stackRemaining;
        }
    }

    function _updateMarket(uint256 _marketId, uint256 _shares, uint256 _points) private {
        // Update market shares and price before sending fund
        totalShares -= _shares;
        markets[_marketId].totalShares -= _shares;
        if (markets[_marketId].totalShares == 0) activeMarkets_.remove(_marketId);

        // Update trader info
        // _burn, then check balanceOf
        // try catch _pointProgramAddr in case of fund locked
        _calculateTraderAverageBuyPrice(msg.sender, _marketId, false, _shares, 0);
        _burn(msg.sender, _marketId, _shares); // trader balance changes after this
        if (balanceOf(msg.sender, _marketId) == 0) marketIds_[msg.sender].remove(_marketId);
        address _pointProgramAddr = IDAO(DAO).pointProgramAddr();
        try IPoint(_pointProgramAddr).updateSellPoint(msg.sender, _marketId, _points) {} catch {}
    }

    function _calculateTraderAverageBuyPrice(address _addr, uint256 _marketId, bool _isBuy, uint256 _shares, uint256 _price) private {
        BuyPrice storage buyPriceInfo = buyPriceOf_[_addr][_marketId];
        if (_isBuy) {
            buyPriceInfo.avgPrice = (buyPriceInfo.amount * buyPriceInfo.avgPrice + _price) / (buyPriceInfo.amount + _shares);
            buyPriceInfo.amount += _shares;
        }
        if (!_isBuy) {
            if (buyPriceInfo.amount < _shares) {
                _shares = buyPriceInfo.amount;
                buyPriceInfo.avgPrice = 0;
            }
            buyPriceInfo.amount -= _shares;
        }
    }

    function _calculateRewardFee(uint256 _marketId, uint256 _tradingFee) private {
        // Claim protocol revenue first, then send sentinel revenue to the protocol
        // The revenue sentinel collected this time is not counted
        // But will be saved for next trade if there are tokens staking for the market
        // Check _factoryAddr to make sure the function will not be reverted and traders fund locked
        // When _marketTotalShares is 0, Sentinel will get all the remaining _tradingFee
        uint256 _marketTotalShares = markets[_marketId].totalShares;
        uint256 _calculatingSentinelReward = _tradingFee * SENTINEL / (_marketTotalShares + SENTINEL);
        uint256 _maxSentinelReward = _tradingFee / 5;
        if (_marketTotalShares != 0 && _calculatingSentinelReward > _maxSentinelReward) _calculatingSentinelReward = _maxSentinelReward;
        uint256 _sentinelReward;
        uint256 _protocolRevenue;
        try IDAO(DAO).claim(_marketId) returns (uint256 _claimedRevenue) { _protocolRevenue = _claimedRevenue; } catch {}
        try IDAO(DAO).receiveRevenue{value: _calculatingSentinelReward}() returns (uint256 _revenue) { _sentinelReward = _revenue; } catch {}

        // updateMarketFee
        // Update accumulated market fee after deminishing market totalShares and interacting with DAO
        // When there is no share in the market, the market will still generate feeReward in DAO if tokens staked
        // marketUndistributedFee_ takes into account when _marketTotalShares is 0 after claiming _protocolRevenue
        // These _protocolRevenue will go into marketUndistributedFee_ and reserve for next trade
        uint256 _marketLastUndistributedFee = marketUndistributedFee_[_marketId];
        if (_marketTotalShares == 0) {
            uint256 _totalUndistributedFee = _tradingFee - _sentinelReward + _protocolRevenue; // _tradingFee - _sentinelReward takes into account when receiveRevenue failed
            marketUndistributedFee_[_marketId] += _totalUndistributedFee; // here should be += instead of =
        }
        if (_marketTotalShares > 0) {
            marketFeePerShareAt[_marketId] += (_tradingFee - _sentinelReward + _protocolRevenue + _marketLastUndistributedFee) / _marketTotalShares;
            marketUndistributedFee_[_marketId] = (_tradingFee - _sentinelReward + _protocolRevenue + _marketLastUndistributedFee) % _marketTotalShares;
        }

        uint256 _currentPrice = (10000 + B * _marketTotalShares) * DECIMALS / 10000;

        emit FeeStack(_marketId, _sentinelReward, _protocolRevenue, _marketLastUndistributedFee, marketFeePerShareAt[_marketId], _currentPrice);
    }

    function updateURI(string memory _newURI) external nonReentrant isDAO { _setURI(_newURI); }

    function receiveRevenue() external payable isDAO {}

    receive() external payable { revert("Direct transfer not allowed"); }

    fallback() external payable { revert("Direct transfer not allowed"); }
}

contract CloudedPoint is ReentrancyGuardTransient {
    using UserAddr for UserAddr.Set;

    event UpdatePoints(
        uint256 indexed epoch, 
        uint256 indexed marketId, 
        bool indexed isBuy, 
        address traderAddr, 
        address creatorAddr, 
        uint256 points
    );

    event ClaimToken(
        uint256 indexed epoch, 
        address indexed user, 
        uint256 traderReward, 
        uint256 creatorReward, 
        uint256 totalReward
    );

    address constant DAO = 0xB3690c850d5a4Bc0b7eB1Aa952D3c6854cacad99;
    address constant FACTORY = 0x41D609212882f10AdCA647AFA53BA1e818e53a58;
    uint256 constant EPOCH_DURATION = 30 days;

    // Community amount is represented in half, split between traders and market creators
    // The distribution between traders and creators is 70:30
    uint256 constant COMMUNITY_TRADER_INITIAL_LAUNCH = 14_000_000;
    uint256 constant COMMUNITY_CREATOR_INITIAL_LAUNCH = 6_000_000;
    uint256 constant COMMUNITY_TRADER_LINEAR_UNLOCK = 1_400_000;
    uint256 constant COMMUNITY_CREATOR_LINEAR_UNLOCK = 600_000;

    address public tokenAddr;
    uint256 public nextEpoch;
    mapping(uint256 => uint256) public epochTimestamp;
    mapping(uint256 => uint256) public epochTotalTraderPoints;
    mapping(uint256 => uint256) public epochTotalCreatorPoints;
    mapping(uint256 => address) public marketCreator;
    mapping(uint256 => mapping(address => uint256)) public epochTraderPoints;
    mapping(uint256 => mapping(address => uint256)) public epochCreatorPoints;
    mapping(uint256 => mapping(address => bool)) public epochUserClaimed;
    mapping(uint256 => UserAddr.Set) private epochTraders_;
    mapping(uint256 => UserAddr.Set) private epochCreators_;

    modifier isFactory() {
        require(msg.sender == FACTORY, "Not authorized");
        _;
    }

    constructor() {}

    function getTraderPastEpoch(address _addr) external view returns (
        uint256[] memory totalTraderPoints, 
        uint256[] memory traderPoints, 
        uint256[] memory totalCreatorPoints, 
        uint256[] memory creatorPoints
    ) {
        totalTraderPoints = new uint256[](nextEpoch);
        traderPoints = new uint256[](nextEpoch);
        totalCreatorPoints = new uint256[](nextEpoch);
        creatorPoints = new uint256[](nextEpoch);
        for (uint256 i = 0; i < nextEpoch; i++) {
            totalTraderPoints[i] = epochTotalTraderPoints[i];
            traderPoints[i] = epochTraderPoints[i][_addr];
            totalCreatorPoints[i] = epochTotalCreatorPoints[i];
            creatorPoints[i] = epochCreatorPoints[i][_addr];
        }
    }

    function getEpochTraderCount(uint256 _epoch) external view returns (uint256) { return epochTraders_[_epoch].getLength(); }

    function getEpochCreatorCount(uint256 _epoch) external view returns (uint256) { return epochCreators_[_epoch].getLength(); }

    function getEpochTraderLeaderboard(uint256 _epoch, uint256 _offset, uint256 _limit) external view returns (address[] memory addrs, uint256[] memory points) {
        addrs = epochTraders_[_epoch].getAddrs(_offset, _limit);
        points = new uint256[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            points[i] = epochTraderPoints[_epoch][addrs[i]];
        }
    }

    function getEpochCreatorLeaderboard(uint256 _epoch, uint256 _offset, uint256 _limit) external view returns (address[] memory addrs, uint256[] memory points) {
        addrs = epochCreators_[_epoch].getAddrs(_offset, _limit);
        points = new uint256[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            points[i] = epochCreatorPoints[_epoch][addrs[i]];
        }
    }

    function remainingTimeToNextEpoch() external view returns (uint256, uint256, uint256) {
        require(nextEpoch > 0, "Token not launched");
        if (block.timestamp >= epochTimestamp[nextEpoch] + EPOCH_DURATION) return (0, 0, 0);
        uint256 _remainingTime = epochTimestamp[nextEpoch] + EPOCH_DURATION - block.timestamp;
        uint256 _remainingDay = _remainingTime / 1 days;
        uint256 _remainingHour = _remainingTime / 1 hours % 24;
        uint256 _remainingMinute = _remainingTime / 1 minutes % 60;
        return (_remainingDay, _remainingHour, _remainingMinute);
    }

    function updateCreatorAddr(uint256 _marketId, address _creatorAddr) external nonReentrant isFactory { marketCreator[_marketId] = _creatorAddr; }

    // nextEpoch can be 0, which represents the epoch before initial token launch
    function updateBuyPoint(
        address _traderAddr, 
        uint256 _marketId, 
        uint256 _shares
    ) external nonReentrant isFactory {
        _updateEpoch();

        uint256 _points = _shares * 100;
        epochTotalTraderPoints[nextEpoch] += _points;
        epochTraderPoints[nextEpoch][_traderAddr] += _points;

        address _creatorAddr = marketCreator[_marketId];
        epochTotalCreatorPoints[nextEpoch] += _points;
        epochCreatorPoints[nextEpoch][_creatorAddr] += _points;

        epochTraders_[nextEpoch].add(_traderAddr);
        epochCreators_[nextEpoch].add(_creatorAddr);

        emit UpdatePoints(
            nextEpoch, 
            _marketId, 
            true, 
            _traderAddr, 
            _creatorAddr, 
            _points
        );
    }

    function updateSellPoint(
        address _traderAddr, 
        uint256 _marketId, 
        uint256 _points
    ) external nonReentrant isFactory {
        _updateEpoch();

        epochTotalTraderPoints[nextEpoch] += _points;
        epochTraderPoints[nextEpoch][_traderAddr] += _points;

        address _creatorAddr = marketCreator[_marketId];

        epochTraders_[nextEpoch].add(_traderAddr);

        emit UpdatePoints(
            nextEpoch, 
            _marketId, 
            false, 
            _traderAddr, 
            _creatorAddr, 
            _points
        );
    }

    function _updateEpoch() private {
        if (nextEpoch > 0) {
            uint256 _timePassed = block.timestamp - epochTimestamp[nextEpoch];
            if (_timePassed > EPOCH_DURATION) {
                nextEpoch++;
                epochTimestamp[nextEpoch] = block.timestamp;
            }
        }
    }

    function activateEpoch(address _tokenAddr) external nonReentrant {
        require(msg.sender == DAO, "Not authorized");
        require(tokenAddr == address(0), "Token is launched");
        tokenAddr = _tokenAddr;
        nextEpoch = 1;
        epochTimestamp[nextEpoch] = block.timestamp;
    }

    // Epoch can still be updated after 40 for leaderboard only
    function claimToken(uint256 _epoch) public nonReentrant {
        require(tokenAddr != address(0), "Token not launched yet");
        require(_epoch < nextEpoch && _epoch <= 40, "Epoch out of bound");
        require(!epochUserClaimed[_epoch][msg.sender], "Already claimed");
        epochUserClaimed[_epoch][msg.sender] = true;
        uint256 _decimals = IERC20Metadata(tokenAddr).decimals();
        uint256 _wei = 10 ** _decimals;

        if (_epoch == 0) {
            uint256 _tradingReward = COMMUNITY_TRADER_INITIAL_LAUNCH * _wei * epochTraderPoints[_epoch][msg.sender] / epochTotalTraderPoints[_epoch];
            uint256 _creatorReward = COMMUNITY_CREATOR_INITIAL_LAUNCH * _wei * epochCreatorPoints[_epoch][msg.sender] / epochTotalCreatorPoints[_epoch];
            uint256 _totalReward = _tradingReward + _creatorReward;
            IToken(tokenAddr).mint(msg.sender, _totalReward);
            emit ClaimToken(_epoch, msg.sender, _tradingReward, _creatorReward, _totalReward);
        }

        if (_epoch > 0) {
            uint256 _tradingReward = COMMUNITY_TRADER_LINEAR_UNLOCK * _wei * epochTraderPoints[_epoch][msg.sender] / epochTotalTraderPoints[_epoch];
            uint256 _creatorReward = COMMUNITY_CREATOR_LINEAR_UNLOCK * _wei * epochCreatorPoints[_epoch][msg.sender] / epochTotalCreatorPoints[_epoch];
            uint256 _totalReward = _tradingReward + _creatorReward;
            IToken(tokenAddr).mint(msg.sender, _totalReward);
            emit ClaimToken(_epoch, msg.sender, _tradingReward, _creatorReward, _totalReward);
        }
    }
}

contract CloudedToken is ERC20 {

    address constant POINT_PROGRAM = 0x48F7eb29fCB50Bc6225f9f04148e76E323B18C61;

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

    function mint(address _traderAddr, uint256 _amountInWei) external {
        require(msg.sender == POINT_PROGRAM, "Not authorized");
        _mint(_traderAddr, _amountInWei);
    }
}
