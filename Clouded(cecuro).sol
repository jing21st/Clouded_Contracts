// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
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
    function isSet(Set storage set, uint256 _id) internal view returns (bool) { return set.positions[_id] != 0; }
    function getId(Set storage set, uint256 _position) internal view returns (uint256) { return set.ids[_position]; }
    function getAll(Set storage set) internal view returns (uint256[] memory) { return set.ids; }
    function getLength(Set storage set) internal view returns (uint256) { return set.ids.length; }
}
interface IManager { function getFounderTokenAddr() external view returns (address); }
interface IJury {
    function DAO() external view returns (address);
    function updateURI(string memory) external;
    function updateDAOAddr(address) external;
    function updatePythAddr(address) external;
    function updateCloudedAddr(address) external;
    function updateMarketStatus(uint256) external returns (uint8);
    function getMarketInfo(uint256 _marketId) external view returns (
        uint256 marketTalliedTS, 
        uint256 marketRevealedTS, 
        uint256 juryOutcomeUpdatedTS, 
        uint256 marketChallengedTS, 
        uint256 juryOutcome, 
        uint256 votingOutcome, 
        uint256 resolvedOutcome, 
        bool marketResolved, 
        bool incentivized, 
        uint8 status
    );
    function publicLaunch() external;
}
interface IClouded {
    function nextMarketId() external view returns (uint256);
    function getMarketEndAt(uint256) external view returns (uint256);
    function getOutcomeMarketId(uint256) external view returns (uint256);
    function getMarketOutcomeIds(uint256) external view returns (uint256[] memory);
    function getMarketWinningOutcome(uint256) external view returns (uint256);
    function getPriceAppreciation(uint256, bool, uint256) external view returns (uint256);
    function createMarket(string memory, string memory, string[] memory, uint256) external returns (uint256[] memory);
    function claimCreatorReward(address, uint256, uint256) external returns (uint256);
    function claimJuryReward(address, uint256, uint256) external returns (uint256);
    function buy(address, uint256, uint256, uint256, uint256, uint256) external payable;
    function updateURI(string memory) external;
}
interface IDAO {
    function mint(address, uint256) external;
    function outcomeVotes(uint256) external view returns (uint256);
    function buyBack() external payable;
}
interface IPyth {
    function getFee() external view returns (uint256);
    function marketRandomNumber(uint256) external view returns (bytes32);
    function requestRandomNumber(uint256, uint256) external payable;
}
interface IEntropyV2 {
    function getFeeV2() external view returns (uint256 fee);
    function requestV2() external payable returns (uint64 assignedSequenceNumber);
    function getDefaultProvider() external view returns (address provider);
}
interface IHyperSwapV2Router {
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint amountOutMin, address[] calldata path, address to, address referrer, uint deadline) external payable;
}
contract CloudedFounderToken is ERC20 { constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) { _mint(msg.sender, 1e8 * 10 ** decimals()); } }
contract CloudedManager {
    event Blacklist(uint256 indexed _marketId, bool _isBlacklisted);
    IERC20 public founderToken;
    address public CLOUDED;
    address public JURY;
    mapping(uint256 => bool) public marketBlacklisted;
    modifier isLowerAuthority() { require(founderToken.balanceOf(msg.sender) >= founderToken.totalSupply() / 5, "Not authorized"); _; }
    modifier isHigherAuthority() { require(founderToken.balanceOf(msg.sender) >= founderToken.totalSupply() / 2, "Not authorized"); _; }
    constructor(address _founderTokenAddr) { founderToken = IERC20(_founderTokenAddr); }
    function getFounderTokenAddr() external view returns (address) { return address(founderToken); }
    function blacklist(uint256 _marketId, bool _blacklist) external isLowerAuthority {
        if (_blacklist) marketBlacklisted[_marketId] = true;
        else marketBlacklisted[_marketId] = false;
        emit Blacklist(_marketId, _blacklist);
    }
    function updateJuryAddrs(address _juryAddr, address _daoAddr, address _cloudedAddr, address _pythAddr) external isHigherAuthority {
        if (JURY == address(0)) {
            JURY = _juryAddr;
            IJury(JURY).updateDAOAddr(_daoAddr);
            IJury(JURY).updatePythAddr(_pythAddr);
            IJury(JURY).updateCloudedAddr(_cloudedAddr);
        }
    }
    function updateFounderToken(address _newFounderTokenAddr) external isHigherAuthority { founderToken = IERC20(_newFounderTokenAddr); }
    function updateCloudedAddr(address _cloudedAddr) external isHigherAuthority { if (CLOUDED == address(0)) CLOUDED = _cloudedAddr; }
    function updateCloudedURI(string memory _newURI) external isHigherAuthority { IClouded(CLOUDED).updateURI(_newURI); }
    function updateJuryURI(string memory _newURI) external isHigherAuthority { IJury(JURY).updateURI(_newURI); }
    function updateWhitelisted() external isHigherAuthority { IJury(JURY).publicLaunch(); }
}
contract CloudedJury is ERC721, ReentrancyGuardTransient {
    using Ids for Ids.Set;
    event Stake(address indexed staker, uint256 indexed marketId, uint256 indexed tokenId);
    event Unstake(address indexed staker, uint256 indexed marketId, uint256 indexed tokenId);
    event CreateMarket(address indexed marketCreator, uint256 indexed marketId, uint256[] tokenIds);
    event Tally(uint256 indexed marketId, uint256 marketTalliedTS, uint256 pythFee);
    event SelectJury(uint256 indexed marketId, uint256 juryTokens, uint256[] jurySet);
    event UpdateJuryOutcome(uint256 indexed marketId, uint256 juryOutcome, uint256 timestamp);
    event Challenge(address indexed challenger, uint256 indexed marketId, uint256 indexed tokenId);
    event ResolveMarket(uint256 indexed marketId, bool isMarketChallenged, bool isMarketIncentivized, uint256 juryOutcomeId, uint256 votingOutcomeId);
    event ClaimCreatorReward(address indexed creator, uint256 indexed marketId, uint256 indexed tokenId, uint256 creatorReward);
    event ClaimChallengerReward(address indexed challenger, uint256 indexed marketId, uint256 indexed tokenId, uint256 challengerReward);
    event ClaimJuryReward(address indexed staker, uint256 indexed marketId, uint256 indexed tokenId, uint256 tokenReward);
    event Slash(address indexed staker, uint256 indexed marketId, uint256 outcomeId, uint256 tokenId);
    event SendSlashedTokenToDAO(uint256 indexed marketId, uint256 tokens, uint256 tokenValue);
    event PublicLaunch();
    uint256 constant DECIMALS = 1e18;
    uint256 constant ENTROPY_TIMEOUT = 5 minutes;
    address constant MANAGER = ; // Update after contract deployment
    address public CLOUDED;
    address public PYTH;
    address public DAO;
    bool public whitelisted;
    string private uri_;
    uint256 private nextTokenId_;
    uint256 private totalSupply_;
    Ids.Set private allOngoingMarketIds_;
    Ids.Set private allResolvedMarketIds_;
    uint256 private allOngoingMarketStakes_; // For calculating if a market is incentivized
    mapping(uint256 => Market) private markets_;
    mapping(address => Ids.Set) private tokenOf_;
    mapping(address => Ids.Set) private marketOf_; // Markets that stakers participate which include staking, creating, challenging
    mapping(address => mapping(uint256 => Ids.Set)) private marketTokenOf_;
    mapping(address => mapping(uint256 => Ids.Set)) private marketCreatorTokenOf_;
    mapping(address => mapping(uint256 => Ids.Set)) private marketChallengerTokenOf_;
    mapping(address => mapping(uint256 => bytes32)) private marketCommitHashOf_;
    mapping(address => mapping(uint256 => bool)) private marketHasRevealedOf_;
    mapping(address => mapping(uint256 => uint256)) private marketOutcomeOf_;
    mapping(uint256 => Ids.Set) private marketStakes_; // total stakes in the market excluding creator and challenger tokens
    mapping(uint256 => Ids.Set) private marketJuryStakes_; // total stakes picked as jury
    mapping(uint256 => uint256) private marketJuryReveals_; // The amount of stakes in the jury revealed
    mapping(uint256 => uint256) private marketCreatorTokens_; // For calculating creator reward
    mapping(uint256 => uint256) private marketChallengerToken_; // For calculating challenger reward
    mapping(uint256 => mapping(uint256 => uint256)) private juryOutcomeCount_; // The amount of stakes in the jury. marketId → outcomeId → count
    struct Market {
        uint256 marketTalliedTS;
        uint256 marketRevealedTS;
        uint256 juryOutcomeUpdatedTS;
        uint256 marketChallengedTS;
        uint256 juryOutcome;
        uint256 votingOutcome;
        bool marketResolved; // Track if any token slashed and move fund to DAO
        bool incentivized;
        Status status;
    }
    enum Status {
        ONGOING, 
        JURY, 
        APPEAL, 
        VOTING, 
        SETTLED
    }
    modifier isManager() { require(msg.sender == MANAGER, "Not authorized"); _; }
    constructor(string memory _name, string memory _symbol) ERC721(_name, _symbol) {
        whitelisted = true;
        nextTokenId_ = 1;
    }
    function tokenURI(uint256) public view override returns (string memory) { return uri_; }
    function publicLaunch() external isManager { whitelisted = false; emit PublicLaunch(); }
    function updateURI(string memory _newURI) external isManager { uri_ = _newURI; }
    function updateDAOAddr(address _daoAddr) external isManager { DAO = _daoAddr; }
    function updatePythAddr(address _pythAddr) external isManager { PYTH = _pythAddr; }
    function updateCloudedAddr(address _cloudedAddr) external isManager { CLOUDED = _cloudedAddr; }
    function updateMarketStatus(uint256 _marketId) external returns (uint8) { return uint8(_updateMarketStatus(_marketId)); }
    function getAllOngoingMarketIds() external view returns (uint256[] memory) { return allOngoingMarketIds_.getAll(); }
    function getCurrentCreateMarketPrice() external view returns (uint256) { return _getCurrentCreateMarketPrice(); }
    function getMarketInfo(uint256 _marketId) external view returns (uint256 marketTalliedTS, uint256 marketRevealedTS, uint256 juryOutcomeUpdatedTS, uint256 marketChallengedTS, uint256 juryOutcome, uint256 votingOutcome, uint256 resolvedOutcome, bool marketResolved, bool incentivized, uint8 status) {
        Market storage market = markets_[_marketId];
        marketTalliedTS       = market.marketTalliedTS;
        marketRevealedTS      = market.marketRevealedTS;
        juryOutcomeUpdatedTS  = market.juryOutcomeUpdatedTS;
        marketChallengedTS    = market.marketChallengedTS;
        juryOutcome           = market.juryOutcome;
        votingOutcome         = market.votingOutcome;
        resolvedOutcome       = _getResolvedMarketOutcome(_marketId);
        marketResolved        = market.marketResolved;
        incentivized          = market.incentivized;
        Status _currentMarketStatus = _getMarketStatus(_marketId);
        status = uint8(_currentMarketStatus > market.status ? _currentMarketStatus : market.status);
    }
    function mint(uint256 _amount) external payable nonReentrant {
        if (whitelisted) {
            address _founderTokenAddr = IManager(MANAGER).getFounderTokenAddr();
            require(IERC20(_founderTokenAddr).balanceOf(msg.sender) >= IERC20(_founderTokenAddr).totalSupply() / 5, "Whitelisted");
        }
        require(_amount > 0, "Amount must be greater than 0");
        uint256 _mintPrice = 3 * _amount * DECIMALS; // The price for minting an NFT is 3 $HYPE
        require(msg.value >= _mintPrice, "Insufficient payment");
        for (uint256 i = 0; i < _amount; i++) {
            _mint(msg.sender, nextTokenId_);
            totalSupply_++;
            nextTokenId_++;
        }
        uint256 _refund = msg.value - _mintPrice;
        if (_refund > 0) {
            (bool _success, ) = msg.sender.call{value: _refund}("");
            require(_success, "Refund failed");
        }
    }
    function redeem(uint256[] memory _tokenIds) external nonReentrant {
        uint256 _amount;
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            if (ownerOf(_tokenIds[i]) != msg.sender) continue;
            _burn(_tokenIds[i]);
            totalSupply_--;
            _amount++;
        }
        uint256 _refund = 3 * _amount * DECIMALS;
        if (_refund > 0) {
            (bool _success, ) = msg.sender.call{value: _refund}("");
            require(_success, "Refund failed");
        }
    }
    function stake(uint256 _marketId, uint256[] memory _tokenIds, bytes32 _commitHash) external nonReentrant {
        require(_updateMarketStatus(_marketId) == Status.ONGOING, "Market ended");
        for (uint256 i = 0; i < _tokenIds.length; i++) { _stake(_marketId, _tokenIds[i]); }
        marketCommitHashOf_[msg.sender][_marketId] = _commitHash;
    }
    function unstake(uint256 _marketId, uint256[] memory _tokenIds) external nonReentrant {
        require(_updateMarketStatus(_marketId) == Status.ONGOING, "Market ended");
        Ids.Set storage marketTokenOf = marketTokenOf_[msg.sender][_marketId];
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            if (!marketTokenOf.isSet(_tokenIds[i])) continue;
            _unstake(_marketId, _tokenIds[i]);
            allOngoingMarketStakes_--;
        }
    }
    function createMarket(string memory _name, string memory _rule, string[] memory _outcomes, uint256 _days, uint256[] memory _tokenIds, uint256 _outcomePosition, uint256 _shares) external payable nonReentrant {
        require(_outcomePosition > 0 && _outcomePosition <= _outcomes.length, "Outcome position out of bound");
        uint256 _requiredTokenAmount = _getCurrentCreateMarketPrice();
        require(_tokenIds.length >= 5 && _tokenIds.length >= _requiredTokenAmount, "Insufficient payment");
        uint256 _nextMarketId = IClouded(CLOUDED).nextMarketId();
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            require(ownerOf(_tokenIds[i]) == msg.sender, "Not owner");
            _update(address(this), _tokenIds[i], msg.sender);
            marketCreatorTokenOf_[msg.sender][_nextMarketId].add(_tokenIds[i]);
        }
        allOngoingMarketIds_.add(_nextMarketId);
        marketCreatorTokens_[_nextMarketId] = _tokenIds.length;
        marketOf_[msg.sender].add(_nextMarketId);
        uint256[] memory _outcomeIds = IClouded(CLOUDED).createMarket(_name, _rule, _outcomes, _days);
        uint256 _outcomeId = _outcomeIds[_outcomePosition - 1];
        uint256 _executionPrice = IClouded(CLOUDED).getPriceAppreciation(_outcomeId, true, _shares);
        require(msg.value >= _executionPrice, "Insufficient payment");
        uint256 _refund = msg.value - _executionPrice;
        if (_refund > 0) {
            (bool _success, ) = msg.sender.call{value: _refund}("");
            require(_success, "Refund failed");
        }
        IClouded(CLOUDED).buy{value: _executionPrice}(msg.sender, _nextMarketId, _outcomeId, _shares, _executionPrice, 0);
        emit CreateMarket(msg.sender, _nextMarketId, _tokenIds);
    }
    function tally(uint256 _marketId) external payable nonReentrant {
        require(_updateMarketStatus(_marketId) == Status.JURY, "Jury window ended");
        require(marketStakes_[_marketId].getLength() != 0, "No token staked");
        Market storage market = markets_[_marketId];
        require(market.marketTalliedTS == 0, "Market tallied");
        market.marketTalliedTS = block.timestamp;
        uint256 _fee;
        try IPyth(PYTH).getFee() returns (uint256 fee) { _fee = fee; } catch {}
        require(msg.value >= _fee, "Insufficient payment");
        try IPyth(PYTH).requestRandomNumber{value: _fee}(_marketId, _fee) {
            uint256 _refund = msg.value - _fee;
            if (_refund > 0) {
                (bool _success, ) = msg.sender.call{value: _refund}("");
                require(_success, "Refund failed");
            }
        } catch {
            if (msg.value > 0) {
                (bool _success, ) = msg.sender.call{value: msg.value}("");
                require(_success, "Refund failed");
            }
        }
        emit Tally(_marketId, market.marketTalliedTS, _fee);
    }
    function selectJury(uint256 _marketId) external nonReentrant {
        require(markets_[_marketId].marketTalliedTS != 0, "Market not tallied");
        require(marketJuryStakes_[_marketId].getLength() == 0, "Jury selected");
        require(_updateMarketStatus(_marketId) == Status.JURY, "Jury window ended");
        bytes32 _randomNumber = IPyth(PYTH).marketRandomNumber(_marketId);
        if (_randomNumber == 0) {
            require(block.timestamp > markets_[_marketId].marketTalliedTS + ENTROPY_TIMEOUT, "Waiting Entropy callback");
            _randomNumber = keccak256(abi.encodePacked(blockhash(block.number - 1), blockhash(block.number - 2), blockhash(block.number - 3), block.timestamp, _marketId));
        }
        uint256 _totalStakedTokens = marketStakes_[_marketId].getLength();
        uint256 _jurySet = _totalStakedTokens < 5 ? 1 : _totalStakedTokens / 5 < 1000 ? _totalStakedTokens / 5 : 1000;
        uint256 _attempt;
        uint256 _position;
        uint256 _tokenId;
        while (_attempt < _jurySet) {
            _position = uint256(keccak256(abi.encodePacked(_randomNumber, marketStakes_[_marketId].getId(_attempt)))) % _totalStakedTokens;
            _tokenId = marketStakes_[_marketId].getId(_position);
            if (!marketJuryStakes_[_marketId].isSet(_tokenId)) { marketJuryStakes_[_marketId].add(_tokenId); }
            _attempt++;
        }
        emit SelectJury(_marketId, marketJuryStakes_[_marketId].getLength(), marketJuryStakes_[_marketId].getAll());
    }
    function juryRevealOutcome(uint256 _marketId, uint256 _outcomeId, bytes32 _salt) external nonReentrant {
        require(_updateMarketStatus(_marketId) == Status.JURY, "Jury window ended");
        require(!marketHasRevealedOf_[msg.sender][_marketId], "Outcome revealed");
        marketHasRevealedOf_[msg.sender][_marketId] = true;
        bytes32 _commitHash = marketCommitHashOf_[msg.sender][_marketId];
        require(_commitHash != 0, "No commit");
        require(keccak256(abi.encodePacked(msg.sender, _marketId, _outcomeId, _salt)) == _commitHash, "Wrong committed hash");
        marketOutcomeOf_[msg.sender][_marketId] = _outcomeId;
        Ids.Set storage marketJuryStakes = marketJuryStakes_[_marketId];
        require(marketJuryStakes.getLength() != 0, "No jury");
        for (uint256 i = 0; i < marketJuryStakes.getLength(); i++) {
            uint256 _currentTokenId = marketJuryStakes.getId(i);
            if (marketTokenOf_[msg.sender][_marketId].isSet(_currentTokenId)) {
                marketJuryReveals_[_marketId]++;
                juryOutcomeCount_[_marketId][_outcomeId]++;
            }
        }
        if (marketJuryReveals_[_marketId] == marketJuryStakes.getLength()) markets_[_marketId].marketRevealedTS = block.timestamp;
    }
    function updateJuryOutcome(uint256 _marketId) external nonReentrant {
        require(marketJuryStakes_[_marketId].getLength() != 0, "Jury not selected");
        require(_updateMarketStatus(_marketId) == Status.APPEAL, "Appeal window ended");
        Market storage market = markets_[_marketId];
        require(market.juryOutcomeUpdatedTS == 0, "Outcome already updated");
        market.juryOutcomeUpdatedTS = block.timestamp;
        uint256[] memory _marketOutcomeIds = IClouded(CLOUDED).getMarketOutcomeIds(_marketId);
        uint256[] memory _marketOutcomes = new uint256[](_marketOutcomeIds.length);
        for (uint256 i = 0; i < _marketOutcomeIds.length; i++) { _marketOutcomes[i] = juryOutcomeCount_[_marketId][_marketOutcomeIds[i]]; }
        market.juryOutcome = _calculateMarketOutcome(_marketOutcomeIds, _marketOutcomes);
        emit UpdateJuryOutcome(_marketId, market.juryOutcome, market.juryOutcomeUpdatedTS);
    }
    // Challenge can only be made once every market. The token will be rewarded if the voters also agree with the same outcome, but will be slashed for being wrong.
    function challenge(uint256 _marketId, uint256 _tokenId) external nonReentrant {
        require(_updateMarketStatus(_marketId) == Status.APPEAL, "Appeal window ended");
        require(marketJuryStakes_[_marketId].getLength() != 0, "No jury");
        require(ownerOf(_tokenId) == msg.sender, "Not owner");
        Market storage market = markets_[_marketId];
        require(market.juryOutcomeUpdatedTS != 0, "Jury outcome not updated");
        require(market.marketChallengedTS == 0, "Market already challenged");
        require(market.juryOutcome != 0, "No jury outcome");
        market.marketChallengedTS = block.timestamp;
        marketOf_[msg.sender].add(_marketId);
        marketChallengerTokenOf_[msg.sender][_marketId].add(_tokenId);
        marketChallengerToken_[_marketId]++;
        _update(address(this), _tokenId, msg.sender);
        emit Challenge(msg.sender, _marketId, _tokenId);
    }
    function resolveMarket(uint256 _marketId) external nonReentrant {
        require(_updateMarketStatus(_marketId) == Status.SETTLED, "Market not ended");
        Market storage market = markets_[_marketId];
        require(!market.marketResolved, "Market resolved");
        market.marketResolved = true;
        if (allOngoingMarketStakes_ > 0) _checkIncentivized(_marketId);
        allOngoingMarketIds_.remove(_marketId);
        allResolvedMarketIds_.add(_marketId);
        bool _isMarketChallenged = market.marketChallengedTS != 0;
        if (_isMarketChallenged) {
            uint256[] memory _marketOutcomeIds = IClouded(CLOUDED).getMarketOutcomeIds(_marketId);
            uint256[] memory _marketOutcomes = new uint256[](_marketOutcomeIds.length);
            for (uint256 i = 0; i < _marketOutcomeIds.length; i++) _marketOutcomes[i] = IDAO(DAO).outcomeVotes(_marketOutcomeIds[i]);
            market.votingOutcome = _calculateMarketOutcome(_marketOutcomeIds, _marketOutcomes);
        }
        uint256 _resolvedOutcomeId = _getResolvedMarketOutcome(_marketId);
        _sendSlashedTokenValueToDao(_marketId, _resolvedOutcomeId);
        emit ResolveMarket(_marketId, _isMarketChallenged, market.incentivized, market.juryOutcome, market.votingOutcome);
    }
    function claimReward(uint256 _marketId, uint256[] memory _tokenIds) external nonReentrant {
        require(_updateMarketStatus(_marketId) == Status.SETTLED, "Market not ended");
        require(markets_[_marketId].marketResolved, "Market not resolved");
        uint256 _currentTokenId;
        Market storage market = markets_[_marketId];
        uint256 _marketOutcome = _getResolvedMarketOutcome(_marketId);
        (, uint256 _totalWinnerOutcomeStakes) = _getSlashedAndRewardedTokens(_marketId, _marketOutcome);
        uint256 _juryOutcomeOf = marketOutcomeOf_[msg.sender][_marketId];
        Ids.Set storage marketTokenOf = marketTokenOf_[msg.sender][_marketId];
        Ids.Set storage marketCreatorTokenOf = marketCreatorTokenOf_[msg.sender][_marketId];
        Ids.Set storage marketChallengerTokenOf = marketChallengerTokenOf_[msg.sender][_marketId];
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            _currentTokenId = _tokenIds[i];
            if (marketCreatorTokenOf.isSet(_currentTokenId)) { _claimCreatorReward(_marketId, _currentTokenId, _totalWinnerOutcomeStakes); continue; }
            if (marketChallengerTokenOf.isSet(_currentTokenId)) {
                if (market.juryOutcome != _marketOutcome) { // market.juryOutcome can be 0 if challenged
                    _claimChallengerReward(_marketId, _currentTokenId, _totalWinnerOutcomeStakes);
                    if (market.incentivized) IDAO(DAO).mint(msg.sender, DECIMALS);
                } else _slash(_marketId, 0, _currentTokenId); // Challenger has no vote on market outcome
                continue;
            }
            if (!marketTokenOf.isSet(_currentTokenId)) continue; // The token is not creator token or challenger token. The token is not staked in the current market or belong to caller
            if (market.juryOutcome == 0) { _unstake(_marketId, _currentTokenId); continue; } // If the jury has been selected but the outcome has not yet been revealed or updated, return the staked token immediately to prevent jury assets from being permanently locked. Jury tokens can withdraw without reward and market resolved to the most popular outcome.
            if (marketJuryStakes_[_marketId].isSet(_currentTokenId)) {
                if (_juryOutcomeOf == 0) { _slash(_marketId, _juryOutcomeOf, _currentTokenId); continue; } // Slash token if not revealed
                if (markets_[_marketId].marketChallengedTS != 0) { // Is market challenged
                    if (_juryOutcomeOf == _marketOutcome) {
                        _unstake(_marketId, _currentTokenId);
                        if (market.incentivized) IDAO(DAO).mint(msg.sender, DECIMALS);
                        uint256 _tokenReward = IClouded(CLOUDED).claimJuryReward(msg.sender, _marketId, _totalWinnerOutcomeStakes);
                        emit ClaimJuryReward(msg.sender, _marketId, _currentTokenId, _tokenReward);
                    } else _slash(_marketId, _juryOutcomeOf, _currentTokenId);
                    continue;
                }
                if (_juryOutcomeOf == market.juryOutcome) {
                    _unstake(_marketId, _currentTokenId);
                    if (market.incentivized) IDAO(DAO).mint(msg.sender, DECIMALS);
                    uint256 _tokenReward = IClouded(CLOUDED).claimJuryReward(msg.sender, _marketId, _totalWinnerOutcomeStakes);
                    emit ClaimJuryReward(msg.sender, _marketId, _currentTokenId, _tokenReward);
                } else _slash(_marketId, _juryOutcomeOf, _currentTokenId);
                continue;
            }
            _unstake(_marketId, _currentTokenId); // Return staked tokens to non-jury members
        }
        if (marketCreatorTokenOf.getLength() == 0 && marketChallengerTokenOf.getLength() == 0 && marketTokenOf.getLength() == 0) marketOf_[msg.sender].remove(_marketId);
    }
    function _update(address _to, uint256 _tokenId, address _auth) internal override returns (address) {
        address from = super._update(_to, _tokenId, _auth);
        if (from != address(0)) tokenOf_[from].remove(_tokenId);
        if (_to != address(0)) tokenOf_[_to].add(_tokenId);
        return from;
    }
    function _getCurrentCreateMarketPrice() private view returns (uint256) { return totalSupply_ / 100; }
    function _updateMarketStatus(uint256 _marketId) private returns (Status) {
        require(_marketId > 0 && _marketId < IClouded(CLOUDED).nextMarketId(), "Market id out of bound");
        Market storage market = markets_[_marketId];
        Status _currentMarketStatus = _getMarketStatus(_marketId);
        if (_currentMarketStatus > market.status) market.status = _currentMarketStatus;
        return market.status;
    }
    function _getMarketStatus(uint256 _marketId) private view returns (Status) {
        uint256 _marketEndAt = IClouded(CLOUDED).getMarketEndAt(_marketId);
        return _getMarketStatus(_marketId, _marketEndAt);
    }
    function _getMarketStatus(uint256 _marketId, uint256 _marketEndAt) private view returns (Status) {
        Market storage market = markets_[_marketId];
        uint256 _currentTimestamp = block.timestamp;
        if (_currentTimestamp < _marketEndAt) return Status.ONGOING;
        if (market.marketRevealedTS == 0 && _currentTimestamp < _marketEndAt + 1 days) return Status.JURY;
        uint256 _challengeStart = market.marketRevealedTS != 0 ? market.marketRevealedTS : _marketEndAt + 1 days;
        if (market.marketChallengedTS != 0) return _currentTimestamp >= market.marketChallengedTS + 3 days ? Status.SETTLED : Status.VOTING;
        return _currentTimestamp < _challengeStart + 1 days ? Status.APPEAL : Status.SETTLED;
    }
    function _stake(uint256 _marketId, uint256 _tokenId) private {
        if (ownerOf(_tokenId) != msg.sender) return;
        allOngoingMarketStakes_++;
        marketStakes_[_marketId].add(_tokenId);
        marketTokenOf_[msg.sender][_marketId].add(_tokenId);
        marketOf_[msg.sender].add(_marketId);
        _update(address(this), _tokenId, msg.sender);
        emit Stake(msg.sender, _marketId, _tokenId);
    }
    function _unstake(uint256 _marketId, uint256 _tokenId) private {
        marketTokenOf_[msg.sender][_marketId].remove(_tokenId);
        marketStakes_[_marketId].remove(_tokenId);
        _update(msg.sender, _tokenId, address(this));
        emit Unstake(msg.sender, _marketId, _tokenId);
    }
    function _slash(uint256 _tokenMarketId, uint256 _tokenOutcomeId, uint256 _tokenId) private {
        marketChallengerTokenOf_[msg.sender][_tokenMarketId].remove(_tokenId);
        marketTokenOf_[msg.sender][_tokenMarketId].remove(_tokenId);
        _burn(_tokenId);
        emit Slash(msg.sender, _tokenMarketId, _tokenOutcomeId, _tokenId);
    }
    function _checkIncentivized(uint256 _marketId) private {
        uint256 _currentMarketStakes   = marketStakes_[_marketId].getLength();
        uint256 _currentMarketStakeBps = _currentMarketStakes * 10000 / allOngoingMarketStakes_;
        if (_currentMarketStakeBps > 5000) markets_[_marketId].incentivized = true;
        allOngoingMarketStakes_ -= _currentMarketStakes;
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
    function _getResolvedMarketOutcome(uint256 _marketId) private view returns (uint256) {
        Market storage market = markets_[_marketId];
        if (!market.marketResolved) return 0;
        if (market.votingOutcome != 0) return market.votingOutcome;
        if (market.juryOutcome != 0) return market.juryOutcome;
        return IClouded(CLOUDED).getMarketWinningOutcome(_marketId);
    }
    function _claimCreatorReward(uint256 _tokenMarketId, uint256 _currentTokenId, uint256 _totalOutcomeStakes) private {
        marketCreatorTokenOf_[msg.sender][_tokenMarketId].remove(_currentTokenId);
        _update(msg.sender, _currentTokenId, address(this));
        uint256 _creatorReward = IClouded(CLOUDED).claimCreatorReward(msg.sender, _tokenMarketId, _totalOutcomeStakes);
        emit ClaimCreatorReward(msg.sender, _tokenMarketId, _currentTokenId, _creatorReward);
    }
    function _claimChallengerReward(uint256 _tokenMarketId, uint256 _currentTokenId, uint256 _totalOutcomeStakes) private {
        marketChallengerTokenOf_[msg.sender][_tokenMarketId].remove(_currentTokenId);
        _update(msg.sender, _currentTokenId, address(this));
        uint256 _challengerReward = IClouded(CLOUDED).claimCreatorReward(msg.sender, _tokenMarketId, _totalOutcomeStakes);
        emit ClaimChallengerReward(msg.sender, _tokenMarketId, _currentTokenId, _challengerReward);
    }
    function _sendSlashedTokenValueToDao(uint256 _marketId, uint256 _marketResolvedOutcomeId) private {
        (uint256 _slashedTokens, ) = _getSlashedAndRewardedTokens(_marketId, _marketResolvedOutcomeId);
        totalSupply_ -= _slashedTokens;
        IDAO(DAO).buyBack{value: _slashedTokens * 3 * DECIMALS}();
        emit SendSlashedTokenToDAO(_marketId, _slashedTokens, _slashedTokens * 3 * DECIMALS);
    }
    function _getSlashedAndRewardedTokens(uint256 _marketId, uint256 _marketOutcome) private view returns (uint256 slashedTokens, uint256 winnerOutcomeStakes) {
        uint256 _juryOutcome = markets_[_marketId].juryOutcome;
        uint256 _juryStakes  = marketJuryStakes_[_marketId].getLength();
        uint256 _marketCreatorTokens   = marketCreatorTokens_[_marketId];
        uint256 _marketChallengerToken = marketChallengerToken_[_marketId];
        uint256 _resolvedOutcomeTokens = juryOutcomeCount_[_marketId][_marketOutcome];
        bool _isMarketChallenged       = markets_[_marketId].marketChallengedTS != 0;
        bool _isChallengerTokenSlashed = _isMarketChallenged && _marketOutcome == _juryOutcome;
        if (_juryOutcome == 0) return (0, _marketCreatorTokens);
        slashedTokens = _juryStakes - _resolvedOutcomeTokens;
        if (_isChallengerTokenSlashed) slashedTokens += marketChallengerToken_[_marketId];
        winnerOutcomeStakes = _juryStakes - slashedTokens + _marketCreatorTokens + _marketChallengerToken;
    }
}
abstract contract IEntropyConsumer {
    modifier onlyEntropy() { require(msg.sender == getEntropy(), "caller is not Entropy contract"); _; }
    function getEntropy() internal view virtual returns (address);
    function entropyCallback( uint64 sequenceNumber, address provider, bytes32 randomNumber) internal virtual;
    function _entropyCallback(uint64 sequenceNumber, address provider, bytes32 randomNumber) external onlyEntropy { entropyCallback(sequenceNumber, provider, randomNumber); }
}
contract PythEntropy is IEntropyConsumer {
    event RequestRandomNumber(uint256 indexed marketId, uint64 sequenceNumber, uint256 feePaid);
    event ReceiveRandomNumber(uint256 indexed marketId, uint64 sequenceNumber, bytes32 randomNumber, address provider);
    address constant JURY = ; // Update after contract deployment
    IEntropyV2 constant entropy = IEntropyV2(0xfA25E653b44586dBbe27eE9d252192F0e4956683);
    mapping(uint256 => bytes32) public marketRandomNumber;
    mapping(uint64 => uint256) private sequenceToMarket_;
    mapping(uint256 => bool)   private marketRequesting_;
    constructor() {}
    function currentProvider() external view returns (address) { return entropy.getDefaultProvider(); }
    function getFee() external view returns (uint256) { return entropy.getFeeV2(); }
    function getEntropy() internal view override returns (address) { return address(entropy); }
    function requestRandomNumber(uint256 _marketId, uint256 _fee) external payable {
        require(msg.sender == JURY, "Not authorized");
        require(!marketRequesting_[_marketId], "Currently requesting");
        marketRequesting_[_marketId] = true;
        uint64 _sequenceNumber = entropy.requestV2{value: _fee}();
        sequenceToMarket_[_sequenceNumber] = _marketId;
        emit RequestRandomNumber(_marketId, _sequenceNumber, _fee);
    }
    function entropyCallback(uint64 _sequenceNumber, address _provider, bytes32 _randomNumber) internal override {
        uint256 _marketId = sequenceToMarket_[_sequenceNumber];
        marketRandomNumber[_marketId] = _randomNumber;
        delete sequenceToMarket_[_sequenceNumber];
        emit ReceiveRandomNumber(_marketId, _sequenceNumber, _randomNumber, _provider);
    }
}
contract Clouded is ERC1155, ReentrancyGuardTransient {
    using Ids for Ids.Set;
    event Buy(address indexed buyer, uint256 indexed marketId, uint256 indexed outcomeId, uint256 shares, uint256 marketExecutionPrice, uint256 outcomeExecutionPrice, uint256 totalExecutionPrice, uint256 frontendPrice, uint256 slippageBPS, uint256 maxPrice, uint256 refund);
    event Sell(address indexed seller, uint256 indexed marketId, uint256 indexed outcomeId, uint256 shares, uint256 refund, uint256 frontendPrice, uint256 slippageBPS, uint256 minRefund);
    event ClaimTraderReward(address indexed trader, uint256 indexed marketId, uint256 winningOutcome, uint256 totalReward, uint256 traderReward);
    uint256 constant B = 1;
    uint256 constant DECIMALS = 1e18;
    address constant MANAGER = ; // Update after contract deployment
    address constant JURY = ; // Update after contract deployment
    uint256 public nextMarketId;
    uint256 public nextOutcomeId;
    mapping(uint256 => Market) private markets_;
    mapping(uint256 => Outcome) private outcomes_;
    mapping(address => Ids.Set) private traderOutcomes_;
    mapping(address => mapping(uint256 => AvgPrice)) private traderOutcomeAvgCost_;
    mapping(address => mapping(uint256 => AvgPrice)) private traderOutcomeAvgSell_;
    mapping(address => mapping(uint256 => int256)) private traderOutcomePnl_;
    struct Market {
        string name;
        string rule;
        uint256[] outcomeIds;
        uint256 startAt;
        uint256 daysOf;
        uint256 shares;
        uint256 bondingPool; // Accumulated bonding curve deposits. Refundable via sell during market; at settlement, distributed proportionally to winners.
        uint256 prizePool; // Fixed buy-in contributions from all traders. Non-refundable. Combined with prizePool, Distributed to winners at settlement.
    }
    struct Outcome {
        uint256 marketId;
        string name;
        uint256 shares;
    }
    struct AvgPrice {
        uint256 shares;
        uint256 avgPrice;
    }
    modifier isJury() { require(msg.sender == JURY, "Not authorized"); _; }
    constructor(string memory _uri) ERC1155(_uri) {
        nextMarketId = 1;
        nextOutcomeId = 1;
    }
    function getMarketEndAt(uint256 _marketId) external view returns (uint256) { return markets_[_marketId].startAt + markets_[_marketId].daysOf; }
    function getMarketOutcomeIds(uint256 _marketId) external view returns (uint256[] memory) { return markets_[_marketId].outcomeIds; }
    function getOutcomeMarketId(uint256 _outcomeId) external view returns (uint256) { return outcomes_[_outcomeId].marketId; }
    function getMarketWinningOutcome(uint256 _marketId) external view returns (uint256) { return _getMarketWinningOutcome(_marketId); } // The function returns the outcome with most shares in a market
    function getMarketTotalReward(uint256 _marketId) external view returns (uint256) { return _getMarketTotalReward(_marketId); }
    function getPriceAppreciation(uint256 _outcomeId, bool _buy, uint256 _shares) external view returns (uint256) {
        uint256 _marketId = outcomes_[_outcomeId].marketId;
        uint256 _marketTotalShares  = markets_[_marketId].shares;
        uint256 _outcomeTotalShares = outcomes_[_outcomeId].shares;
        require(_buy || _outcomeTotalShares >= _shares, "Exceed outcome total shares");
        uint256 _marketExecutionPrice  = _getPriceAppreciation(_marketTotalShares, _buy, _shares) / 2;
        uint256 _outcomeExecutionPrice = _getPriceAppreciation(_outcomeTotalShares, _buy, _shares) / 2;
        if (_buy) return _marketExecutionPrice + _outcomeExecutionPrice;
        else return _marketExecutionPrice;
    }
    function updateURI(string memory _newURI) external nonReentrant {
        require(msg.sender == MANAGER, "Not authorized");
        _setURI(_newURI);
    }
    function createMarket(string memory _name, string memory _rule, string[] memory _outcomes, uint256 _days) external nonReentrant isJury returns (uint256[] memory) {
        require(bytes(_name).length >= 10 && bytes(_name).length <= 200, "Name out of bound");
        require(bytes(_rule).length <= 4000, "Rule out of bound");
        require(_outcomes.length >= 2 && _outcomes.length <= 64, "Outcomes out of bound");
        require(_days >= 1 && _days <= 365, "At least 1 day and within 1 year");
        markets_[nextMarketId].name = _name;
        markets_[nextMarketId].rule = _rule;
        for (uint256 i = 0; i < _outcomes.length; i++) {
            markets_[nextMarketId].outcomeIds.push(nextOutcomeId);
            outcomes_[nextOutcomeId].marketId = nextMarketId;
            outcomes_[nextOutcomeId].name = _outcomes[i];
            nextOutcomeId++;
        }
        markets_[nextMarketId].startAt = block.timestamp;
        markets_[nextMarketId].daysOf  = _days * 1 days;
        nextMarketId++;
        return markets_[nextMarketId - 1].outcomeIds;
    }
    function buy(address _msgSender, uint256 _outcomeMarketId, uint256 _outcomeId, uint256 _shares, uint256 _frontendPrice, uint256 _slippageBPS) external payable isJury { _buy(_msgSender, _outcomeMarketId, _outcomeId, _shares, _frontendPrice, _slippageBPS); }
    function buy(uint256 _outcomeId, uint256 _shares, uint256 _frontendPrice, uint256 _slippageBPS) external payable nonReentrant {
        uint256 _outcomeMarketId = outcomes_[_outcomeId].marketId;
        require(IJury(JURY).updateMarketStatus(_outcomeMarketId) == 0, "Market ended");
        require(_outcomeMarketId > 0 && _outcomeMarketId < nextMarketId, "Market id out of bound");
        _buy(msg.sender, _outcomeMarketId, _outcomeId, _shares, _frontendPrice, _slippageBPS);
    }
    function _buy(address _msgSender, uint256 _outcomeMarketId, uint256 _outcomeId, uint256 _shares, uint256 _frontendPrice, uint256 _slippageBPS) private {
        require(_shares > 0, "Shares cannot be 0");
        require(_slippageBPS <= 2000, "Exceed max slippage");
        uint256 _marketExecutionPrice  = _getPriceAppreciation(markets_[_outcomeMarketId].shares, true, _shares) / 2;
        uint256 _outcomeExecutionPrice = _getPriceAppreciation(outcomes_[_outcomeId].shares, true, _shares) / 2;
        uint256 _totalExecutionPrice   = _marketExecutionPrice + _outcomeExecutionPrice;
        uint256 _maxPrice = _frontendPrice * (10000 + _slippageBPS) / 10000;
        require(_totalExecutionPrice <= _maxPrice, "Exceed slippage");
        require(msg.value >= _totalExecutionPrice, "Insufficient payment");
        _calculateAvgCost(_msgSender, _outcomeId, true, _shares, _totalExecutionPrice);
        markets_[_outcomeMarketId].shares += _shares;
        markets_[_outcomeMarketId].bondingPool += _marketExecutionPrice;
        markets_[_outcomeMarketId].prizePool += _outcomeExecutionPrice;
        outcomes_[_outcomeId].shares += _shares;
        _mint(_msgSender, _outcomeId, _shares, "");
        traderOutcomes_[_msgSender].add(_outcomeId);
        uint256 _refund = msg.value - _totalExecutionPrice;
        if (_refund > 0) {
            (bool _success, ) = address(_msgSender).call{value: _refund}("");
            require(_success, "Refund failed");
        }
        emit Buy(_msgSender, _outcomeMarketId, _outcomeId, _shares, _marketExecutionPrice, _outcomeExecutionPrice, _totalExecutionPrice, _frontendPrice, _slippageBPS, _maxPrice, _refund);
    }
    function sell(uint256 _outcomeId, uint256 _shares, uint256 _frontendPrice, uint256 _slippageBPS) external nonReentrant {
        uint256 _outcomeMarketId = outcomes_[_outcomeId].marketId;
        require(_outcomeMarketId > 0 && _outcomeMarketId < nextMarketId, "Market id out of bound");
        require(IJury(JURY).updateMarketStatus(_outcomeMarketId) == 0, "Market ended");
        require(balanceOf(msg.sender, _outcomeId) >= _shares, "Insufficient balance");
        require(_shares > 0, "Shares cannot be 0");
        require(_slippageBPS <= 2000, "Exceed max slippage");
        uint256 _marketShares = markets_[_outcomeMarketId].shares;
        uint256 _refund = _getPriceAppreciation(_marketShares, false, _shares) / 2;
        uint256 _minRefund = _frontendPrice * (10000 - _slippageBPS) / 10000;
        require(_refund >= _minRefund, "Exceed slippage");
        _calculateAvgSell(msg.sender, _outcomeId, _shares, _refund);
        _calculateAvgCost(msg.sender, _outcomeId, false, _shares, _refund);
        markets_[_outcomeMarketId].shares -= _shares;
        markets_[_outcomeMarketId].bondingPool -= _refund;
        outcomes_[_outcomeId].shares -= _shares;
        _burn(msg.sender, _outcomeId, _shares);
        if (balanceOf(msg.sender, _outcomeId) == 0) traderOutcomes_[msg.sender].remove(_outcomeId);
        if (_refund > 0) {
            (bool _success, ) = msg.sender.call{value: _refund}("");
            require(_success, "Refund failed");
        }
        emit Sell(msg.sender, _outcomeMarketId, _outcomeId, _shares, _refund, _frontendPrice, _slippageBPS, _minRefund);
    }
    function claimReward(uint256 _marketId) external nonReentrant {
        require(IJury(JURY).updateMarketStatus(_marketId) == 4, "Market not ended");
        (, , , , uint256 _juryOutcomeId, uint256 _votingOutcomeId, , bool _marketResolved, , ) = IJury(JURY).getMarketInfo(_marketId);
        require(_marketResolved, "Market not resolved");
        uint256 _resolvedOutcome;
        if (_votingOutcomeId != 0)    _resolvedOutcome = _votingOutcomeId;
        else if (_juryOutcomeId != 0) _resolvedOutcome = _juryOutcomeId;
        else                          _resolvedOutcome = _getMarketWinningOutcome(_marketId);
        uint256[] memory _outcomeIds = markets_[_marketId].outcomeIds;
        for (uint256 i = 0; i < _outcomeIds.length; i++) {
            uint256 _traderShares = balanceOf(msg.sender, _outcomeIds[i]);
            if (_traderShares == 0) continue;
            _burn(msg.sender, _outcomeIds[i], _traderShares);
            traderOutcomes_[msg.sender].remove(_outcomeIds[i]);
            if (_outcomeIds[i] == _resolvedOutcome) _calculateTraderReward(_marketId, _resolvedOutcome, _traderShares);
        }
    }
    function claimCreatorReward(address _creatorAddr, uint256 _tokenMarketId, uint256 _totalOutcomeStakes) external nonReentrant isJury returns (uint256 creatorReward) {
        uint256 _marketTotalReward = _getMarketTotalReward(_tokenMarketId);
        creatorReward = _marketTotalReward / 10 / _totalOutcomeStakes;
        if (creatorReward > 0) {
            (bool _success, ) = address(_creatorAddr).call{value: creatorReward}("");
            require(_success, "Creator refund failed");
        }
    }
    function claimJuryReward(address _msgSender, uint256 _tokenMarketId, uint256 _totalWinnerOutcomeStakes) external nonReentrant isJury returns (uint256 tokenReward) {
        uint256 _marketTotalReward = _getMarketTotalReward(_tokenMarketId);
        tokenReward =  _marketTotalReward / 10 / _totalWinnerOutcomeStakes;
        if (tokenReward > 0) {
            (bool _success, ) = address(_msgSender).call{value: tokenReward}("");
            require(_success, "Jury refund failed");
        }
    }
    function _getPriceAppreciation(uint256 _idTotalShares, bool _buy, uint256 _shares) private pure returns (uint256) {
        uint256 _sharesAfter = _buy ? _idTotalShares + _shares : _idTotalShares - _shares;
        uint256 _sharesAfterSquared  = _sharesAfter * _sharesAfter;
        uint256 _sharesBeforeSquared = _idTotalShares * _idTotalShares;
        return _buy ? B * (_sharesAfterSquared - _sharesBeforeSquared) * DECIMALS / 2 / 10000 : B * (_sharesBeforeSquared - _sharesAfterSquared) * DECIMALS / 2 / 10000;
    }
    function _getMarketWinningOutcome(uint256 _marketId) private view returns (uint256) {
        uint256 _currentOutcomeId;
        uint256 _winningOutcomeShares;
        uint256 _winningOutcomeId;
        for (uint256 i = 0; i < markets_[_marketId].outcomeIds.length; i++) {
            _currentOutcomeId = markets_[_marketId].outcomeIds[i];
            if (outcomes_[_currentOutcomeId].shares > _winningOutcomeShares) {
                _winningOutcomeShares = outcomes_[_currentOutcomeId].shares;
                _winningOutcomeId = _currentOutcomeId;
            }
        }
        return _winningOutcomeId;
    }
    function _getMarketTotalReward(uint256 _marketId) private view returns (uint256) { return markets_[_marketId].bondingPool + markets_[_marketId].prizePool; }
    function _calculateTraderReward(uint256 _marketId, uint256 _winningOutcomeId, uint256 _traderShares) private {
        uint256 _totalReward = _getMarketTotalReward(_marketId);
        uint256 _traderReward = _calculateOutcomeReward(_traderShares, _totalReward, outcomes_[_winningOutcomeId].shares);
        if (_traderReward > 0) {
            (bool _success, ) = msg.sender.call{value: _traderReward}("");
            require(_success, "Refund failed");
        }
        _calculateAvgSell(msg.sender, _winningOutcomeId, _traderShares, _traderReward);
        _calculateAvgCost(msg.sender, _winningOutcomeId, false, _traderShares, _traderReward);
        emit ClaimTraderReward(msg.sender, _marketId, _winningOutcomeId, _totalReward, _traderReward);
    }
    function _calculateOutcomeReward(uint256 _traderShares, uint256 _pool, uint256 _outcomeShares) private pure returns (uint256) { return _traderShares * _pool * 9 / _outcomeShares / 10; }
    function _calculateAvgCost(address _traderAddr, uint256 _outcomeId, bool _isBuy, uint256 _shares, uint256 _price) private {
        AvgPrice storage traderOutcomeAvgCost = traderOutcomeAvgCost_[_traderAddr][_outcomeId];
        if (_isBuy) {
            traderOutcomeAvgCost.avgPrice = (traderOutcomeAvgCost.shares * traderOutcomeAvgCost.avgPrice + _price) / (traderOutcomeAvgCost.shares + _shares);
            traderOutcomeAvgCost.shares += _shares;
        }
        if (!_isBuy) {
            if (traderOutcomeAvgCost.shares <= _shares) {
                _shares = traderOutcomeAvgCost.shares;
                traderOutcomeAvgCost.avgPrice = 0;
            }
            traderOutcomeAvgCost.shares -= _shares;
        }
    }
    function _calculateAvgSell(address _traderAddr, uint256 _outcomeId, uint256 _shares, uint256 _price) private {
        AvgPrice storage traderOutcomeAvgSell = traderOutcomeAvgSell_[_traderAddr][_outcomeId];
        uint256 _avgSell = _price / _shares;
        traderOutcomeAvgSell.avgPrice = (traderOutcomeAvgSell.avgPrice * traderOutcomeAvgSell.shares + _avgSell * _shares) / (traderOutcomeAvgSell.shares + _shares);
        traderOutcomeAvgSell.shares += _shares;
        int256 _pnlPerShare = int256(_avgSell) - int256(traderOutcomeAvgCost_[_traderAddr][_outcomeId].avgPrice);
        int256 _totalPnl = _pnlPerShare * int256(_shares);
        traderOutcomePnl_[_traderAddr][_outcomeId] += _totalPnl;
    }
}
contract CloudedDAO is ERC20, ReentrancyGuardTransient {
    using Ids for Ids.Set;
    event StakeToVote(address indexed voter, uint256 indexed marketId, uint256 indexed outcomeId, uint256 amount);
    event Unstake(address indexed voter, uint256 indexed marketId, uint256 indexed outcomeId, uint256 amount);
    event BuyBack(uint256 receivedReward, uint256 swappedHYPE, uint256 tokenBurned);
    address constant JURY = ; // Update after contract deployment
    address constant CLOUDED = ; // Update after contract deployment
    address constant ROUTER = 0xb4a9C4e6Ea8E2191d2FA5B380452a634Fb21240A;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    uint256 constant DECIMALS = 1e18;
    mapping(address => uint256) public stakeOf;
    mapping(address => mapping(uint256 => uint256)) public outcomeStakeOf;
    mapping(uint256 => uint256) public outcomeVotes;
    mapping(address => Ids.Set) private voterActiveOutcomeIds_;
    modifier isJury() { require(msg.sender == JURY, "Not authorized"); _; }
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}
    function mint(address _to, uint256 _amount) external nonReentrant isJury { _mint(_to, _amount); }
    function stakeToVote(uint256 _outcomeId, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(balanceOf(msg.sender) >= _amount * DECIMALS, "Insufficient balance");
        _update(msg.sender, address(this), _amount * DECIMALS);
        uint256 _outcomeMarketId = IClouded(CLOUDED).getOutcomeMarketId(_outcomeId);
        uint8 _status = IJury(JURY).updateMarketStatus(_outcomeMarketId);
        require(_status == 3, "Not voting window");
        stakeOf[msg.sender] += _amount;
        outcomeStakeOf[msg.sender][_outcomeId] += _amount;
        outcomeVotes[_outcomeId] += _amount;
        voterActiveOutcomeIds_[msg.sender].add(_outcomeId);
        emit StakeToVote(msg.sender, _outcomeMarketId, _outcomeId, _amount);
    }
    function unstake(uint256 _outcomeId) external nonReentrant {
        require(outcomeStakeOf[msg.sender][_outcomeId] > 0, "No token staked");
        uint256 _outcomeStakeOf = outcomeStakeOf[msg.sender][_outcomeId];
        outcomeStakeOf[msg.sender][_outcomeId] = 0;
        uint256 _outcomeMarketId = IClouded(CLOUDED).getOutcomeMarketId(_outcomeId);
        uint8 _status = IJury(JURY).updateMarketStatus(_outcomeMarketId);
        if (_status == 3) outcomeVotes[_outcomeId] -= _outcomeStakeOf;
        stakeOf[msg.sender] -= _outcomeStakeOf;
        voterActiveOutcomeIds_[msg.sender].remove(_outcomeId);
        _update(address(this), msg.sender, _outcomeStakeOf * DECIMALS);
        emit Unstake(msg.sender, _outcomeMarketId, _outcomeId, _outcomeStakeOf);
    }
    function buyBack() external payable isJury {
        uint256 _try;
        uint256 _swappedHYPE;
        uint256 _tokenBurned;
        uint256 _maxAttempt = 3;
        uint256 _total = address(this).balance;
        address[] memory _path = new address[](2);
        _path[0] = WHYPE;
        _path[1] = address(this);
        while (_try < _maxAttempt) {
            try IHyperSwapV2Router(ROUTER).getAmountsOut(_total, _path) returns (uint[] memory _estimatedAmounts) {
                uint256 _amountOutMin = _estimatedAmounts[1] / 2;
                try IHyperSwapV2Router(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: _total}(
                    _amountOutMin, 
                    _path, 
                    msg.sender, 
                    address(0), 
                    block.timestamp + 300
                ) {
                    _swappedHYPE = _total;
                    _tokenBurned = balanceOf(msg.sender);
                    _burn(msg.sender, balanceOf(msg.sender));
                    break;
                } catch {}
            } catch {}
            _total = _total / 2;
            _try++;
        }
        emit BuyBack(msg.value, _swappedHYPE, _tokenBurned);
    }
}