// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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

interface IJury { function updateMarketStatus(uint256) external returns (uint8); }

interface IClouded { function getOutcomeMarketId(uint256) external view returns (uint256); }

contract CloudedDAO is ERC20, ReentrancyGuardTransient {
    using Ids for Ids.Set;

    event StakeToVote(address indexed voter, uint256 indexed marketId, uint256 indexed outcomeId, uint256 amount, uint256 outcomeVotes);
    event Unstake(address indexed voter, uint256 indexed marketId, uint256 indexed outcomeId, uint256 amount, uint256 outcomeVotes);
    event BuyBack(uint256 hypeReward, uint256 daoBurned, uint256 reserveHYPE, uint256 reserveDAO);
    event AddLiquidity(address indexed provider, uint256 lpAdded, uint256 hypeUsed, uint256 daoUsed, uint256 hypeRefund, uint256 daoRefund, uint256 lpOf, uint256 totalLP, uint256 reserveHYPE, uint256 reserveDAO);
    event RemoveLiquidity(address indexed provider, uint256 lpRemoved, uint256 hype, uint256 dao, uint256 lpOf, uint256 totalLP, uint256 reserveHYPE, uint256 reserveDAO);
    event Swap(address indexed user, uint256 hypeIn, uint256 daoIn, uint256 hypeOut, uint256 daoOut, uint256 reserveHYPE, uint256 reserveDAO);

    address public immutable JURY;
    address public immutable CLOUDED;
    uint256 constant DECIMALS = 1e18;
    uint256 private constant FEE_NUM = 997;
    uint256 private constant FEE_DEN = 1000;

    uint256 private constant BPS_DEN = 10000;
    uint256 private constant MAX_BUYBACK_DEVIATION_BPS = 2000;
    uint256 private constant ORACLE_PERIOD = 30 minutes;

    uint256 private priceCumulative_;
    uint256 private priceUpdatedAt_;
    uint256 private oraclePrice_;
    uint256 private oracleCumulative_;
    uint256 private oracleUpdatedAt_;

    mapping(uint256 => uint256) public  outcomeVotes;
    mapping(address => Ids.Set) private voterActiveOutcomeIds_;
    mapping(address => mapping(uint256 => uint256)) private outcomeStakeOf_;

    uint256 public pendingHYPE;
    uint256 public reserveHYPE;
    uint256 public reserveDAO;
    uint256 public totalLP;

    mapping(address => uint256) public lpOf;

    modifier isJury() { require(msg.sender == JURY, "Not authorized"); _; }

    constructor(string memory _name, string memory _symbol, address _juryAddr, address _cloudedAddr) ERC20(_name, _symbol) {
        JURY = _juryAddr;
        CLOUDED = _cloudedAddr;
    }

    function getVoterActiveOutcomeIds(address _voterAddr) external view returns (uint256[] memory) { return voterActiveOutcomeIds_[_voterAddr].getAll(); }

    function getVoterOutcomeVotes(address _voterAddr, uint256[] memory _outcomeIds) external view returns (uint256[] memory voterOutcomeVotes) {
        voterOutcomeVotes = new uint256[](_outcomeIds.length);
        for (uint256 i = 0; i < _outcomeIds.length; i++) { voterOutcomeVotes[i] = outcomeStakeOf_[_voterAddr][_outcomeIds[i]]; }
    }

    function getOutcomeVoteInBatch(uint256[] memory _outcomeIds) external view returns (uint256[] memory voterOutcomeVotes) {
        voterOutcomeVotes = new uint256[](_outcomeIds.length);
        for (uint256 i = 0; i < _outcomeIds.length; i++) { voterOutcomeVotes[i] = outcomeVotes[_outcomeIds[i]]; }
    }

    function getPool() external view returns (uint256, uint256, uint256) { return (reserveHYPE, reserveDAO, totalLP); }

    function getUserPosition(address _addr) external view returns (uint256 hypeBalance, uint256 daoBalance, uint256 lp, uint256 poolShareBPS, uint256 poolHYPE, uint256 poolDAO) {
        hypeBalance = address(_addr).balance;
        daoBalance  = balanceOf(_addr);
        lp          = lpOf[_addr];
        if (totalLP > 0 && lp > 0) {
            poolShareBPS = lp * 10000 / totalLP;
            poolHYPE     = lp * reserveHYPE / totalLP;
            poolDAO      = lp * reserveDAO  / totalLP;
        }
    }

    function quoteAddLiquidity(uint256 _hypeAmount, uint256 _daoAmount) external view returns (uint256 lp, uint256 hypeUsed, uint256 daoUsed, uint256 hypeRefund, uint256 daoRefund) {
        require(_hypeAmount > 0 || _daoAmount > 0, "Input amount");

        if (totalLP == 0) require(_hypeAmount > 0 && _daoAmount > 0, "Add both tokens to initiate pool");

        if (_hypeAmount > 0 && _daoAmount == 0) { _daoAmount  = _hypeAmount * reserveDAO  / reserveHYPE; }
        if (_daoAmount > 0 && _hypeAmount == 0) { _hypeAmount = _daoAmount  * reserveHYPE / reserveDAO; }

        (lp, hypeUsed, daoUsed, hypeRefund, daoRefund) = _calculateAddLiquidity(_hypeAmount, _daoAmount);
    }

    function quoteRemoveLiquidity(uint256 _lp) external view returns (uint256 hype, uint256 dao) {
        require(_lp != 0 && totalLP != 0, "No liquidity in the pool");
        hype = _lp * reserveHYPE / totalLP;
        dao  = _lp * reserveDAO  / totalLP;
    }

    function quoteHYPEForDAO(uint256 _hypeIn, uint256 _slippageBPS) external view returns (uint256 daoOut, uint256 minDaoOut) {
        require(_hypeIn > 0, "Zero input");

        uint256 _hypeInAfterFee = _hypeIn * FEE_NUM;
        daoOut = _hypeInAfterFee * reserveDAO / (reserveHYPE * FEE_DEN + _hypeInAfterFee);
        minDaoOut = daoOut * (10000 - _slippageBPS) / 10000;
    }

    function quoteDAOForHYPE(uint256 _daoIn, uint256 _slippageBPS) external view returns (uint256 hypeOut, uint256 minHypeOut) {
        require(_daoIn > 0, "Zero input");

        uint256 _daoInAfterFee = _daoIn * FEE_NUM;
        hypeOut = _daoInAfterFee * reserveHYPE / (reserveDAO * FEE_DEN + _daoInAfterFee);

        minHypeOut = hypeOut * (10000 - _slippageBPS) / 10000;
    }

    function mint(address _to, uint256 _amount) external nonReentrant isJury { _mint(_to, _amount); }

    function stakeToVote(uint256 _outcomeId, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(balanceOf(msg.sender) >= _amount * DECIMALS, "Insufficient balance");

        uint256 _outcomeMarketId  = IClouded(CLOUDED).getOutcomeMarketId(_outcomeId);
        require(_outcomeMarketId != 0, "Invalid outcome id");

        uint8   _status = IJury(JURY).updateMarketStatus(_outcomeMarketId);
        require(_status == 3, "Not voting window");

        outcomeStakeOf_[msg.sender][_outcomeId] += _amount;
        outcomeVotes[_outcomeId]                += _amount;
        voterActiveOutcomeIds_[msg.sender].add(_outcomeId);
        _update(msg.sender, address(this), _amount * DECIMALS);

        emit StakeToVote(msg.sender, _outcomeMarketId, _outcomeId, _amount, outcomeVotes[_outcomeId]);
    }

    function unstake(uint256 _outcomeId) external nonReentrant {
        require(outcomeStakeOf_[msg.sender][_outcomeId] > 0, "No token staked");
        uint256 _outcomeStakeOf = outcomeStakeOf_[msg.sender][_outcomeId];
        outcomeStakeOf_[msg.sender][_outcomeId] = 0;

        uint256 _outcomeMarketId = IClouded(CLOUDED).getOutcomeMarketId(_outcomeId);
        uint8 _status = IJury(JURY).updateMarketStatus(_outcomeMarketId);
        if (_status == 3) outcomeVotes[_outcomeId] -= _outcomeStakeOf;

        voterActiveOutcomeIds_[msg.sender].remove(_outcomeId);
        _update(address(this), msg.sender, _outcomeStakeOf * DECIMALS);

        emit Unstake(msg.sender, _outcomeMarketId, _outcomeId, _outcomeStakeOf, outcomeVotes[_outcomeId]);
    }

    function buyBack() external payable nonReentrant isJury {
        pendingHYPE += msg.value;

        if (totalLP == 0) {
            uint256 _initialAmount = pendingHYPE;
            _mint(address(this), _initialAmount);
            pendingHYPE         -= _initialAmount;
            reserveHYPE         += _initialAmount;
            reserveDAO          += _initialAmount;
            totalLP             += _initialAmount;
            lpOf[address(this)] += _initialAmount;
            priceUpdatedAt_  = block.timestamp;
            oracleUpdatedAt_ = block.timestamp;
            oraclePrice_     = DECIMALS * reserveDAO / reserveHYPE;
        }

        _updateBuyBackOracle();

        uint256 _hypeIn = pendingHYPE;
        uint256 _hypeInAfterFee = _hypeIn * FEE_NUM;
        uint256 _daoOut = _hypeInAfterFee * reserveDAO / (reserveHYPE * FEE_DEN + _hypeInAfterFee);

        uint256 _oracleReserveDAO = reserveHYPE * oraclePrice_ / DECIMALS; //  // oraclePrice_ = oracleReserveDAO / reserveHYPE × DECIMALS
        uint256 _minDaoOut = _hypeInAfterFee * _oracleReserveDAO / (reserveHYPE * FEE_DEN + _hypeInAfterFee);
        _minDaoOut = _minDaoOut * (BPS_DEN - MAX_BUYBACK_DEVIATION_BPS) / BPS_DEN;

        if (_daoOut > 0 && _daoOut >= _minDaoOut) {
            pendingHYPE -= _hypeIn;
            reserveHYPE += _hypeIn;
            reserveDAO  -= _daoOut;
            _burn(address(this), _daoOut);
        }
        else _daoOut = 0;

        emit BuyBack(msg.value, _daoOut, reserveHYPE, reserveDAO);
    }

    function addLiquidity(uint256 _daoAmount, uint256 _minLpOut, uint256 _deadline) external payable nonReentrant returns (uint256 lpAdded) {
        require(block.timestamp <= _deadline, "Expired");
        require(balanceOf(msg.sender) >= _daoAmount, "Insufficient balance");

        uint256 _hypeAmount = msg.value;
        require(_hypeAmount > 0 && _daoAmount > 0, "Zero amount");

        uint256 _hypeUsed; uint256 _daoUsed; uint256 _hypeRefund; uint256 _daoRefund;
        (lpAdded, _hypeUsed, _daoUsed, _hypeRefund, _daoRefund) = _calculateAddLiquidity(_hypeAmount, _daoAmount);
        require(lpAdded > 0 && lpAdded >= _minLpOut, "Insufficient LP minted");

        _updateBuyBackOracle();

        lpOf[msg.sender] += lpAdded;
        totalLP          += lpAdded;
        reserveHYPE      += _hypeUsed;
        reserveDAO       += _daoUsed;

        _update(msg.sender, address(this), _daoUsed);

        if (_hypeRefund > 0) {
            (bool _success, ) = msg.sender.call{value: _hypeRefund}("");
            require(_success, "Refund failed");
        }

        emit AddLiquidity(msg.sender, lpAdded, _hypeUsed, _daoUsed, _hypeRefund, _daoRefund, lpOf[msg.sender], totalLP, reserveHYPE, reserveDAO);
    }

    function removeLiquidity(uint256 _lp, uint256 _minHypeOut, uint256 _minDaoOut, uint256 _deadline) external nonReentrant returns (uint256 hype, uint256 dao) {
        require(lpOf[msg.sender] >= _lp && _lp > 0, "Insufficient LP");
        require(block.timestamp <= _deadline, "Expired");

        hype = _lp * reserveHYPE / totalLP;
        dao  = _lp * reserveDAO / totalLP;
        require(hype > 0 && dao > 0, "Zero output");
        require(hype >= _minHypeOut && dao >= _minDaoOut, "Exceed slippage");

        _updateBuyBackOracle();

        lpOf[msg.sender] -= _lp;
        totalLP          -= _lp;
        reserveHYPE      -= hype;
        reserveDAO       -= dao;

        _update(address(this), msg.sender, dao);

        (bool _success, ) = msg.sender.call{value: hype}("");
        require(_success, "HYPE transfer failed");

        emit RemoveLiquidity(msg.sender, _lp, hype, dao, lpOf[msg.sender], totalLP, reserveHYPE, reserveDAO);
    }

    function swapHYPEForDAO(uint256 _minDaoOut, uint256 _deadline) external payable nonReentrant returns (uint256 daoOut) {
        require(block.timestamp <= _deadline, "Expired");
        require(msg.value > 0, "Zero input");

        uint256 _hypeInAfterFee = msg.value * FEE_NUM;
        daoOut = _hypeInAfterFee * reserveDAO / (reserveHYPE * FEE_DEN + _hypeInAfterFee);
        require(daoOut >= _minDaoOut && daoOut > 0, "Slippage/zero output");

        _updateBuyBackOracle();

        reserveHYPE += msg.value;
        reserveDAO  -= daoOut;
        _update(address(this), msg.sender, daoOut);

        emit Swap(msg.sender, msg.value, 0, 0, daoOut, reserveHYPE, reserveDAO);
    }

    function swapDAOForHYPE(uint256 _daoIn, uint256 _minHypeOut, uint256 _deadline) external nonReentrant returns (uint256 hypeOut) {
        require(block.timestamp <= _deadline, "Expired");
        require(_daoIn > 0, "Zero input");

        uint256 _daoInAfterFee = _daoIn * FEE_NUM;
        hypeOut = _daoInAfterFee * reserveHYPE / (reserveDAO * FEE_DEN + _daoInAfterFee);
        require(hypeOut >= _minHypeOut && hypeOut > 0, "Slippage/zero output");

        _updateBuyBackOracle();

        reserveDAO  += _daoIn;
        reserveHYPE -= hypeOut;
        _update(msg.sender, address(this), _daoIn);

        (bool _success, ) = msg.sender.call{value: hypeOut}("");
        require(_success, "HYPE transfer failed");

        emit Swap(msg.sender, 0, _daoIn, hypeOut, 0, reserveHYPE, reserveDAO);
    }

    function _calculateAddLiquidity(uint256 _hypeAmount, uint256 _daoAmount) private view returns (uint256 lpAdded, uint256 hypeUsed, uint256 daoUsed, uint256 hypeRefund, uint256 daoRefund) {
        if (totalLP == 0) {
            uint256 _sqrtK = _sqrt(_hypeAmount * _daoAmount);
            hypeUsed = _hypeAmount;
            daoUsed  = _daoAmount;
            lpAdded  = _sqrtK;
        } else {
            uint256 _lpByHype = _hypeAmount * totalLP / reserveHYPE;
            uint256 _lpByDAO  = _daoAmount  * totalLP / reserveDAO;
            lpAdded = _lpByHype < _lpByDAO ? _lpByHype : _lpByDAO;
            if (_lpByHype < _lpByDAO) {
                hypeUsed  = _hypeAmount;
                daoUsed   = _hypeAmount * reserveDAO / reserveHYPE;
                daoRefund = _daoAmount - daoUsed;
            } else if (_lpByDAO < _lpByHype) {
                daoUsed    = _daoAmount;
                hypeUsed   = _daoAmount * reserveHYPE / reserveDAO;
                hypeRefund = _hypeAmount - hypeUsed;
            } else {
                hypeUsed = _hypeAmount;
                daoUsed  = _daoAmount;
            }
            require(hypeUsed > 0 && daoUsed > 0, "Insufficient liquidity");
        }
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) z = 1;
    }

    function _updateBuyBackOracle() private {
        if (totalLP == 0) return;

        uint256 _timestamp = block.timestamp;

        uint256 _priceElapsed = _timestamp - priceUpdatedAt_;
        if (_priceElapsed > 0) {
            priceCumulative_ += (reserveDAO * DECIMALS / reserveHYPE) * _priceElapsed;
            priceUpdatedAt_   = _timestamp;
        }

        uint256 _oracleElapsed = _timestamp - oracleUpdatedAt_;
        if (_oracleElapsed >= ORACLE_PERIOD) {
            oraclePrice_      = (priceCumulative_ - oracleCumulative_) / _oracleElapsed;
            oracleCumulative_ = priceCumulative_;
            oracleUpdatedAt_  = _timestamp;
        }
    }
}