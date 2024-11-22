// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface ISocialMetricsOracle {
    struct SocialMetrics {
        uint256 tweetCount;
        uint256 sentimentScore;
        uint256 engagementRate;
        uint256 timestamp;
    }
    
    function getLatestMetrics() external view returns (SocialMetrics memory);
    function requestSocialMetrics() external returns (bytes32);
}

contract SocialToken is ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable, PausableUpgradeable {
    using SafeMath for uint256;

    // Oracle interface
    ISocialMetricsOracle public socialOracle;
    
    // Token mechanics configuration
    struct TokenMechanics {
        uint256 minSentimentScore;      // Minimum sentiment score for positive action
        uint256 minEngagementRate;      // Minimum engagement rate for positive action
        uint256 minTweetCount;          // Minimum tweet count for valid metrics
        uint256 rewardBaseAmount;       // Base amount for rewards
        uint256 penaltyBaseAmount;      // Base amount for penalties
        uint256 cooldownPeriod;         // Cooldown between mechanics triggers
    }
    
    TokenMechanics public mechanics;
    
    // Tracking variables
    uint256 public lastMechanicsUpdate;
    mapping(address => uint256) public lastRewardClaim;
    
    // Events
    event OracleUpdated(address indexed newOracle);
    event MechanicsUpdated(TokenMechanics mechanics);
    event RewardDistributed(uint256 amount, uint256 sentimentScore, uint256 engagementRate);
    event PenaltyApplied(uint256 amount, uint256 sentimentScore, uint256 engagementRate);

    // Errors
    error InvalidOracleAddress();
    error CooldownPeriodNotElapsed();
    error InvalidMetricsTimestamp();
    error InsufficientTweetCount();
    error RewardClaimTooSoon();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address _socialOracle,
        TokenMechanics memory _mechanics
    ) public initializer {
        __ERC20_init(name, symbol);
        __Ownable_init(msg.sender);
        __Pausable_init();
        __UUPSUpgradeable_init();

        if (_socialOracle == address(0)) revert InvalidOracleAddress();
        socialOracle = ISocialMetricsOracle(_socialOracle);
        mechanics = _mechanics;
        
        // Mint initial supply
        _mint(msg.sender, 1000000 * 10**decimals());
    }

    // Oracle integration functions
    function updateBasedOnMetrics() external whenNotPaused {
        if (block.timestamp < lastMechanicsUpdate + mechanics.cooldownPeriod) 
            revert CooldownPeriodNotElapsed();

        ISocialMetricsOracle.SocialMetrics memory metrics = socialOracle.getLatestMetrics();
        
        // Validate metrics
        if (block.timestamp - metrics.timestamp > 1 hours) 
            revert InvalidMetricsTimestamp();
        if (metrics.tweetCount < mechanics.minTweetCount) 
            revert InsufficientTweetCount();

        // Calculate reward/penalty
        if (
            metrics.sentimentScore >= mechanics.minSentimentScore &&
            metrics.engagementRate >= mechanics.minEngagementRate
        ) {
            _handlePositiveMetrics(metrics);
        } else {
            _handleNegativeMetrics(metrics);
        }

        lastMechanicsUpdate = block.timestamp;
        
        // Request new metrics for next update
        socialOracle.requestSocialMetrics();
    }

    function claimReward() external whenNotPaused {
        if (block.timestamp < lastRewardClaim[msg.sender] + mechanics.cooldownPeriod)
            revert RewardClaimTooSoon();

        ISocialMetricsOracle.SocialMetrics memory metrics = socialOracle.getLatestMetrics();
        
        uint256 rewardAmount = _calculateReward(
            metrics.sentimentScore,
            metrics.engagementRate,
            balanceOf(msg.sender)
        );

        if (rewardAmount > 0) {
            _mint(msg.sender, rewardAmount);
            lastRewardClaim[msg.sender] = block.timestamp;
        }
    }

    // Internal functions
    function _handlePositiveMetrics(ISocialMetricsOracle.SocialMetrics memory metrics) internal {
        uint256 rewardAmount = _calculateReward(
            metrics.sentimentScore,
            metrics.engagementRate,
            totalSupply()
        );

        if (rewardAmount > 0) {
            _burn(address(this), rewardAmount);
            emit RewardDistributed(rewardAmount, metrics.sentimentScore, metrics.engagementRate);
        }
    }

    function _handleNegativeMetrics(ISocialMetricsOracle.SocialMetrics memory metrics) internal {
        uint256 penaltyAmount = _calculatePenalty(
            metrics.sentimentScore,
            metrics.engagementRate,
            totalSupply()
        );

        if (penaltyAmount > 0) {
            _mint(address(this), penaltyAmount);
            emit PenaltyApplied(penaltyAmount, metrics.sentimentScore, metrics.engagementRate);
        }
    }

    function _calculateReward(
        uint256 sentimentScore,
        uint256 engagementRate,
        uint256 baseAmount
    ) internal view returns (uint256) {
        uint256 sentimentMultiplier = sentimentScore.sub(mechanics.minSentimentScore);
        uint256 engagementMultiplier = engagementRate.sub(mechanics.minEngagementRate);
        
        return mechanics.rewardBaseAmount
            .mul(sentimentMultiplier)
            .mul(engagementMultiplier)
            .mul(baseAmount)
            .div(10000) // Adjust for precision
            .div(100);  // Scale down multipliers
    }

    function _calculatePenalty(
        uint256 sentimentScore,
        uint256 engagementRate,
        uint256 baseAmount
    ) internal view returns (uint256) {
        uint256 sentimentDiff = mechanics.minSentimentScore > sentimentScore ? 
            mechanics.minSentimentScore.sub(sentimentScore) : 0;
        uint256 engagementDiff = mechanics.minEngagementRate > engagementRate ? 
            mechanics.minEngagementRate.sub(engagementRate) : 0;
        
        return mechanics.penaltyBaseAmount
            .mul(sentimentDiff)
            .mul(engagementDiff)
            .mul(baseAmount)
            .div(10000) // Adjust for precision
            .div(100);  // Scale down multipliers
    }

    // Admin functions
    function updateOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert InvalidOracleAddress();
        socialOracle = ISocialMetricsOracle(newOracle);
        emit OracleUpdated(newOracle);
    }

    function updateMechanics(TokenMechanics memory newMechanics) external onlyOwner {
        mechanics = newMechanics;
        emit MechanicsUpdated(newMechanics);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // UUPS required function
    function _authorizeUpgrade(address) internal override onlyOwner {}
}