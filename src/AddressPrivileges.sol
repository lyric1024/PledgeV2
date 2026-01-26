// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// 权限管理
contract AddressPrivileges is Ownable {
    mapping(address => bool) public minters;
    mapping(address => bool) public admins;
    mapping(address => bool) public oracleManagers;

    event MinterAdded(address indexed account);
    event AdminAdded(address indexed account);
    event OracleManagerAdded(address indexed account);

    event MinterRemoved(address indexed account);
    event AdminRemoved(address indexed account);
    event OracleManagerRemoved(address indexed account);

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyMinter() {
        require(minters[msg.sender], "AddressPrivileges: not minter");
        _;
    }
    modifier onlyAdmin() {
        require(admins[msg.sender], "AddressPrivileges: not admin");
        _;
    }
    modifier onlyOracleManager() {
        require(
            oracleManagers[msg.sender],
            "AddressPrivileges: not oracleManager"
        );
        _;
    }

    function addMinter(address account) external onlyOwner {
        minters[account] = true;
        emit MinterAdded(account);
    }
    function addAdmin(address account) external onlyOwner {
        admins[account] = true;
        emit AdminAdded(account);
    }
    function addOracleManager(address account) external onlyOwner {
        oracleManagers[account] = true;
        emit OracleManagerAdded(account);
    }

    // 移除权限
    function removeMinter(address account) external onlyOwner {
        minters[account] = false;
        emit MinterRemoved(account);
    }
    function removeAdmin(address account) external onlyOwner {
        admins[account] = false;
        emit AdminRemoved(account);
    }
    function removeOracleManager(address account) external onlyOwner {
        oracleManagers[account] = false;
        emit OracleManagerRemoved(account);
    }
}
