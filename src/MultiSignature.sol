// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AddressPrivileges} from "./AddressPrivileges.sol";

// 多签治理
contract MultiSignature {
    // 提案结构体
    struct Proposal {
        address target; // 提案要调用的目标合约
        bytes data;     // 调用目标地址时的calldata(函数签名 + 参数)
        uint256 value; // 调用时发送的ETH
        bool executed; // 提案是否执行
        uint256 voteCount; // 提案当前已获得有效票数
    }

    address[] public admins; // 多签管理员列表
    uint256 public requiredVotes; // 执行提前需最小票数
    mapping(uint256 => Proposal) public proposals; // 提前id到提案结构体
    uint256 public proposalCount; // 提案计算器, 用于生成唯一提案ID

    // 独立的嵌套映射：proposalId -> address -> bool
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // 创建提案
    event ProposalCreated(uint256 indexed id, address target, bytes data, uint256 value);
    // 投票
    event VoteCast(uint256 indexed id, address indexed voter);
    // 提案执行
    event ProposalExecuted(uint256 indexed id);

    constructor(address[] memory _admins, uint256 _requiredVotes) {
        require(_requiredVotes > 0 && _requiredVotes <= _admins.length, "MultiSignature: empty admins");
        admins = _admins;
        requiredVotes = _requiredVotes;
    }

    modifier onlyAdmin() {
        bool isAdmin = false;
        for (uint256 i=0; i < admins.length; i++) {
            if (admins[i] == msg.sender) {
                isAdmin = true;
                break;
            }
        }
        require(isAdmin, "MultiSignature: not admin");
        _;
    }

    /**
     创建多签提案
     target 提案要调用的目标合约
     data  提案调用目标合约的calldata
     value 提案调用时发送的ETH
     return 提案id
    */
    function createProposal(
        address target,
        bytes memory data, 
        uint256 value) 
        external onlyAdmin returns (uint256) {
        
        // 提案id
        proposalCount++;
        // 创建结构体
        proposals[proposalCount] = Proposal({
            target: target,
            data: data,
            value: value,
            executed: false,
            voteCount: 0
        });
        // 事件
        emit ProposalCreated(proposalCount, target, data, value);
        return proposalCount;
    }

    /**
     为指定提案投票
     proposalId 提案id
    */
    function vote(uint256 proposalId) external onlyAdmin {
        // 查询结构体 & 验证
        Proposal storage proposal = proposals[proposalId];
        require(proposal.executed == false, "MultiSignature: proposal has executed");
        require(hasVoted[proposalId][msg.sender] == false, "MultiSignature: already voted");

        // 标记hasVoted投票地址
        hasVoted[proposalId][msg.sender] = true;
        // 增加提案有效数
        proposal.voteCount++;

        // 事件
        emit VoteCast(proposalId, msg.sender);

        // 若投票达到阈值, 自动执行提案
        if (proposal.voteCount >= requiredVotes) {
            _execute(proposalId);
        }
    }

    // 内部函数  执行提案
    function _execute(uint256 proposalId) internal {
        // 获取提案 && 验证
        Proposal storage proposal = proposals[proposalId];
        require(proposal.executed == false, "MultiSignature: proposal has executed");
        // 标记提案执行
        proposal.executed = true;

        // 调用目标地址执行并返回结果
        (bool success, ) = proposal.target.call{value: proposal.value}(proposal.data);
        // 校验是否成功
        require(success, "MultiSignature: call failed");
        // 触发事件
        emit ProposalExecuted(proposalId);
    }

    // 供外部合约验证调用者是否为有效的多签管理员
    function isValidCall(address caller) external view returns(bool) {
        for(uint256 i=0; i < admins.length; i++) {
            if (admins[i] == caller) {
                return true;
            }
        }
        return false;
    }

}