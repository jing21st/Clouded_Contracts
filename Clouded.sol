// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

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

interface IJury {
    function updateMarketStatus(uint256) external returns (uint8);
    function getMarketStoredInfo(uint256) external view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, bytes32, bool, bool);
}

contract Clouded is ERC1155, ReentrancyGuardTransient {
    using Ids for Ids.Set;

    event Buy(address indexed buyer, uint256 indexed marketId, uint256 indexed outcomeId, uint256 shares, uint256 frontendPrice, uint256 slippageBPS, uint256 marketShares, uint256 outcomeShares, uint256 bondingPool, uint256 prizePool);
    event Sell(address indexed seller, uint256 indexed marketId, uint256 indexed outcomeId, uint256 shares, uint256 refund, uint256 frontendPrice, uint256 slippageBPS, bool isTraderOutcome);
    event SellAfter(uint256 indexed marketId, uint256 indexed outcomeId, uint256 marketShares, uint256 outcomeShares, uint256 bondingPool);
    event TraderAvgCost(address indexed trader, uint256 indexed outcomeId, uint256 avgCost);
    event TraderAvgSell(address indexed trader, uint256 indexed outcomeId, uint256 avgSell, int256 pnl);
    event ClaimTraderReward(address indexed trader, uint256 indexed marketId, uint256 indexed outcomeId, uint256 traderShares, uint256 totalReward, uint256 traderReward);
    event TransferToken(address indexed from, address indexed to, uint256 indexed outcomeId, bool isTraderOutcomesFrom);

    uint256 constant B = 1;
    uint256 constant DECIMALS = 1e18;
    address public immutable MANAGER;
    address public immutable JURY;

    uint256 public nextMarketId;
    uint256 public nextOutcomeId;

    mapping(uint256 => Market)  private markets_;
    mapping(uint256 => Outcome) private outcomes_;

    mapping(address => Ids.Set) private traderOutcomeIds_;
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
        uint256 prizePool; // Fixed buy-in contributions from all traders. Non-refundable. Combined with bondingPool, Distributed to winners at settlement.
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

    constructor(string memory _uri, address _managerAddr, address _juryAddr) ERC1155(_uri) {
        nextMarketId = 1;
        nextOutcomeId = 1;
        MANAGER = _managerAddr;
        JURY = _juryAddr;
    }

    function getMarketStartAtDaysOf(uint256 _marketId) external view returns (uint256, uint256) { return (markets_[_marketId].startAt, markets_[_marketId].daysOf); }

    function getMarketOutcomeIds(uint256 _marketId) external view returns (uint256[] memory) { return markets_[_marketId].outcomeIds; }

    function getOutcomeMarketId(uint256 _outcomeId) external view returns (uint256) { return outcomes_[_outcomeId].marketId; }

    function getMarketWinningOutcome(uint256 _marketId) external view returns (uint256) { return _getMarketWinningOutcome(_marketId); } // The function returns the outcome with most shares in a market

    function getMarketTotalReward(uint256 _marketId) external view returns (uint256) { return _getMarketTotalReward(_marketId); }

    function getMarketInfo(uint256 _marketId) external view returns (
        string    memory name, 
        string    memory rule, 
        uint256[] memory outcomeIds, 
        uint256 startAt, 
        uint256 daysOf, 
        uint256 shares, 
        uint256 bondingPool, 
        uint256 prizePool
    ) {
        name        = markets_[_marketId].name;
        rule        = markets_[_marketId].rule;
        outcomeIds  = markets_[_marketId].outcomeIds;
        startAt     = markets_[_marketId].startAt;
        daysOf      = markets_[_marketId].daysOf;
        shares      = markets_[_marketId].shares;
        bondingPool = markets_[_marketId].bondingPool;
        prizePool   = markets_[_marketId].prizePool;
    }

    function getTraderOutcomeIds(address _traderAddr) external view returns (uint256[] memory) { return traderOutcomeIds_[_traderAddr].getAll(); }

    function getTraderOutcomePnlInBatch(address _traderAddr, uint256[] memory _outcomeIds) external view returns (uint256[] memory shares, uint256[] memory avgCost, uint256[] memory avgSell, int256[] memory pnl, uint256[] memory impliedRewardToWin) {
        shares  = new uint256[](_outcomeIds.length);
        avgCost = new uint256[](_outcomeIds.length);
        avgSell = new uint256[](_outcomeIds.length);
        pnl     = new int256[](_outcomeIds.length);
        impliedRewardToWin = new uint256[](_outcomeIds.length);
        for (uint256 i = 0; i < _outcomeIds.length; i++) {
            uint256 _outcomeId = _outcomeIds[i];
            uint256 _marketId  = outcomes_[_outcomeId].marketId;
            shares[i]  = balanceOf(_traderAddr, _outcomeId);
            avgCost[i] = traderOutcomeAvgCost_[_traderAddr][_outcomeId].avgPrice;
            avgSell[i] = traderOutcomeAvgSell_[_traderAddr][_outcomeId].avgPrice;
            pnl[i]     = traderOutcomePnl_[_traderAddr][_outcomeId];
            if (shares[i] > 0) impliedRewardToWin[i] = _calculateOutcomeReward(shares[i], markets_[_marketId].prizePool + markets_[_marketId].bondingPool, outcomes_[_outcomeId].shares);
        }
    }

    function getOutcomeBuyQuote(uint256 _outcomeId, uint256 _shares) external view returns (uint256 price, uint256 impliedRewardToWin, uint256 minRewardToWin) {
        uint256 _marketId = outcomes_[_outcomeId].marketId;
        Market storage market = markets_[_marketId];
        uint256 _marketExecutionPrice  = _getPriceAppreciation(market.shares, true, _shares) / 2;
        uint256 _outcomeExecutionPrice = _getPriceAppreciation(outcomes_[_outcomeId].shares, true, _shares) / 2;
        price = _marketExecutionPrice + _outcomeExecutionPrice;

        uint256 _totalPool   = market.prizePool + market.bondingPool + price;
        uint256 _sharesAfter = outcomes_[_outcomeId].shares + _shares;
        impliedRewardToWin   = _calculateOutcomeReward(_shares, _totalPool, _sharesAfter);

        uint256 _totalPrizePool = 2 * (market.prizePool + _outcomeExecutionPrice);
        minRewardToWin = _getMinRewardToWin(_shares, _totalPool, _totalPrizePool, _sharesAfter);
    }

    function getPriceAppreciation(uint256 _outcomeId, bool _isBuy, uint256 _shares) external view returns (uint256) {
        uint256 _marketId = outcomes_[_outcomeId].marketId;
        uint256 _marketTotalShares  = markets_[_marketId].shares;
        uint256 _outcomeTotalShares = outcomes_[_outcomeId].shares;
        require(_isBuy || _outcomeTotalShares >= _shares, "Exceed outcome total shares");
        uint256 _marketExecutionPrice  = _getPriceAppreciation(_marketTotalShares, _isBuy, _shares) / 2;
        uint256 _outcomeExecutionPrice = _getPriceAppreciation(_outcomeTotalShares, _isBuy, _shares) / 2;
        if (_isBuy) return _marketExecutionPrice + _outcomeExecutionPrice;
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
            require(bytes(_outcomes[i]).length > 0, "Outcome empty");
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

    function buy(address _msgSender, uint256 _outcomeMarketId, uint256 _outcomeId, uint256 _shares, uint256 _frontendPrice, uint256 _slippageBPS) external payable nonReentrant isJury { _buy(_msgSender, _outcomeMarketId, _outcomeId, _shares, _frontendPrice, _slippageBPS); }

    function buy(uint256 _outcomeId, uint256 _shares, uint256 _frontendPrice, uint256 _slippageBPS) external payable nonReentrant {
        uint256 _outcomeMarketId = outcomes_[_outcomeId].marketId;
        require(_outcomeMarketId != 0, "Invalid outcome id");
        require(IJury(JURY).updateMarketStatus(_outcomeMarketId) == 0, "Market ended");
        _buy(msg.sender, _outcomeMarketId, _outcomeId, _shares, _frontendPrice, _slippageBPS);
    }
    
    function _buy(address _msgSender, uint256 _outcomeMarketId, uint256 _outcomeId, uint256 _shares, uint256 _frontendPrice, uint256 _slippageBPS) private {
        require(_shares > 0, "Shares cannot be 0");
        require(_slippageBPS <= 2000, "Exceed max slippage");

        Market storage market = markets_[_outcomeMarketId];
        Outcome storage outcome = outcomes_[_outcomeId];
        uint256 _marketExecutionPrice  = _getPriceAppreciation(market.shares, true, _shares) / 2;
        uint256 _outcomeExecutionPrice = _getPriceAppreciation(outcome.shares, true, _shares) / 2;
        uint256 _totalExecutionPrice   = _marketExecutionPrice + _outcomeExecutionPrice;
        require(_totalExecutionPrice <= _frontendPrice * (10000 + _slippageBPS) / 10000, "Exceed slippage");
        require(msg.value >= _totalExecutionPrice, "Insufficient payment");

        _calculateAvgCost(_msgSender, _outcomeId, true, _shares, _totalExecutionPrice);

        outcome.shares     += _shares;
        market.shares      += _shares;
        market.bondingPool += _marketExecutionPrice;
        market.prizePool   += _outcomeExecutionPrice;
        traderOutcomeIds_[_msgSender].add(_outcomeId);
        _mint(_msgSender, _outcomeId, _shares, "");

        uint256 _refund = msg.value - _totalExecutionPrice;
        if (_refund > 0) {
            (bool _success, ) = _msgSender.call{value: _refund}("");
            require(_success, "Refund failed");
        }

        emit Buy(_msgSender, _outcomeMarketId, _outcomeId, _shares, _frontendPrice, _slippageBPS, market.shares, outcome.shares, market.bondingPool, market.prizePool);
    }

    function sell(uint256 _outcomeId, uint256 _shares, uint256 _frontendPrice, uint256 _slippageBPS) external nonReentrant {
        Outcome storage outcome  = outcomes_[_outcomeId];
        uint256 _outcomeMarketId = outcome.marketId;
        require(_outcomeMarketId != 0, "Invalid outcome id");
        require(IJury(JURY).updateMarketStatus(_outcomeMarketId) == 0, "Market ended");
        require(balanceOf(msg.sender, _outcomeId) >= _shares, "Insufficient balance");
        require(_shares > 0, "Shares cannot be 0");
        require(_slippageBPS <= 2000, "Exceed max slippage");

        Market storage market = markets_[_outcomeMarketId];
        uint256 _refund       = _getPriceAppreciation(market.shares, false, _shares) / 2;
        uint256 _minRefund    = _frontendPrice * (10000 - _slippageBPS) / 10000;
        require(_refund >= _minRefund, "Exceed slippage");

        _calculateAvgSell(msg.sender, _outcomeId, _shares, _refund);
        _calculateAvgCost(msg.sender, _outcomeId, false, _shares, _refund);

        market.shares      -= _shares;
        market.bondingPool -= _refund;
        outcome.shares     -= _shares;
        _burn(msg.sender, _outcomeId, _shares);
        if (balanceOf(msg.sender, _outcomeId) == 0) traderOutcomeIds_[msg.sender].remove(_outcomeId);

        if (_refund > 0) {
            (bool _success, ) = msg.sender.call{value: _refund}("");
            require(_success, "Refund failed");
        }

        _emitSell(_outcomeMarketId, _outcomeId, _shares, _refund, _frontendPrice, _slippageBPS);

        _emitSellAfter(_outcomeMarketId, _outcomeId);
    }

    function _emitSell(uint256 _outcomeMarketId, uint256 _outcomeId, uint256 _shares, uint256 _refund, uint256 _frontendPrice, uint256 _slippageBPS) private { emit Sell(msg.sender, _outcomeMarketId, _outcomeId, _shares, _refund, _frontendPrice, _slippageBPS, traderOutcomeIds_[msg.sender].isSet(_outcomeId)); }

    function _emitSellAfter(uint256 _marketId, uint256 _outcomeId) private { emit SellAfter(_marketId, _outcomeId, markets_[_marketId].shares, outcomes_[_outcomeId].shares, markets_[_marketId].bondingPool); }

    function claimReward(uint256 _marketId) external nonReentrant {
        require(IJury(JURY).updateMarketStatus(_marketId) == 4, "Market not ended");

        (, , , , , uint256 _juryOutcomeId, uint256 _votingOutcomeId, , , bool _marketResolved) = IJury(JURY).getMarketStoredInfo(_marketId);
        require(_marketResolved, "Market not resolved");

        uint256 _resolvedOutcomeId;
        if (_votingOutcomeId != 0)    _resolvedOutcomeId = _votingOutcomeId;
        else if (_juryOutcomeId != 0) _resolvedOutcomeId = _juryOutcomeId;
        else                          _resolvedOutcomeId = _getMarketWinningOutcome(_marketId);

        uint256 _traderShares;
        uint256 _traderReward;
        uint256 _totalReward = _getMarketTotalReward(_marketId);
        uint256[] memory _outcomeIds = markets_[_marketId].outcomeIds;
        for (uint256 i = 0; i < _outcomeIds.length; i++) {
            _traderShares = balanceOf(msg.sender, _outcomeIds[i]);
            if (_traderShares == 0) continue;
            _burn(msg.sender, _outcomeIds[i], _traderShares);
            traderOutcomeIds_[msg.sender].remove(_outcomeIds[i]);
            if (_outcomeIds[i] == _resolvedOutcomeId) _traderReward = _calculateOutcomeReward(_traderShares, _totalReward, outcomes_[_resolvedOutcomeId].shares);
            emit ClaimTraderReward(msg.sender, _marketId, _outcomeIds[i], _traderShares, _totalReward, _traderReward);
        }

        if (_traderReward > 0) {
            (bool _success, ) = msg.sender.call{value: _traderReward}("");
            require(_success, "Refund failed");
        }
    }

    function claimJuryReward(address _msgSender, uint256 _tokenMarketId, uint256 _totalWinnerOutcomeStakes) external nonReentrant isJury returns (uint256 tokenReward) {
        uint256 _marketTotalReward = _getMarketTotalReward(_tokenMarketId);
        tokenReward =  _marketTotalReward / 10 / _totalWinnerOutcomeStakes;
        if (tokenReward > 0) {
            (bool _success, ) = _msgSender.call{value: tokenReward}("");
            require(_success, "Jury refund failed");
        }
    }

    function _update(address _from, address _to, uint256[] memory _ids, uint256[] memory _values) internal virtual override {
        super._update(_from, _to, _ids, _values);
        
        if (_from != address(0) && _to != address(0)) {
            for (uint256 i = 0; i < _ids.length; i++) {
                if (_values[i] > 0) {
                    traderOutcomeIds_[_to].add(_ids[i]);
                    if (balanceOf(_from, _ids[i]) == 0) traderOutcomeIds_[_from].remove(_ids[i]);
                    emit TransferToken(_from, _to, _ids[i], traderOutcomeIds_[_from].isSet(_ids[i]));
                }
            }
        }
    }

    function _getPriceAppreciation(uint256 _idTotalShares, bool _isBuy, uint256 _shares) private pure returns (uint256) {
        uint256 _sharesAfter = _isBuy ? _idTotalShares + _shares : _idTotalShares - _shares;
        uint256 _sharesAfterSquared  = _sharesAfter * _sharesAfter;
        uint256 _sharesBeforeSquared = _idTotalShares * _idTotalShares;
        return _isBuy ? B * (_sharesAfterSquared - _sharesBeforeSquared) * DECIMALS / 2 / 10000 : B * (_sharesBeforeSquared - _sharesAfterSquared) * DECIMALS / 2 / 10000;
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

    function _calculateOutcomeReward(uint256 _traderShares, uint256 _pool, uint256 _outcomeShares) private pure returns (uint256) { return _traderShares * _pool * 9 / _outcomeShares / 10; }

    function _calculateAvgCost(address _traderAddr, uint256 _outcomeId, bool _isBuy, uint256 _shares, uint256 _price) private {
        AvgPrice storage traderOutcomeAvgCost = traderOutcomeAvgCost_[_traderAddr][_outcomeId];
        if (_isBuy) {
            traderOutcomeAvgCost.avgPrice = (traderOutcomeAvgCost.shares * traderOutcomeAvgCost.avgPrice + _price) / (traderOutcomeAvgCost.shares + _shares);
            traderOutcomeAvgCost.shares  += _shares;
        }
        if (!_isBuy) {
            if (traderOutcomeAvgCost.shares <= _shares) {
                _shares = traderOutcomeAvgCost.shares;
                traderOutcomeAvgCost.avgPrice = 0;
            }
            traderOutcomeAvgCost.shares -= _shares;
        }
        emit TraderAvgCost(_traderAddr, _outcomeId, traderOutcomeAvgCost.avgPrice);
    }

    function _calculateAvgSell(address _traderAddr, uint256 _outcomeId, uint256 _shares, uint256 _price) private {
        AvgPrice storage traderOutcomeAvgSell = traderOutcomeAvgSell_[_traderAddr][_outcomeId];
        uint256 _avgSell = _price / _shares;

        traderOutcomeAvgSell.avgPrice = (traderOutcomeAvgSell.avgPrice * traderOutcomeAvgSell.shares + _avgSell * _shares) / (traderOutcomeAvgSell.shares + _shares);
        traderOutcomeAvgSell.shares  += _shares;

        int256 _pnlPerShare = int256(_avgSell) - int256(traderOutcomeAvgCost_[_traderAddr][_outcomeId].avgPrice);
        int256 _totalPnl    = _pnlPerShare * int256(_shares);
        traderOutcomePnl_[_traderAddr][_outcomeId] += _totalPnl;

        emit TraderAvgSell(_traderAddr, _outcomeId, traderOutcomeAvgSell.avgPrice, traderOutcomePnl_[_traderAddr][_outcomeId]);
    }

    function _getMinRewardToWin(uint256 _shares, uint256 _totalPool, uint256 _totalPrizePool, uint256 _sharesAfterBuy) private pure returns (uint256) {
        uint256 _effectivePool = _totalPrizePool < _totalPool ? _totalPrizePool : _totalPool;

        uint256 _k   = B * DECIMALS / 10000;
        uint256 _kS2 = _k * _sharesAfterBuy * _sharesAfterBuy; // if k × sharesAfterBuy < 0.9 × poolAfterBuy / sharesAfterBuy, has guaranteed min profit to enter if won
        if (_kS2 * 10 >= _effectivePool * 9) return _calculateOutcomeReward(_shares, _effectivePool, _sharesAfterBuy);

        uint256 _numerator   = 18 * _effectivePool - 9 * _kS2;
        uint256 _denominator = 11 * _k;
        uint256 _equilibrium = _sqrt(_numerator / _denominator); // c(S_eq) = 0.9 × P_eq / S_eq --> P_eq = P₀ + k(S_eq² - S₀²)/2 --> S_eq = √[ 18(P₀ - kS₀²/2) / 11k ]

        return _shares * _k * _equilibrium;
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) z = 1;
    }
}