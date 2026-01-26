// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AddressPrivileges} from "./AddressPrivileges.sol";

// 预言机合约
contract BscPledgeOracle is AddressPrivileges {
    
    mapping(address => AggregatorV3Interface) public priceFeeds; // Chainlink价格地址映射
    mapping(address => uint256) public manualPrices; // 手动价格映射
    mapping(address => bool) public useManualPrice; // 是否启用手动价格映射
    // 价格精度
    uint256 public constant PRICE_PRECISION = 1e8; 
    // 事件
    event PriceFeedSet(address asset, address priceFeed);
    event ManualPriceSet(address asset, uint256 price);

    constructor() AddressPrivileges(msg.sender) {}

    // 设置Chainlink价格预言机地址
    function setPriceFeed(address asset, address priceFeed) external onlyOracleManager {
        priceFeeds[asset] = AggregatorV3Interface(priceFeed);
        emit PriceFeedSet(asset, priceFeed);
    }

    // 启动手动价格(应急)
    function setManualPrice(address asset, uint256 price) external onlyOracleManager {
        manualPrices[asset] = price;
        useManualPrice[asset] = true;
        emit ManualPriceSet(asset, price);
    }
    // 关闭手动价格(应急)
    function closeManualPrice(address asset) external onlyOracleManager {
        require(useManualPrice[asset], "BscPledgeOracle: manual is closed");
        useManualPrice[asset] = false;
        emit ManualPriceSet(asset, 0);
    }

    // 获取单个资产价格
    function getPrice(address asset) external view returns(uint256) {
        if (useManualPrice[asset]) {
            return manualPrices[asset];
        }
        AggregatorV3Interface priceFeed = priceFeeds[asset];
        require(address(priceFeed) != address(0), "BscPledgeOracle: feed not set");
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "BscPledgeOracle: invalid price");
        return uint256(price);
    }

    // 批量获取多个资产价格
    function getPrices(address[] calldata assets) external view returns(uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = this.getPrice(assets[i]);
        }
        return prices;
    }


}