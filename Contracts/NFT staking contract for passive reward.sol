// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title NFTStakingContract
 * @dev A contract that allows users to stake NFTs and earn passive rewards in ERC20 tokens
 */
contract NFTStakingContract is ReentrancyGuard, Ownable, Pausable {
    
    // Struct to store staking information
    struct StakeInfo {
        address owner;
        uint256 tokenId;
        uint256 stakedAt;
        uint256 lastRewardCalculation;
    }
    
    // Events
    event NFTStaked(address indexed user, uint256 indexed tokenId, uint256 timestamp);
    event NFTUnstaked(address indexed user, uint256 indexed tokenId, uint256 timestamp);
    event RewardsClaimed(address indexed user, uint256 amount, uint256 timestamp);
    event RewardRateUpdated(uint256 newRate);
    
    // State variables
    IERC721 public immutable nftContract;
    IERC20 public immutable rewardToken;
    
    uint256 public rewardRate; // Rewards per second per staked NFT (in wei)
    uint256 public totalStaked;
    
    // Mappings
    mapping(uint256 => StakeInfo) public stakedNFTs; // tokenId => StakeInfo
    mapping(address => uint256[]) public userStakedTokens; // user => array of tokenIds
    mapping(uint256 => bool) public isStaked; // tokenId => staking status
    
    /**
     * @dev Constructor to initialize the staking contract
     * @param _nftContract Address of the NFT contract that can be staked
     * @param _rewardToken Address of the ERC20 token used for rewards
     * @param _rewardRate Initial reward rate (rewards per second per NFT in wei)
     */
    constructor(
        address _nftContract,
        address _rewardToken,
        uint256 _rewardRate
    ) Ownable(msg.sender) {
        require(_nftContract != address(0), "Invalid NFT contract address");
        require(_rewardToken != address(0), "Invalid reward token address");
        require(_rewardRate > 0, "Reward rate must be greater than 0");
        
        nftContract = IERC721(_nftContract);
        rewardToken = IERC20(_rewardToken);
        rewardRate = _rewardRate;
    }
    
    /**
     * @dev Core Function 1: Stake NFTs to earn passive rewards
     * @param tokenIds Array of NFT token IDs to stake
     */
    function stakeNFTs(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0, "Must stake at least one NFT");
        require(tokenIds.length <= 20, "Cannot stake more than 20 NFTs at once");
        
        // Claim any pending rewards before staking new NFTs
        if (userStakedTokens[msg.sender].length > 0) {
            _claimRewards(msg.sender);
        }
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Check if NFT is already staked
            require(!isStaked[tokenId], "NFT is already staked");
            
            // Verify ownership and approval
            require(nftContract.ownerOf(tokenId) == msg.sender, "Not the owner of this NFT");
            require(
                nftContract.getApproved(tokenId) == address(this) || 
                nftContract.isApprovedForAll(msg.sender, address(this)),
                "Contract not approved to transfer this NFT"
            );
            
            // Transfer NFT to this contract
            nftContract.transferFrom(msg.sender, address(this), tokenId);
            
            // Update staking info
            stakedNFTs[tokenId] = StakeInfo({
                owner: msg.sender,
                tokenId: tokenId,
                stakedAt: block.timestamp,
                lastRewardCalculation: block.timestamp
            });
            
            // Mark as staked
            isStaked[tokenId] = true;
            
            // Add to user's staked tokens
            userStakedTokens[msg.sender].push(tokenId);
            
            emit NFTStaked(msg.sender, tokenId, block.timestamp);
        }
        
        totalStaked += tokenIds.length;
    }
    
    /**
     * @dev Core Function 2: Unstake NFTs and claim accumulated rewards
     * @param tokenIds Array of NFT token IDs to unstake
     */
    function unstakeNFTs(uint256[] calldata tokenIds) external nonReentrant {
        require(tokenIds.length > 0, "Must unstake at least one NFT");
        
        // Claim all pending rewards first
        _claimRewards(msg.sender);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Check if NFT is actually staked
            require(isStaked[tokenId], "NFT is not staked");
            require(stakedNFTs[tokenId].owner == msg.sender, "Not the owner of this staked NFT");
            
            // Transfer NFT back to owner
            nftContract.transferFrom(address(this), msg.sender, tokenId);
            
            // Remove from user's staked tokens array
            _removeTokenFromUserArray(msg.sender, tokenId);
            
            // Clear staking info and mark as unstaked
            delete stakedNFTs[tokenId];
            isStaked[tokenId] = false;
            
            emit NFTUnstaked(msg.sender, tokenId, block.timestamp);
        }
        
        totalStaked -= tokenIds.length;
    }
    
    /**
     * @dev Core Function 3: Claim accumulated rewards without unstaking
     */
    function claimRewards() external nonReentrant {
        require(userStakedTokens[msg.sender].length > 0, "No NFTs staked");
        _claimRewards(msg.sender);
    }
    
    /**
     * @dev Internal function to calculate and distribute rewards
     * @param user Address of the user to claim rewards for
     */
    function _claimRewards(address user) internal {
        uint256 totalRewards = calculatePendingRewards(user);
        
        if (totalRewards > 0) {
            // Check if contract has enough reward tokens
            require(rewardToken.balanceOf(address(this)) >= totalRewards, "Insufficient reward tokens in contract");
            
            // Update last reward calculation time for all user's staked NFTs
            uint256[] storage userTokens = userStakedTokens[user];
            for (uint256 i = 0; i < userTokens.length; i++) {
                uint256 tokenId = userTokens[i];
                if (isStaked[tokenId]) {
                    stakedNFTs[tokenId].lastRewardCalculation = block.timestamp;
                }
            }
            
            // Transfer rewards
            require(rewardToken.transfer(user, totalRewards), "Reward transfer failed");
            
            emit RewardsClaimed(user, totalRewards, block.timestamp);
        }
    }
    
    /**
     * @dev Calculate pending rewards for a user
     * @param user Address of the user
     * @return Total pending rewards
     */
    function calculatePendingRewards(address user) public view returns (uint256) {
        uint256[] memory userTokens = userStakedTokens[user];
        uint256 totalRewards = 0;
        
        for (uint256 i = 0; i < userTokens.length; i++) {
            uint256 tokenId = userTokens[i];
            if (isStaked[tokenId]) {
                StakeInfo memory stakeInfo = stakedNFTs[tokenId];
                uint256 timeStaked = block.timestamp - stakeInfo.lastRewardCalculation;
                totalRewards += timeStaked * rewardRate;
            }
        }
        
        return totalRewards;
    }
    
    /**
     * @dev Get all staked token IDs for a user
     * @param user Address of the user
     * @return Array of token IDs
     */
    function getUserStakedTokens(address user) external view returns (uint256[] memory) {
        return userStakedTokens[user];
    }
    
    /**
     * @dev Get staking information for a specific token
     * @param tokenId The NFT token ID
     * @return StakeInfo struct
     */
    function getStakeInfo(uint256 tokenId) external view returns (StakeInfo memory) {
        return stakedNFTs[tokenId];
    }
    
    /**
     * @dev Remove a token from user's staked tokens array
     * @param user Address of the user
     * @param tokenId Token ID to remove
     */
    function _removeTokenFromUserArray(address user, uint256 tokenId) internal {
        uint256[] storage userTokens = userStakedTokens[user];
        for (uint256 i = 0; i < userTokens.length; i++) {
            if (userTokens[i] == tokenId) {
                userTokens[i] = userTokens[userTokens.length - 1];
                userTokens.pop();
                break;
            }
        }
    }
    
    // Admin functions
    
    /**
     * @dev Update the reward rate (only owner)
     * @param newRate New reward rate per second per NFT
     */
    function updateRewardRate(uint256 newRate) external onlyOwner {
        require(newRate > 0, "Reward rate must be greater than 0");
        rewardRate = newRate;
        emit RewardRateUpdated(newRate);
    }
    
    /**
     * @dev Withdraw reward tokens (only owner)
     * @param amount Amount to withdraw
     */
    function withdrawRewardTokens(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        require(rewardToken.balanceOf(address(this)) >= amount, "Insufficient balance");
        require(rewardToken.transfer(owner(), amount), "Transfer failed");
    }
    
    /**
     * @dev Emergency function to pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Get contract statistics
     * @return totalStaked_ Total number of staked NFTs
     * @return rewardRate_ Current reward rate
     * @return contractBalance Current reward token balance
     */
    function getContractStats() external view returns (
        uint256 totalStaked_,
        uint256 rewardRate_,
        uint256 contractBalance
    ) {
        return (
            totalStaked,
            rewardRate,
            rewardToken.balanceOf(address(this))
        );
    }
}
