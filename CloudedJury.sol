// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

library Ids {
    struct Set {
        uint256[] ids;
        mapping(uint256 => uint256) positions;
    }

    function add(Set storage set, uint256 _id) internal {
        if (set.positions[_id] == 0) {
            set.ids.push(_id);
            set.positions[_id] = set.ids.length; // skip index 0 for non existing element
        }
    }

    function remove(Set storage set, uint256 _id) internal {
        uint256 _position = set.positions[_id];
        if (_position != 0) {
            uint256 _index = _position - 1;
            uint256 _lastIndexId = set.ids[set.ids.length - 1];
            set.ids[_index] = _lastIndexId;
            set.positions[_lastIndexId] = _position;
            set.ids.pop();
            delete set.positions[_id];
        }
    }

    function swap(Set storage set, uint256 _indexA, uint256 _indexB) internal {
        if (_indexA == _indexB) return;
        
        uint256 idA = set.ids[_indexA];
        uint256 idB = set.ids[_indexB];

        set.ids[_indexA] = idB;
        set.ids[_indexB] = idA;

        set.positions[idA] = _indexB + 1;
        set.positions[idB] = _indexA + 1;
    }

    function isSet(Set storage set, uint256 _id) internal view returns (bool) { return set.positions[_id] != 0; }

    function getId(Set storage set, uint256 _position) internal view returns (uint256) { return set.ids[_position]; }

    function getAll(Set storage set) internal view returns (uint256[] memory) { return set.ids; }

    function getLength(Set storage set) internal view returns (uint256) { return set.ids.length; }
}

interface IClouded {
    function nextMarketId() external view returns (uint256);
    function getMarketStartAtDaysOf(uint256) external view returns (uint256, uint256);
    function getOutcomeMarketId(uint256) external view returns (uint256);
    function getMarketOutcomeIds(uint256) external view returns (uint256[] memory);
    function getMarketWinningOutcome(uint256) external view returns (uint256);
    function getPriceAppreciation(uint256, bool, uint256) external view returns (uint256);
    function getMarketIndexInfoInBatch(uint256[] memory _marketIds) external view returns (string[] memory, uint256[] memory, uint256[][] memory, string[][] memory, uint256[][] memory, uint256[] memory, uint256[] memory, uint256[] memory);
    function getMarketResolutionInfoInBatch(uint256[] memory) external view returns (string[] memory, uint256[] memory, uint256[] memory, uint256[] memory, uint256[] memory);
    function createMarket(string memory, string memory, string[] memory, uint256) external returns (uint256[] memory);
    function buy(address, uint256, uint256, uint256, uint256, uint256) external payable;
    function claimJuryReward(address, uint256, uint256) external returns (uint256);
}

interface IDAO {
    function mint(address, uint256) external;
    function outcomeVotes(uint256) external view returns (uint256);
    function buyBack() external payable;
}

