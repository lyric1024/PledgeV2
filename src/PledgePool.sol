// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 导入OpenZeppelin的ERC20接口（标准代币交互）
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// 导入SafeERC20工具库（安全的ERC20转账，防止转账失败无反馈）
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// 防重入
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// 导入多签合约（用于权限校验，确保核心操作仅多签管理员可执行）
import {MultiSignature} from "./MultiSignature.sol";
// 导入预言机合约（用于获取资产价格，计算质押率/清算阈值）
import {BscPledgeOracle} from "./BscPledgeOracle.sol";
// 导入债务凭证代币合约（用于发行存款/债务凭证）
import {DebtToken} from "./DebtToken.sol";
import {IDebtToken} from "./interface/IDebtToken.sol";
// 导入地址权限管理合约（用于凭证代币的权限控制）
import {AddressPrivileges} from "./AddressPrivileges.sol";

// 核心借贷池合约
contract PledgePool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // 定义质押池状态枚举, 管理池的生命周期
    enum Poolstate {
        MATCH, // 匹配期  可存入借出/借入的资产
        EXECUTION, // 执行期  结算后,计算利息/清算
        FINISH, // 完成期  池结算, 可提取资产
        LIQUIDATION, // 清算期  触发自动清算
        UNDONE // 撤销期  池未正常启动, 撤销并退款
    }

    // 精度
    uint256 public constant BASE_DECIMAL = 1e18;
    // 最小存款金额
    uint256 public constant MIN_DEPOSIT = 1e16; // 0.01token

    // 池子结构体
    struct PoolBaseInfo {
        address lendToken; //    借出资产 比如BUSD
        address borrowToken; //  借入资产 比如BTCB (借方质押的)
        uint256 settleTime; //   结算时间戳(匹配期结束, 进入执行期的时间)
        uint256 endTime; // 池结束时间(Finish)
        uint256 interestRate; //   年利率
        uint256 maxSupply; // 池子最大借出额度 (借出方最大存入上限)
        uint256 mortgageRate; // 质押率
        uint256 autoLiquidateThreshold; // 自动清算阈值
        Poolstate state; // 池状态
        uint256 lendSupply; // 贷方总存入金额
        uint256 borrowSupply; // 借方总质押金额
        uint256 totalBorrowed; // 总借出金额
        uint256 originalLendSupply; // 原始未结算借出金额
        uint256 originalBorrowSupply; // 原始未结算质押金额
        uint256 settleAmountLend; // 结算时借出的金额 (计算利息)
        uint256 settleAmountBorrow; // 结算时质押的金额 (清算)
        //
        IDebtToken spToken; // 贷方存入资产发放凭证
        IDebtToken jpToken; // 借方质押资产发放凭证
        uint256 liquidationAmountLend; // 清算金额
        uint256 liquidationTime; // 清算时间
        uint256 finishAmountLend; //  完成时最终借出金额
        uint256 finishAmountBorrow; // 完成时最终质押金额
    }
    // 贷方结构体
    struct LendInfo {
        uint256 stakeAmount; // 贷方存入的token金额
        bool hasNoRefund; // true 未退款,  false 退款
        bool hasNoClaim; // true 未领取, false 领取spToken
    }

    // 借方结构体
    struct BorrowInfo {
        uint256 stakeAmount; // 借方质押的金额
        uint256 borrowedAmount; // 已借出金额
        uint256 refundAmount; // 结算后应退还的金额(扣除利息/ 手续费)
        bool hasNoRefund; // true 未退款,  false 退款
        bool hasNoClaim; // true 未领取, false 领取jpToken
    }

    // 池子结构体映射
    mapping(uint256 => PoolBaseInfo) public pools;
    // 池子 - 用户地址 - 贷方信息映射(用户在各个池子里贷方数据)
    mapping(uint256 => mapping(address => LendInfo)) public lendInfos;
    // 池子 - 用户地址 - 借方信息映射(用户在各个池子里借方数据)
    mapping(uint256 => mapping(address => BorrowInfo)) public borrowInfos;

    BscPledgeOracle public oracle;
    MultiSignature public multiSig;
    // 平台手续费地址
    address public feeCollector;
    // 平台手续费 精度
    uint256 public platformFeeRate = 1e6;

    // 质押池创建事件：记录池ID、借出资产、借入资产，便于链下监控
    event PoolCreated(
        uint256 indexed poolId,
        address lendToken,
        address borrowToken
    );
    // 贷方存款事件：记录池ID、用户地址、存款金额，便于追踪贷方操作
    event DepositLend(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount
    );
    // 借方质押事件：记录池ID、用户地址、质押金额，便于追踪借方操作
    event DepositBorrow(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount
    );
    // 借方借款事件
    event WithdrawBorrow(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount
    );
    // 贷方领取spToken凭证
    event ClaimSpToken(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount
    );
    // 领取jpToken事件
    event ClaimJpToken(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount
    );
    // 状态变更
    event StateChange(
        uint256 indexed poolId,
        Poolstate oldState,
        Poolstate newState
    );
    // 结算事件
    event PoolSettled(
        uint256 indexed poolId,
        uint256 settleAmountLend,
        uint256 settleAmountBorrow
    );
    // 完成事件
    event PoolFinished(
        uint256 indexed poolId,
        uint256 finishAmountLend,
        uint256 finishAmountBorrow
    );
    // 清算事件
    event PoolLiquidated(
        uint256 indexed poolId,
        uint256 actualReceiveLendToken,
        uint256 timestamp
    );
    // swap事件
    event SwapExecuted(
        uint256 indexed poolId,
        uint256 amountIn,
        uint256 amountOut
    );

    // 多签合约
    modifier onlyValidCall() {
        require(
            multiSig.isValidCall(msg.sender),
            "PledgePool: not valid caller"
        );
        _;
    }
    // 校验池子是否存在
    modifier validPool(uint256 poolId) {
        require(
            pools[poolId].lendToken != address(0),
            "PledgePool: pool not exist"
        );
        _;
    }
    // 匹配期
    modifier matchState(uint256 poolId) {
        require(
            pools[poolId].state == Poolstate.MATCH,
            "PledgePool: not in MATCH state"
        );
        _;
    }
    // 非匹配期且非撤销期
    modifier notMatchOrUndone(uint256 poolId) {
        Poolstate state = pools[poolId].state;
        require(
            state != Poolstate.MATCH && state != Poolstate.UNDONE,
            "PledgePool: not in MATCH or UNDONE state"
        );
        _;
    }

    constructor(address _oracle, address _multiSig, address _feeCollector) {
        oracle = BscPledgeOracle(_oracle);
        multiSig = MultiSignature(_multiSig);
        feeCollector = _feeCollector;
    }

    /**
    创建质押池
    lendToken 借出资产 比如BUSD
    borrowToken 入资产 比如BTCB (借方质押的)
    settleTime 结算时间戳(匹配期结束, 进入执行期的时间)
    endTime 池结束时间(Finish)
    interestRate 年利率
    maxSupply 池子最大借出额度 (借出方最大存入上限)
    mortgageRate 质押率
    autoLiquidateThreshold 自动清算阈值
    return:  poolId 池子ID
    */
    function createPool(
        address _lendToken,
        address _borrowToken,
        uint256 _settleTime,
        uint256 _endTime,
        uint256 _interestRate,
        uint256 _maxSupply,
        uint256 _mortgageRate,
        uint256 _autoLiquidateThreshold,
        address _spToken,
        address _jpToken
    ) external onlyValidCall returns (uint256 poolId) {
        // 借出 借入资产非空
        require(
            _lendToken != address(0) && _borrowToken != address(0),
            "PledgePool: invalid tokens"
        );
        // 结算时间大于当前时间
        require(
            _settleTime > block.timestamp,
            "PledgePool: invalid settle time"
        );
        // 结束时间大于结算时间
        require(_endTime > _settleTime, "PledgePool: invalid endTime");
        // 年化利率大于0
        require(
            _interestRate > 0,
            "PledgePool:  interestRate need bigger than 0"
        );
        // 最大借出额度大于0
        require(_maxSupply > 0, "PledgePool:  maxSupply need bigger than 0");
        // 质押率至少1倍(1e8)
        require(
            _mortgageRate > 1e8,
            "PledgePool:  maxSupply need bigger than 1x"
        );
        // 清算阈值大于0
        require(
            _autoLiquidateThreshold > 0,
            "PledgePool:  threshold need bigger than 0"
        );
        // 凭证代币地址有效
        require(
            _spToken != address(0) && _jpToken != address(0),
            "PledgePool: invalid token addresses"
        );

        // 池子唯一ID: hash(借出资产+借入资产+当前时间戳)
        poolId = uint256(
            keccak256(
                abi.encodePacked(
                    _lendToken,
                    _borrowToken,
                    block.timestamp,
                    block.number
                )
            )
        );
        // 池子基础信息
        pools[poolId] = PoolBaseInfo({
            lendToken: _lendToken,
            borrowToken: _borrowToken,
            settleTime: _settleTime,
            endTime: _endTime,
            interestRate: _interestRate,
            maxSupply: _maxSupply,
            mortgageRate: _mortgageRate,
            autoLiquidateThreshold: _autoLiquidateThreshold,
            state: Poolstate.MATCH,
            lendSupply: 0,
            borrowSupply: 0,
            totalBorrowed: 0,
            originalLendSupply: 0,
            originalBorrowSupply: 0,
            settleAmountLend: 0,
            settleAmountBorrow: 0,
            spToken: IDebtToken(_spToken),
            jpToken: IDebtToken(_jpToken),
            liquidationAmountLend: 0,
            liquidationTime: 0,
            finishAmountLend: 0,
            finishAmountBorrow: 0
        });

        emit PoolCreated(poolId, _lendToken, _borrowToken);
        return poolId;
    }

    // ===============lender funciton ===============
    /**
    贷方存款
    poolId 质押池id
    amount 存款金额
    */
    function depositLend(
        uint256 poolId,
        uint256 amount
    ) external nonReentrant validPool(poolId) matchState(poolId) {
        require(amount >= MIN_DEPOSIT, "PledgePool: amount too small");
        PoolBaseInfo storage pool = pools[poolId];
        // 时间校验
        require(
            pool.settleTime > block.timestamp,
            "PledgePool: after settleTime"
        );
        // 存款总金额不超出
        require(
            pool.lendSupply + amount <= pool.maxSupply,
            "PledgePool: exceed maxSupply"
        );
        if (lendInfos[poolId][msg.sender].stakeAmount == 0) {
            // 新增
            lendInfos[poolId][msg.sender] = LendInfo({
                stakeAmount: amount,
                hasNoRefund: true,
                hasNoClaim: true
            });
        } else {
            // 更新该用户存款金额
            lendInfos[poolId][msg.sender].stakeAmount += amount;
        }

        // 更新借贷池总存款金额
        pool.lendSupply += amount;
        // 转账
        IERC20(pool.lendToken).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        // 触发事件
        emit DepositLend(poolId, msg.sender, amount);
    }
    /**
    领取spToken凭证
    poolId 质押池id
    */
    function claimSpToken(
        uint256 poolId
    ) external nonReentrant validPool(poolId) notMatchOrUndone(poolId) {
        PoolBaseInfo storage pool = pools[poolId];
        LendInfo storage lendInfo = lendInfos[poolId][msg.sender];
        // 用户在池中有存款
        require(lendInfo.stakeAmount > 0, "PledgePool: no deposit");
        // 未领取凭证
        require(lendInfo.hasNoClaim, "PledgePool: already claimed");
        // 结算借出金额大于0
        require(pool.settleAmountLend > 0, "PledgePool: settle amount not set");
        // 池子总存款大于0
        require(pool.lendSupply > 0, "PledgePool: no lend supply");
        // 计算用户应得份额
        uint256 userShare = (lendInfo.stakeAmount * BASE_DECIMAL) /
            pool.lendSupply;
        // 计算应领取的SpToken数量
        uint256 spTokenAmount = (pool.settleAmountLend * userShare) /
            BASE_DECIMAL;
        require(spTokenAmount > 0, "PledgePool: no spToken to claim");
        // 更新领取状态
        lendInfo.hasNoClaim = false;
        // 发送spToken
        pool.spToken.mint(msg.sender, spTokenAmount);
        // 事件
        emit ClaimSpToken(poolId, msg.sender, spTokenAmount);
    }

    // ===============borrow funcion===============
    /**
    借方抵押
    poolId 质押池id
    amount 抵押金额
    */
    function depositBorrow(
        uint256 poolId,
        uint256 amount
    ) external nonReentrant validPool(poolId) matchState(poolId) {
        require(amount >= MIN_DEPOSIT, "PledgePool: amount too small");
        PoolBaseInfo storage pool = pools[poolId];
        // 时间校验
        require(
            pool.settleTime > block.timestamp,
            "PledgePool: after settleTime"
        );
        if (borrowInfos[poolId][msg.sender].stakeAmount == 0) {
            // add
            borrowInfos[poolId][msg.sender] = BorrowInfo({
                stakeAmount: amount,
                borrowedAmount: 0,
                refundAmount: 0,
                hasNoRefund: true,
                hasNoClaim: true
            });
        } else {
            // 更新用户质押总额
            borrowInfos[poolId][msg.sender].stakeAmount += amount;
        }
        // 更新总借入质押金额
        pool.borrowSupply += amount;
        // 转账
        IERC20(pool.borrowToken).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        emit DepositBorrow(poolId, msg.sender, amount);
    }

    /**
    借入资产
    poolId 质押池id
    amount 借出金额
    deadline 交易机截止时间
    */
    function withdrawBorrow(
        uint256 poolId,
        uint256 amount,
        uint256 deadline
    ) external nonReentrant validPool(poolId) matchState(poolId) {
        require(amount >= 0, "PledgePool: amount too small");
        require(deadline >= block.timestamp, "PledgePool: deadline expired");
        PoolBaseInfo storage pool = pools[poolId];
        BorrowInfo storage borrowInfo = borrowInfos[poolId][msg.sender];
        // 用户要有质押
        require(borrowInfo.stakeAmount > 0, "PledgePool: no deposit");
        // 计算最大可借出金额
        uint256 maxBorrowable = calculateMaxBorrowable(poolId, msg.sender);
        require(amount <= maxBorrowable, "PledgePool: exceed max borrowable");
        // 池子现有可借资金
        uint256 availableLiquidity = pool.lendSupply - pool.totalBorrowed;
        require(
            availableLiquidity >= amount,
            "PledgePool: insufficient liquidity"
        );
        // 更新用户已借金额
        borrowInfo.borrowedAmount += amount;
        // 更新池子总借出金额
        pool.totalBorrowed += amount;
        // 发放jpToken
        pool.jpToken.mint(msg.sender, amount);
        // 转账借出token
        IERC20(pool.lendToken).safeTransfer(msg.sender, amount);

        emit WithdrawBorrow(poolId, msg.sender, amount);
    }
    /**
    领取借出凭证jpToken
    poolId 质押池id
    */
    function claimBorrowToken(
        uint256 poolId
    ) external nonReentrant validPool(poolId) notMatchOrUndone(poolId) {
        // 获取池子和借方信息
        PoolBaseInfo storage pool = pools[poolId];
        BorrowInfo storage borrowInfo = borrowInfos[poolId][msg.sender];
        // 用户必须借款
        require(borrowInfo.borrowedAmount > 0, "PledgePool: no borrowed");
        // 存在未领取的jpToken
        require(borrowInfo.hasNoClaim, "PledgePool: already claimed");
        // 结算质押金额设置
        require(
            pool.settleAmountBorrow > 0,
            "PledgePool: settle amount not set"
        );
        // 池子总质押大于0
        require(pool.borrowSupply > 0, "PledgePool: no borrow supply");

        // 计算用户份额比例
        uint256 userShare = (borrowInfo.stakeAmount * BASE_DECIMAL) /
            pool.borrowSupply;
        // 计算应领取的jpToken
        uint256 jpTokenAmount = (pool.settleAmountBorrow * userShare) /
            BASE_DECIMAL;
        require(jpTokenAmount > 0, "PledgePool: no jpToken to claim");
        // 更新领取状态
        borrowInfo.hasNoClaim = false;
        // 发送jpToken
        pool.jpToken.mint(msg.sender, jpTokenAmount);
        // 事件  event ClaimJpToken(uint256 indexed poolId, address indexed user, uint256 amount);
        emit ClaimJpToken(poolId, msg.sender, jpTokenAmount);
    }

    // ===============admin funcion===============
    /**
    结算
    一次性锁定借出和质押金额
    poolId 质押池id
    */
    function settle(
        uint256 poolId
    ) external nonReentrant onlyValidCall matchState(poolId) validPool(poolId) {
        PoolBaseInfo storage pool = pools[poolId];
        // 验证
        require(
            pool.settleTime <= block.timestamp,
            "PledgePool: not reach settleTime"
        );
        require(
            pool.lendSupply > 0 && pool.borrowSupply > 0,
            "PledgePool: lend & borrow must greater than 0"
        );
        // 记录原始未结算数据
        pool.originalLendSupply = pool.lendSupply;
        pool.originalBorrowSupply = pool.borrowSupply;
        // 获取资产价格
        uint256 lendTokenPrice = oracle.getPrice(pool.lendToken);
        uint256 borrowTokenPrice = oracle.getPrice(pool.borrowToken);
        require(
            borrowTokenPrice > 0 && lendTokenPrice > 0,
            "PledgePool: invalid price from oracle"
        );
        // 计算总保证金价格(以借出资产计算)
        // totalValue = borrowSupply * borrowTokenPrice / lendTokenPrice
        uint256 totalCollateralValue = (pool.borrowSupply * borrowTokenPrice) /
            lendTokenPrice;
        // 计算实际可借金额(基于质押率)
        // actualValue = totalValue * BASE_DECIMAL / mortgageRate
        uint256 maxBorrowValue = (totalCollateralValue * BASE_DECIMAL) /
            pool.mortgageRate;
        // 确定结算金额
        if (maxBorrowValue >= pool.lendSupply) {
            // 当前存款可全部借出
            pool.settleAmountLend = pool.lendSupply;
            pool.settleAmountBorrow = pool.borrowSupply;
        } else {
            // 只能满足部分借款
            pool.settleAmountLend = maxBorrowValue;
            // 计算对应借入金额
            // settleAmountBorrow = actualValue * mortgageRate / BASE_DECIMAL * lendTokenPrice / borrowTokenPrice
            uint256 numerator = maxBorrowValue *
                pool.mortgageRate *
                lendTokenPrice;
            uint256 denominator = BASE_DECIMAL * borrowTokenPrice;
            pool.settleAmountBorrow = numerator / denominator;
        }
        // 变更状态
        Poolstate oldState = pool.state;
        pool.state = Poolstate.EXECUTION;
        // 事件
        emit StateChange(poolId, oldState, Poolstate.EXECUTION);
        emit PoolSettled(
            poolId,
            pool.settleAmountLend,
            pool.settleAmountBorrow
        );
    }

    /**
    完成 finishPool
    poolId 质押池id
    */
    function finish(
        uint256 poolId
    ) external nonReentrant onlyValidCall validPool(poolId) {
        //
        PoolBaseInfo storage pool = pools[poolId];
        // 验证
        require(
            pool.state == Poolstate.EXECUTION,
            "PledgePool: no in execution"
        );
        // endtime之前可以触发, 超过endTime程序自动触发
        require(pool.endTime > block.timestamp, "PledgePool: after endTime");
        // 计算利息
        uint256 timePassed = block.timestamp - pool.settleTime;
        uint256 timeRatio = (timePassed * BASE_DECIMAL) / 365 days;
        //  利息 = timeRatio * 年利率  / 精度 * 结算借出金额
        uint256 interest = (timeRatio *
            pool.interestRate *
            pool.settleAmountLend) / (BASE_DECIMAL * BASE_DECIMAL);
        // 计算平台手续费
        uint256 platformFee = (interest * platformFeeRate) / BASE_DECIMAL;
        uint256 netInterest = interest - platformFee;
        // 结算最终金额
        uint256 finishAmountLend = pool.settleAmountLend + netInterest;
        uint256 finishAmountBorrow = pool.settleAmountBorrow;
        // 有利息, 收取平台手续费
        if (platformFee > 0 && feeCollector != address(0)) {
            IERC20(pool.lendToken).safeTransfer(feeCollector, platformFee);
        }
        // 状态变更
        Poolstate oldState = pool.state;
        pool.state = Poolstate.FINISH;

        // 事件
        emit StateChange(poolId, oldState, Poolstate.FINISH);
        emit PoolFinished(
            poolId,
            pool.finishAmountLend,
            pool.finishAmountBorrow
        );
    }

    /**
    检查是否需要清算
    return: true 需要, false 不需要
    */
    function checkLiquidate(
        uint256 poolId
    ) external view validPool(poolId) returns (bool) {
        PoolBaseInfo storage pool = pools[poolId];

        // 必须在EXECUTION状态
        if (pool.state != Poolstate.EXECUTION) {
            return false;
        }

        // 必须过了结算时间
        if (block.timestamp <= pool.settleTime) {
            return false;
        }
        // 计算当前抵押品价格
        uint256 borrowTokenPrice = oracle.getPrice(pool.borrowToken);
        uint256 lendTokenPrice = oracle.getPrice(pool.lendToken);
        if (borrowTokenPrice == 0 || lendTokenPrice == 0) {
            return false;
        }

        uint256 currentCollateralValue = (pool.settleAmountBorrow *
            borrowTokenPrice) / lendTokenPrice;
        // 计算清算阈值
        // threshold = settleAmountLend * (1 + autoLiquidateThreshold)
        uint256 thresholdNumber = pool.settleAmountLend *
            (BASE_DECIMAL + pool.autoLiquidateThreshold);
        uint256 liquidateThreshold = thresholdNumber / BASE_DECIMAL;

        // res
        return currentCollateralValue < liquidateThreshold;
    }

    /**
    清算 liquidate
    poolId 质押池id
    */
    function liquidate(
        uint256 poolId
    ) external nonReentrant onlyValidCall validPool(poolId) {
        PoolBaseInfo storage pool = pools[poolId];
        // 验证
        require(
            pool.state == Poolstate.EXECUTION,
            "PledgePool: no in execution"
        );
        // 结算时间之后
        require(
            pool.settleTime < block.timestamp,
            "PledgePool: before settleTime"
        );

        // 计算利息和费用
        uint256 timePassed = block.timestamp - pool.settleTime;
        uint256 timeRatio = (timePassed * BASE_DECIMAL) / 365 days;
        // 应计利息
        uint256 accruedInterest = (pool.settleAmountLend *
            pool.interestRate *
            timeRatio) / (BASE_DECIMAL * BASE_DECIMAL);
        // 计算平台手续费
        uint256 platformFee = (accruedInterest * platformFeeRate) /
            BASE_DECIMAL;
        // 借款人偿还总金额
        uint256 totalRepayment = pool.settleAmountLend + accruedInterest;
        // 贷方最终应得金额 = 本金 + (利息 - 平台手续费)
        uint256 lenderFinalAmount = pool.settleAmountLend +
            (accruedInterest - platformFee);

        // 计算当前抵押品价格
        uint256 borrowTokenPrice = oracle.getPrice(pool.borrowToken);
        uint256 lendTokenPrice = oracle.getPrice(pool.lendToken);
        require(
            borrowTokenPrice > 0 && lendTokenPrice > 0,
            "PledgePool: invalid price from oracle"
        );
        // 计算预期能得到的lenToken数量
        uint256 collateralValueInLendToken = (pool.settleAmountBorrow *
            borrowTokenPrice) / lendTokenPrice;
        // 记录清算前余额
        uint256 initialLendTokenBalance = IERC20(pool.lendToken).balanceOf(
            address(this)
        );
        uint256 initialBorrowTokenBalance = IERC20(pool.borrowToken).balanceOf(
            address(this)
        );
        // 执行交换   _swap暂不实现
        uint256 receiveLendToken = _swap(
            pool.borrowToken,
            pool.lendToken,
            pool.settleAmountBorrow,
            totalRepayment
        );
        // 记录清算后余额
        uint256 finalLendTokenBalance = IERC20(pool.lendToken).balanceOf(
            address(this)
        );
        uint256 finalBorrowTokenBalance = IERC20(pool.borrowToken).balanceOf(
            address(this)
        );
        // 验证交换结果
        require(
            receiveLendToken >= totalRepayment,
            "PledgePool: insufficient swap output"
        );
        require(
            finalBorrowTokenBalance ==
                initialBorrowTokenBalance - pool.settleAmountBorrow,
            "PledgePool: borrow token balance mismatch"
        );
        // 实际收到的lenToken数量
        uint256 actualReceiveLendToken = finalLendTokenBalance -
            initialLendTokenBalance;
        pool.liquidationAmountLend = actualReceiveLendToken;
        pool.liquidationTime = block.timestamp;
        // swap事件
        emit SwapExecuted(
            poolId,
            pool.settleAmountBorrow,
            actualReceiveLendToken
        );
        // 分配交换收益
        if (platformFee > 0 && feeCollector != address(0)) {
            IERC20(pool.lendToken).safeTransfer(feeCollector, platformFee);
        }
        // 计算贷方应得金额
        pool.finishAmountLend = lenderFinalAmount;
        pool.finishAmountBorrow = 0; // 清算后borrow清空
        if (actualReceiveLendToken > totalRepayment) {
            // 如果手机swap之后资金大于总需还款 . .. .
        }
        // 更新状态
        Poolstate oldState = pool.state;
        pool.state = Poolstate.LIQUIDATION;

        // 事件
        emit StateChange(poolId, oldState, Poolstate.LIQUIDATION);
        emit PoolLiquidated(poolId, actualReceiveLendToken, block.timestamp);
    }

    // ==================== utils =============================
    /**
    计算用户最大可借额度
    */
    function calculateMaxBorrowable(
        uint256 poolId,
        address user
    ) public view validPool(poolId) returns (uint256) {
        PoolBaseInfo storage pool = pools[poolId];
        BorrowInfo storage borrowInfo = borrowInfos[poolId][user];

        if (borrowInfo.stakeAmount == 0) {
            return 0;
        }

        // 获取资产价格
        uint256 borrowTokenPrice = oracle.getPrice(pool.borrowToken);
        uint256 lendTokenPrice = oracle.getPrice(pool.lendToken);

        // 抵押品总价值 = 质押金额 × borrowToken价格
        uint256 collateralValue = borrowInfo.stakeAmount * borrowTokenPrice;

        // 最大可借额度（以lendToken为单位）= 抵押品总价值 ÷ 质押率 ÷ lendToken价格
        uint256 maxBorrowValue = (collateralValue * BASE_DECIMAL) /
            pool.mortgageRate;
        uint256 maxBorrowAmount = maxBorrowValue / lendTokenPrice;

        // 减去已借金额
        uint256 available = maxBorrowAmount > borrowInfo.borrowedAmount
            ? maxBorrowAmount - borrowInfo.borrowedAmount
            : 0;

        return available;
    }

    /**
    计算抵押品价值（以借出资产计价）
    */
    function calculateCollateralValue(
        uint256 poolId,
        address user
    ) internal view returns (uint256) {
        PoolBaseInfo storage pool = pools[poolId];
        BorrowInfo storage borrowInfo = borrowInfos[poolId][user];

        uint256 borrowTokenPrice = oracle.getPrice(pool.borrowToken);
        uint256 lendTokenPrice = oracle.getPrice(pool.lendToken);

        return (borrowInfo.stakeAmount * borrowTokenPrice) / lendTokenPrice;
    }

    /**
    计算借款价值（以借出资产计价）
    */
    function calculateBorrowValue(
        uint256 poolId,
        uint256 amount
    ) internal view returns (uint256) {
        // 对于借款，直接返回金额，因为借出资产就是计价单位
        return amount;
    }

    /**
     * 内部函数：执行代币交换（假函数，后续替换为Uniswap V2真实调用）
     */
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        // 这里使用假函数模拟Uniswap交换
        // 实际部署时应替换为以下逻辑：
        /*
        // 1. 批准Uniswap Router使用tokenIn
        IERC20(tokenIn).safeApprove(uniswapRouter, amountIn);
        
        // 2. 设置交换路径
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        
        // 3. 执行交换
        uint256[] memory amounts = IUniswapV2Router(uniswapRouter).swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            block.timestamp + 300  // 5分钟截止时间
        );
        
        // 4. 返回得到的tokenOut数量
        return amounts[amounts.length - 1];
        */

        // 假函数实现：模拟交换，假设1:1交换（仅用于测试）
        // 注意：实际价格应由Uniswap提供，这里只是占位符
        amountOut = amountIn; // 假定的1:1交换

        // 模拟token转移
        IERC20(tokenIn).safeTransfer(
            address(0x1111111111111111111111111111111111111111),
            amountIn
        );
        IERC20(tokenOut).safeTransferFrom(
            address(0x1111111111111111111111111111111111111111),
            address(this),
            amountOut
        );

        return amountOut;
    }
}
