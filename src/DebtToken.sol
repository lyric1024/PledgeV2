// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AddressPrivileges} from "./AddressPrivileges.sol";

// 债务代币合约
contract DebtToken is ERC20 {
    AddressPrivileges public privileges;

    // init
    constructor(
        string memory name,
        string memory symbol,
        AddressPrivileges _privileges
    ) ERC20(name, symbol) {
        privileges = _privileges;
    }

    // 铸造债务代币, onlyMiners
    function mint(address to, uint256 amount) external {
        require(privileges.minters(msg.sender), "DebtToken: not minter");
        _mint(to, amount);
    }

    // 销毁债务代币, onlyMiners
    function burn(address from, uint256 amount) external {
        require(privileges.minters(msg.sender), "DebtToken: not minter");
        _burn(from, amount);
    }
}