contract CloudedJury is ERC721, ReentrancyGuardTransient {
    using Strings for uint256;
    using Ids for Ids.Set;

    event AddToWhitelist(address indexed addr);
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);
    event Stake(address indexed staker, uint256 indexed marketId, uint256 indexed tokenId);
    event Unstake(address indexed staker, uint256 indexed marketId, uint256 indexed tokenId);
    event CreateMarket(address indexed marketCreator, uint256 indexed marketId, uint256 indexed tokenId);
    event StakeAfter(address indexed staker, uint256 indexed marketId, uint256 marketStakes);
    event UnstakeAfter(address indexed staker, uint256 indexed marketId, uint256 marketStakes, bool isMarketOf);
    event CreateMarketAfter(address indexed marketCreator, uint256 indexed marketId, string marketName, string marketRule, uint256[] marketOutcomeIds, string[] marketOutcomeNames, uint256 startAt, uint256 daysOf);
    event RevealOutcome(uint256 indexed marketId, address indexed juryAddr, uint256 indexed juryOutcomeIdOf, bytes32 randomNumber, uint256 juryReveals, uint256 marketRevealedTS, uint256 juryOutcome);
    event SelectJury(uint256 indexed marketId, uint256 indexed tokenId, uint256 indexed tokenOutcomeId, address tokenOwner);
    event Challenge(address indexed challenger, uint256 indexed marketId, uint256 indexed tokenId, uint256 marketChallengedTS);
    event ResolveMarket(uint256 indexed marketId, uint256 votingOutcomeId, uint256 resolvedOutcomeId);
    event ClaimCreatorToken(address indexed creator, uint256 indexed marketId, uint256 tokenId);
    event ClaimChallengerReward(address indexed challenger, uint256 indexed marketId, uint256 tokenId, uint256 challengerReward);
    event ClaimJuryReward(address indexed staker, uint256 indexed marketId, uint256 tokenId, uint256 tokenReward);
    event ClaimRewardAfter(address indexed staker, uint256 indexed marketId, bool isMarketOf);
    event Slash(address indexed staker, uint256 indexed marketId, uint256 outcomeId, uint256 tokenId);
    event SendSlashedTokenToDAO(uint256 indexed marketId, uint256 tokens, uint256 tokenValue);
    event PublicLaunch();

    uint256 constant DECIMALS = 1e18;
    address public immutable MANAGER;
    address public CLOUDED;
    address public DAO;

    bool public whitelisted;

    // Overall protocol conditions
    string  private uri_;
    string  private baseURI_;
    uint256 private nextTokenId_;
    uint256 private totalSupply_;
    Ids.Set private allOngoingMarketIds_;
    Ids.Set private allResolvedMarketIds_;
    mapping(uint256 => Market) private markets_;

    // Staker conditions
    mapping(address => bool) private whitelisted_;
    mapping(address => Ids.Set) private tokenOf_;
    mapping(address => Ids.Set) private marketOf_; // Markets that stakers participate which include staking, creating, challenging
    mapping(uint256 => address) private tokenAddr_; // Staker token address
    mapping(address => mapping(uint256 => Ids.Set)) private marketTokenOf_;
    mapping(address => mapping(uint256 => Ids.Set)) private marketCreatorTokenOf_;
    mapping(address => mapping(uint256 => Ids.Set)) private marketChallengerTokenOf_;
    mapping(address => mapping(uint256 => bytes32)) private marketCommitHashOf_;
    mapping(address => mapping(uint256 => bool)) private marketHasRevealedOf_;
    mapping(address => mapping(uint256 => uint256)) private marketOutcomeOf_;

    // Staked tokens
    mapping(uint256 => Ids.Set) private marketStakes_; // total stakes in the market excluding creator and challenger tokens
    mapping(uint256 => Ids.Set) private marketJuryStakes_; // total stakes picked as jury
    mapping(uint256 => mapping(uint256 => uint256)) private juryOutcomeCount_;   // The amount of stakes in the jury, in the order of marketId → outcomeId → count
    mapping(uint256 => mapping(uint256 => uint256)) private marketOutcomeCount_; // The amount of stakes in the market

    struct Market {
        uint256 creatorTokens;
        uint256 challengerToken;
        uint256 marketRevealedTS;
        uint256 marketChallengedTS;
        uint256 marketReveals;
        uint256 juryOutcome;
        uint256 votingOutcome;
        bytes32 randomNumber;
        bool juryHasSelected;
        bool marketResolved;
        Status status;
    }

    enum Status {
        ONGOING, 
        JURY, 
        APPEAL, 
        VOTING, 
        SETTLED
    }

    modifier isManager() { if (msg.sender != MANAGER) revert NotAuthorized(); _; }

    constructor(string memory _name, string memory _symbol, address _managerAddr) ERC721(_name, _symbol) {
        MANAGER = _managerAddr;
        whitelisted = true;
        nextTokenId_ = 1;
    }

    function addToWhitelist(address _addr) external isManager {
        whitelisted_[_addr] = true;
        emit AddToWhitelist(_addr);
    }

    function publicLaunch() external isManager { whitelisted = false; emit PublicLaunch(); }

    function isWhitelisted(address _addr) external view returns (bool) { return whitelisted_[_addr]; }

    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        _requireOwned(_tokenId);
        return bytes(baseURI_).length > 0 ? baseURI_ : string.concat(uri_, _tokenId.toString());
    }

    function updateURI(string memory _newBaseURI, string memory _newURI) external isManager {
        baseURI_ = _newBaseURI;
        uri_ = _newURI;
        emit BatchMetadataUpdate(1, nextTokenId_ - 1);
    }

    function updateDAOAddr(address _daoAddr) external isManager { DAO = _daoAddr; }

    function updateCloudedAddr(address _cloudedAddr) external isManager { CLOUDED = _cloudedAddr; }

    function updateMarketStatus(uint256 _marketId) external returns (uint8) { return uint8(_updateMarketStatus(_marketId)); }

    function getAllOngoingMarketIds() external view returns (uint256[] memory) { return allOngoingMarketIds_.getAll(); }

    function getCurrentCreateMarketPrice() external view returns (uint256) { return _getCurrentCreateMarketPrice(); }

    function getResolvedMarkets() external view returns (uint256) { return allResolvedMarketIds_.getLength(); }

    function getResolvedMarketIds(uint256 _offset, uint256 _limit) external view returns (uint256[] memory ids) {
        uint256 _totalMarkets = allResolvedMarketIds_.getLength();
        if (_offset >= _totalMarkets || _limit == 0) return new uint256[](0);

        uint256 _end   = _totalMarkets - _offset;
        uint256 _count = _end > _limit ? _limit : _end;

        ids = new uint256[](_count);
        for (uint256 i = 0; i < _count; i++) { ids[i] = allResolvedMarketIds_.getId(_end - 1 - i); }
    }

    function getMarketStoredInfo(uint256 _marketId) external view returns (
        uint256 creatorTokens, 
        uint256 challengerToken, 
        uint256 marketRevealedTS, 
        uint256 marketChallengedTS, 
        uint256 marketReveals, 
        uint256 juryOutcome, 
        uint256 votingOutcome, 
        bytes32 randomNumber, 
        bool    juryHasSelected, 
        bool    marketResolved
    ) {
        Market storage market = markets_[_marketId];
        creatorTokens      = market.creatorTokens;
        challengerToken    = market.challengerToken;
        marketRevealedTS   = market.marketRevealedTS;
        marketChallengedTS = market.marketChallengedTS;
        marketReveals      = market.marketReveals;
        juryOutcome        = market.juryOutcome;
        votingOutcome      = market.votingOutcome;
        randomNumber       = market.randomNumber;
        juryHasSelected    = market.juryHasSelected;
        marketResolved     = market.marketResolved;
    }

    function getMarketDerivedInfo(uint256 _marketId) external view returns (uint256 resolvedOutcome, uint8 status) {
        resolvedOutcome = _getResolvedMarketOutcome(_marketId);
        Status _current = _getMarketStatus(_marketId);
        status = uint8(_current > markets_[_marketId].status ? _current : markets_[_marketId].status);
    }

    function getUserTokenIds(address _userAddr) external view returns (uint256[] memory) { return tokenOf_[_userAddr].getAll(); }

    function getStakerMarketIds(address _stakerAddr) external view returns (uint256[] memory) { return marketOf_[_stakerAddr].getAll(); }

    function getStakerMarketTokenIds(address _stakerAddr, uint256 _marketId) external view returns (uint256[] memory creatorTokenIds, uint256[] memory challengerTokenIds, uint256[] memory stakerTokenIds) {
        creatorTokenIds    = marketCreatorTokenOf_[_stakerAddr][_marketId].getAll();
        challengerTokenIds = marketChallengerTokenOf_[_stakerAddr][_marketId].getAll();
        stakerTokenIds     = marketTokenOf_[_stakerAddr][_marketId].getAll();
    }

    function mint(uint256 _amount) external payable nonReentrant {
        if (whitelisted && !whitelisted_[msg.sender]) revert Whitelisted();

        if (_amount == 0) revert ZeroAmount();

        uint256 _mintPrice = 3 * _amount * DECIMALS; // The price for minting an NFT is 3 $HYPE
        if (msg.value < _mintPrice) revert InsufficientPayment();

        for (uint256 i = 0; i < _amount; i++) {
            _mint(msg.sender, nextTokenId_);
            nextTokenId_++;
        }

        IDAO(DAO).buyBack{value: _amount * DECIMALS / 100}();

        uint256 _refund = msg.value - _mintPrice;
        if (_refund > 0) {
            (bool _success, ) = msg.sender.call{value: _refund}("");
            if (!_success) revert RefundFailed();
        }
    }

    function redeem(uint256[] memory _tokenIds) external nonReentrant {
        uint256 _amount;
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            if (_ownerOf(_tokenIds[i]) != msg.sender) revert NotOwner(_tokenIds[i]);
            _burn(_tokenIds[i]);
            _amount++;
        }

        if (_amount == 0) revert ZeroAmount();

        (bool _success, ) = msg.sender.call{value: _amount * 299 * DECIMALS / 100}("");
        if (!_success) revert RefundFailed();
    }

    function stake(uint256 _marketId, uint256[] memory _tokenIds, bytes32 _commitHash) external nonReentrant {
        if (_commitHash == 0) revert NoCommitHash();
        if (_tokenIds.length == 0) revert NoTokenSelected();
        if (_updateMarketStatus(_marketId) != Status.ONGOING) revert MarketEnded();

        uint256 _tokenId;
        Ids.Set storage marketStakes  = marketStakes_[_marketId];
        Ids.Set storage marketTokenOf = marketTokenOf_[msg.sender][_marketId];
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            _tokenId = _tokenIds[i];
            if (_ownerOf(_tokenId) != msg.sender) revert NotOwner(_tokenId);
            marketStakes.add(_tokenId);
            marketTokenOf.add(_tokenId);
            tokenAddr_[_tokenId] = msg.sender;
            _update(address(this), _tokenId, msg.sender);
            emit Stake(msg.sender, _marketId, _tokenId);
        }
        marketOf_[msg.sender].add(_marketId);
        marketCommitHashOf_[msg.sender][_marketId] = _commitHash;
        emit StakeAfter(msg.sender, _marketId, marketStakes.getLength());
    }

    function unstake(uint256 _marketId, uint256[] memory _tokenIds) external nonReentrant {
        if (_updateMarketStatus(_marketId) != Status.ONGOING) revert MarketEnded();

        Ids.Set storage marketStakes  = marketStakes_[_marketId];
        Ids.Set storage marketTokenOf = marketTokenOf_[msg.sender][_marketId];
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            if (!marketTokenOf.isSet(_tokenIds[i])) revert NotStakedByOwner(_tokenIds[i]);
            marketStakes.remove(_tokenIds[i]);
            _unstake(_marketId, _tokenIds[i]);
        }
        if (marketTokenOf.getLength() == 0) delete marketCommitHashOf_[msg.sender][_marketId];
        if (marketCreatorTokenOf_[msg.sender][_marketId].getLength() == 0 && marketChallengerTokenOf_[msg.sender][_marketId].getLength() == 0 && marketTokenOf.getLength() == 0) marketOf_[msg.sender].remove(_marketId);
        emit UnstakeAfter(msg.sender, _marketId, marketStakes.getLength(), marketOf_[msg.sender].isSet(_marketId));
    }

    function createMarket(string memory _name, string memory _rule, string[] memory _outcomes, uint256 _days, uint256[] memory _tokenIds, uint256 _outcomePosition, uint256 _shares) external payable nonReentrant {
        if (_outcomePosition == 0 || _outcomePosition > _outcomes.length) revert InvalidId();

        uint256 _requiredTokenAmount = _getCurrentCreateMarketPrice();
        if (_tokenIds.length < _requiredTokenAmount) revert StakeRequiredAmounts();

        uint256 _nextMarketId = IClouded(CLOUDED).nextMarketId();
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            if (_ownerOf(_tokenIds[i]) != msg.sender) revert NotOwner(_tokenIds[i]);
            marketCreatorTokenOf_[msg.sender][_nextMarketId].add(_tokenIds[i]);
            _update(address(this), _tokenIds[i], msg.sender);
            emit CreateMarket(msg.sender, _nextMarketId, _tokenIds[i]);
        }

        allOngoingMarketIds_.add(_nextMarketId);
        marketOf_[msg.sender].add(_nextMarketId);
        markets_[_nextMarketId].creatorTokens = _tokenIds.length;

        uint256[] memory _outcomeIds = IClouded(CLOUDED).createMarket(_name, _rule, _outcomes, _days);
        emit CreateMarketAfter(msg.sender, _nextMarketId, _name, _rule, _outcomeIds, _outcomes, block.timestamp, _days * 1 days);

        uint256 _outcomeId = _outcomeIds[_outcomePosition - 1];
        _creatorBuy(_nextMarketId, _outcomeId, _shares);
    }

    function revealOutcome(uint256 _marketId, uint256 _outcomeId, bytes32 _salt) external nonReentrant {
        if (_updateMarketStatus(_marketId) != Status.JURY) revert JuryWindowEnded();
        if (IClouded(CLOUDED).getOutcomeMarketId(_outcomeId) != _marketId) revert InvalidId();
        if (marketHasRevealedOf_[msg.sender][_marketId]) revert OutcomeRevealed();
        marketHasRevealedOf_[msg.sender][_marketId] = true;

        bytes32 _commitHash = marketCommitHashOf_[msg.sender][_marketId];
        if (_commitHash == 0) revert NoCommitHash();
        if (keccak256(abi.encodePacked(msg.sender, _marketId, _outcomeId, _salt)) != _commitHash) revert WrongCommitHash();
        marketOutcomeOf_[msg.sender][_marketId] = _outcomeId;

        Market storage market = markets_[_marketId];
        market.randomNumber   = market.randomNumber ^ _salt;

        market.marketReveals     += marketTokenOf_[msg.sender][_marketId].getLength();
        if (market.marketReveals == marketStakes_[_marketId].getLength()) market.marketRevealedTS = block.timestamp;

        uint256 _winningOutcomeId;
        uint256 _winningOutcomeCount;
        uint256[] memory _marketOutcomeIds = IClouded(CLOUDED).getMarketOutcomeIds(_marketId);
        marketOutcomeCount_[_marketId][_outcomeId] += marketTokenOf_[msg.sender][_marketId].getLength();
        for (uint256 i = 0; i < _marketOutcomeIds.length; i++) {
            if (marketOutcomeCount_[_marketId][_marketOutcomeIds[i]] > _winningOutcomeCount) {
                _winningOutcomeId    = _marketOutcomeIds[i];
                _winningOutcomeCount = marketOutcomeCount_[_marketId][_marketOutcomeIds[i]];
            }
        }
        market.juryOutcome = _winningOutcomeId;

        emit RevealOutcome(_marketId, msg.sender, _outcomeId, market.randomNumber, market.marketReveals, market.marketRevealedTS, market.juryOutcome);
    }

    function selectJury(uint256 _marketId) external nonReentrant {
        if (_updateMarketStatus(_marketId) != Status.APPEAL) revert AppealWindowEnded();

        if (markets_[_marketId].juryHasSelected) revert JurySelected(true);
        markets_[_marketId].juryHasSelected = true;

        uint256 _attempt;
        Ids.Set storage marketStakes = marketStakes_[_marketId];
        uint256 _totalStakedTokens   = marketStakes.getLength();
        uint256 _jurySet             = _totalStakedTokens == 0 ? 0 : _totalStakedTokens < 5 ? 1 : _totalStakedTokens / 5 < 300 ? _totalStakedTokens / 5 : 300;
        while (_attempt < _jurySet) {
            uint256 _position = _attempt + uint256(keccak256(abi.encodePacked(markets_[_marketId].randomNumber, _attempt))) % (marketStakes.getLength() - _attempt);
            marketStakes.swap(_attempt, _position);

            uint256 _tokenId        = marketStakes.getId(_attempt);
            address _tokenOwner     = tokenAddr_[_tokenId];
            uint256 _tokenOutcomeId = marketOutcomeOf_[_tokenOwner][_marketId];
            if (_tokenOutcomeId != 0) {
                marketJuryStakes_[_marketId].add(_tokenId);
                juryOutcomeCount_[_marketId][_tokenOutcomeId]++;
                emit SelectJury(_marketId, _tokenId, _tokenOutcomeId, _tokenOwner);
            }

            _attempt++;
        }
    }

    // Challenge can only be made once every market. 
    // The token will be rewarded if the voters also agree with the same outcome, 
    // but will be slashed for being wrong.
    function challenge(uint256 _marketId, uint256 _tokenId) external nonReentrant {
        if (_updateMarketStatus(_marketId) != Status.APPEAL) revert AppealWindowEnded();
        if (_ownerOf(_tokenId) != msg.sender) revert NotOwner(_tokenId);

        Market storage market = markets_[_marketId];
        if (!market.juryHasSelected) revert JurySelected(false);
        if (market.marketChallengedTS != 0) revert MarketAlreadyChallenged();
        market.marketChallengedTS = block.timestamp;
        market.challengerToken++;

        marketOf_[msg.sender].add(_marketId);
        marketChallengerTokenOf_[msg.sender][_marketId].add(_tokenId);

        _update(address(this), _tokenId, msg.sender);

        emit Challenge(msg.sender, _marketId, _tokenId, block.timestamp);
    }

    function resolveMarket(uint256 _marketId) external nonReentrant {
        if (_updateMarketStatus(_marketId) != Status.SETTLED) revert MarketNotEnded();

        Market storage market = markets_[_marketId];
        if (market.marketResolved) revert MarketResolved(true);
        market.marketResolved = true;

        allOngoingMarketIds_.remove(_marketId);
        allResolvedMarketIds_.add(_marketId);

        bool _isMarketChallenged = market.marketChallengedTS != 0;
        if (_isMarketChallenged) {
            uint256[] memory _marketOutcomeIds = IClouded(CLOUDED).getMarketOutcomeIds(_marketId);
            uint256[] memory _marketOutcomes   = new uint256[](_marketOutcomeIds.length);
            for (uint256 i = 0; i < _marketOutcomeIds.length; i++) _marketOutcomes[i] = IDAO(DAO).outcomeVotes(_marketOutcomeIds[i]);
            market.votingOutcome = _calculateMarketOutcome(_marketOutcomeIds, _marketOutcomes);
        }

        uint256 _resolvedOutcomeId = _getResolvedMarketOutcome(_marketId);
        _sendSlashedTokenValueToDao(_marketId, _resolvedOutcomeId);

        emit ResolveMarket(_marketId, market.votingOutcome, _resolvedOutcomeId);
    }

    function claimReward(uint256 _marketId, uint256[] memory _tokenIds) external nonReentrant {
        if (_updateMarketStatus(_marketId) != Status.SETTLED) revert MarketNotEnded();
        if (!markets_[_marketId].marketResolved) revert MarketResolved(false);

        uint256 _currentTokenId;
        uint256 _marketOutcome = _getResolvedMarketOutcome(_marketId);
        uint256 _outcomeOf     = marketOutcomeOf_[msg.sender][_marketId];
        (, uint256 _daysOf)    = IClouded(CLOUDED).getMarketStartAtDaysOf(_marketId);
        (, uint256 _totalWinnerOutcomeStakes)   = _getSlashedAndRewardedTokens(_marketId, _marketOutcome);
        Market  storage market                  = markets_[_marketId];
        Ids.Set storage marketTokenOf           = marketTokenOf_[msg.sender][_marketId];
        Ids.Set storage marketCreatorTokenOf    = marketCreatorTokenOf_[msg.sender][_marketId];
        Ids.Set storage marketChallengerTokenOf = marketChallengerTokenOf_[msg.sender][_marketId];
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            _currentTokenId = _tokenIds[i];

            if (marketCreatorTokenOf.isSet(_currentTokenId)) { _claimCreatorToken(_marketId, _currentTokenId); continue; }

            if (marketChallengerTokenOf.isSet(_currentTokenId)) {
                if (market.juryOutcome != _marketOutcome) { // market.juryOutcome can be 0 if challenged
                    _claimChallengerReward(_marketId, _currentTokenId, _totalWinnerOutcomeStakes);
                    if (market.marketReveals == marketStakes_[_marketId].getLength()) IDAO(DAO).mint(msg.sender, _daysOf / 1 days * DECIMALS);
                } else _slash(_marketId, _outcomeOf, _currentTokenId); // Challenger has no vote on market outcome
                continue;
            }

            if (!marketTokenOf.isSet(_currentTokenId)) continue; // The token is not creator, challenger, staker token, or belong to the market or caller

            if (!marketHasRevealedOf_[msg.sender][_marketId]) { _slash(_marketId, _outcomeOf, _currentTokenId); continue; }

            if (marketJuryStakes_[_marketId].isSet(_currentTokenId)) {
                if (_outcomeOf != _marketOutcome) { _slash(_marketId, _outcomeOf, _currentTokenId); continue; } // The jury outcome is also checked and slashed if 0, equivalent to _getSlashedAndRewardedTokens
                else if (market.marketReveals == marketStakes_[_marketId].getLength()) IDAO(DAO).mint(msg.sender, _daysOf / 1 days * DECIMALS);
            }

            _unstake(_marketId, _currentTokenId);

            uint256 _tokenReward;
            if (_outcomeOf == _marketOutcome) _tokenReward = IClouded(CLOUDED).claimJuryReward(msg.sender, _marketId, _totalWinnerOutcomeStakes);

            emit ClaimJuryReward(msg.sender, _marketId, _currentTokenId, _tokenReward);
        }

        if (marketCreatorTokenOf.getLength() == 0 && marketChallengerTokenOf.getLength() == 0 && marketTokenOf.getLength() == 0) marketOf_[msg.sender].remove(_marketId);

        emit ClaimRewardAfter(msg.sender, _marketId, marketOf_[msg.sender].isSet(_marketId));
    }

    function _getCurrentCreateMarketPrice() private view returns (uint256) { return totalSupply_ / 100 > 5 ? totalSupply_ / 100 : 5; }

    function _update(address _to, uint256 _tokenId, address _auth) internal override returns (address) {
        address from = super._update(_to, _tokenId, _auth);

        if (from == address(0)) totalSupply_++;
        if (_to == address(0)) totalSupply_--;

        if (from != address(0)) tokenOf_[from].remove(_tokenId);
        if (_to != address(0)) tokenOf_[_to].add(_tokenId);

        return from;
    }

    function _updateMarketStatus(uint256 _marketId) private returns (Status) {
        if (_marketId == 0 || _marketId >= IClouded(CLOUDED).nextMarketId()) revert InvalidId();
        Market storage market = markets_[_marketId];
        Status _currentMarketStatus = _getMarketStatus(_marketId);
        if (_currentMarketStatus > market.status) market.status = _currentMarketStatus;
        return market.status;
    }

    function _getMarketStatus(uint256 _marketId) private view returns (Status) {
        (uint256 _startAt, uint256 _daysOf) = IClouded(CLOUDED).getMarketStartAtDaysOf(_marketId);
        uint256 _marketEndAt = _startAt + _daysOf;

        Market storage market = markets_[_marketId];
        uint256 _currentTimestamp = block.timestamp;

        if (_currentTimestamp < _marketEndAt) return Status.ONGOING;

        if (market.marketRevealedTS == 0 && _currentTimestamp < _marketEndAt + 1 days) return Status.JURY;

        uint256 _challengeStart = market.marketRevealedTS != 0 ? market.marketRevealedTS : _marketEndAt + 1 days;

        if (market.marketChallengedTS != 0) return _currentTimestamp >= market.marketChallengedTS + 3 days ? Status.SETTLED : Status.VOTING;

        return _currentTimestamp < _challengeStart + 1 days ? Status.APPEAL : Status.SETTLED;
    }

    function _creatorBuy(uint256 _nextMarketId, uint256 _outcomeId, uint256 _shares) private {
        uint256 _executionPrice = IClouded(CLOUDED).getPriceAppreciation(_outcomeId, true, _shares);
        if (msg.value < _executionPrice) revert InsufficientPayment();

        IClouded(CLOUDED).buy{value: _executionPrice}(msg.sender, _nextMarketId, _outcomeId, _shares, _executionPrice, 0);

        if (msg.value - _executionPrice > 0) {
            (bool _success, ) = msg.sender.call{value: msg.value - _executionPrice}("");
            if (!_success) revert RefundFailed();
        }
    }

    function _unstake(uint256 _marketId, uint256 _tokenId) private {
        marketTokenOf_[msg.sender][_marketId].remove(_tokenId);
        delete tokenAddr_[_tokenId];
        _update(msg.sender, _tokenId, address(this));
        emit Unstake(msg.sender, _marketId, _tokenId);
    }

    function _calculateMarketOutcome(uint256[] memory _marketOutcomeIds, uint256[] memory _marketOutcomes) private pure returns (uint256) {
        uint256 _winningOutcome;
        uint256 _winningAmount;
        for (uint256 i = 0; i < _marketOutcomes.length; i++) {
            if (_marketOutcomes[i] > _winningAmount) {
                _winningOutcome = _marketOutcomeIds[i];
                _winningAmount  = _marketOutcomes[i];
            }
        }
        return _winningOutcome;
    }

    function _slash(uint256 _tokenMarketId, uint256 _tokenOutcomeId, uint256 _tokenId) private {
        marketChallengerTokenOf_[msg.sender][_tokenMarketId].remove(_tokenId);
        marketTokenOf_[msg.sender][_tokenMarketId].remove(_tokenId);
        delete tokenAddr_[_tokenId];
        emit Slash(msg.sender, _tokenMarketId, _tokenOutcomeId, _tokenId);
    }

    function _sendSlashedTokenValueToDao(uint256 _marketId, uint256 _marketResolvedOutcomeId) private {
        (uint256 _slashedTokens, ) = _getSlashedAndRewardedTokens(_marketId, _marketResolvedOutcomeId);
        if (_slashedTokens > 0) {
            totalSupply_ -= _slashedTokens;
            IDAO(DAO).buyBack{value: _slashedTokens * 299 * DECIMALS / 100}();
            emit SendSlashedTokenToDAO(_marketId, _slashedTokens, _slashedTokens * 299 * DECIMALS / 100);
        }
    }

    function _getSlashedAndRewardedTokens(uint256 _marketId, uint256 _marketOutcome) private view returns (uint256 slashedTokens, uint256 winnerOutcomeStakes) {
        Market storage market = markets_[_marketId];
        uint256 _juryOutcome              = market.juryOutcome;
        uint256 _marketChallengerToken    = market.challengerToken;
        bool    _isChallengerTokenSlashed = _marketOutcome == _juryOutcome;

        slashedTokens = marketJuryStakes_[_marketId].getLength() - juryOutcomeCount_[_marketId][_marketOutcome];

        if (_isChallengerTokenSlashed) {
            slashedTokens += _marketChallengerToken;
            _marketChallengerToken = 0;
        }

        winnerOutcomeStakes = _marketChallengerToken + marketOutcomeCount_[_marketId][_marketOutcome];

        slashedTokens += marketStakes_[_marketId].getLength() - market.marketReveals; // Total slashed tokens including tokens not revealed
    }

    function _getResolvedMarketOutcome(uint256 _marketId) private view returns (uint256) {
        Market storage market = markets_[_marketId];
        if (!market.marketResolved)    return 0;
        if (market.votingOutcome != 0) return market.votingOutcome;
        if (market.juryOutcome != 0)   return market.juryOutcome;
        return IClouded(CLOUDED).getMarketWinningOutcome(_marketId);
    }

    function _claimCreatorToken(uint256 _tokenMarketId, uint256 _currentTokenId) private {
        marketCreatorTokenOf_[msg.sender][_tokenMarketId].remove(_currentTokenId);
        _update(msg.sender, _currentTokenId, address(this));
        emit ClaimCreatorToken(msg.sender, _tokenMarketId, _currentTokenId);
    }

    function _claimChallengerReward(uint256 _tokenMarketId, uint256 _currentTokenId, uint256 _totalOutcomeStakes) private {
        marketChallengerTokenOf_[msg.sender][_tokenMarketId].remove(_currentTokenId);
        _update(msg.sender, _currentTokenId, address(this));

        uint256 _challengerReward = IClouded(CLOUDED).claimJuryReward(msg.sender, _tokenMarketId, _totalOutcomeStakes);

        emit ClaimChallengerReward(msg.sender, _tokenMarketId, _currentTokenId, _challengerReward);
    }

    error NotAuthorized();
    error Whitelisted();
    error ZeroAmount();
    error InvalidId();
    error RefundFailed();
    error NoTokenSelected();
    error OutcomeRevealed();
    error WrongCommitHash();
    error NoCommitHash();
    error MarketEnded();
    error MarketNotEnded();
    error JuryWindowEnded();
    error AppealWindowEnded();
    error MarketAlreadyChallenged();
    error NotOwner(uint256 tokenId);
    error NotStakedByOwner(uint256 tokenId);
    error JurySelected(bool selected);
    error MarketResolved(bool resolved);
    error InsufficientPayment();
    error StakeRequiredAmounts();
}