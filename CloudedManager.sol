// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IJury {
    function updateURI(string memory, string memory) external;
    function updateCloudedAddr(address) external;
    function updateDAOAddr(address) external;
    function addToWhitelist(address) external;
    function publicLaunch() external;
}

interface IClouded { function updateURI(string memory) external; }

contract CloudedManager {

    IERC20 private managerToken = IERC20(0x668f6C73b2e6d023f758B18973065Ce2c11BDD7B);
    address public CLOUDED;
    address public JURY;

    modifier isAuthorized() { require(managerToken.balanceOf(msg.sender) >= managerToken.totalSupply() / 2, "Not authorized"); _; }

    constructor() {}

    function updateJuryAddrs(address _juryAddr, address _cloudedAddr, address _daoAddr) external isAuthorized {
        if (JURY == address(0)) {
            JURY = _juryAddr;
            IJury(JURY).updateDAOAddr(_daoAddr);
            IJury(JURY).updateCloudedAddr(_cloudedAddr);
        }
    }

    function updateJuryURI(string memory _newBaseURI, string memory _newURI) external isAuthorized { IJury(JURY).updateURI(_newBaseURI, _newURI); }

    function updateManagerToken(address _newManagerTokenAddr) external isAuthorized { managerToken = IERC20(_newManagerTokenAddr); }

    function updateCloudedAddr(address _cloudedAddr) external isAuthorized { if (CLOUDED == address(0)) CLOUDED = _cloudedAddr; }

    function updateCloudedURI(string memory _newURI) external isAuthorized { IClouded(CLOUDED).updateURI(_newURI); }

    function addToWhitelist(address _addr) external isAuthorized { IJury(JURY).addToWhitelist(_addr); }

    function updateWhitelisted() external isAuthorized { IJury(JURY).publicLaunch(); }
}