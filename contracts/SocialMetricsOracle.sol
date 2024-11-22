// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract SocialMetricsOracle is ChainlinkClient, AutomationCompatibleInterface, UUPSUpgradeable,
OwnableUpgradeable {
    using Chainlink for Chainlink.Request;

    // Oracle configuration
    address private oracle;
    bytes32 private jobId;
    uint256 private fee;

    // Social metrics data
    struct SocialMetrics {
        uint256 tweetCount;
        uint256 sentimentScore;
        uint256 engagementRate;
        uint256 timestamp;
    }

    SocialMetrics public latestMetrics;
    uint256 public updateInterval;
    uint256 public lastUpdateTimestamp;

    // Events
    event MetricsUpdated(
        uint256 tweetCount,
        uint256 sentimentScore,
        uint256 engagementRate,
        uint256 timestamp
    );
    event OracleConfigUpdated(
        address indexed oracle,
        bytes32 indexed jobId,
        uint256 fee
    );

    // Modifiers
    modifier onlyValidUpdate() {
        require(
            block.timestamp >= lastUpdateTimestamp + updateInterval,
            "Update interval not elapsed"
        );
        _;
    }

    // Initialize function for upgradeable pattern
    function initialize(
        address _chainlinkToken,
        address _oracle,
        bytes32 _jobId,
        uint256 _fee,
        uint256 _updateInterval
    ) public initializer {
        __UUPSUpgradeable_init();
        
        _setChainlinkToken(_chainlinkToken);
        oracle = _oracle;
        jobId = _jobId;
        fee = _fee;
        updateInterval = _updateInterval;
        
        emit OracleConfigUpdated(oracle, jobId, fee);
    }

    // Request social metrics update
    function requestSocialMetrics() public onlyValidUpdate returns (bytes32) {
        Chainlink.Request memory request = _buildChainlinkRequest(
            jobId,
            address(this),
            this.fulfillSocialMetrics.selector
        );

        // Add parameters for the oracle job
        request._add("hashtag", "$SOCIALTOKEN");
        request._add("endpoint", "social_metrics");
        request._add("timeframe", "24h");
        
        // Additional parameters for detailed metrics
        request._add("metrics", "tweets,sentiment,engagement");
        request._add("aggregation", "weighted_average");
        
        // Send the request
        return _sendChainlinkRequestTo(oracle, request, fee);
    }

    // Callback function for Chainlink response
    function fulfillSocialMetrics(
        bytes32 _requestId,
        uint256 _tweetCount,
        uint256 _sentimentScore,
        uint256 _engagementRate
    ) public recordChainlinkFulfillment(_requestId) {
        latestMetrics = SocialMetrics({
            tweetCount: _tweetCount,
            sentimentScore: _sentimentScore,
            engagementRate: _engagementRate,
            timestamp: block.timestamp
        });
        
        lastUpdateTimestamp = block.timestamp;
        
        emit MetricsUpdated(
            _tweetCount,
            _sentimentScore,
            _engagementRate,
            block.timestamp
        );
    }

    // Chainlink Keeper compatible function
   function checkUpkeep(bytes calldata /* checkData */)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp - lastUpdateTimestamp) >= updateInterval;
        performData = ""; // Empty bytes as we don't need to pass any data to performUpkeep
        return (upkeepNeeded, performData);
    }

    // Chainlink Keeper performs this function
    function performUpkeep(bytes calldata /* performData */) external override {
        if ((block.timestamp - lastUpdateTimestamp) >= updateInterval) {
            requestSocialMetrics();
        }
    }

    // Admin functions
    function updateOracleConfig(
        address _oracle,
        bytes32 _jobId,
        uint256 _fee
    ) external onlyOwner {
        oracle = _oracle;
        jobId = _jobId;
        fee = _fee;
        
        emit OracleConfigUpdated(oracle, jobId, fee);
    }

    function updateIntervals(uint256 _updateInterval) external onlyOwner {
        updateInterval = _updateInterval;
    }

    // UUPS required function
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // View functions
    function getLatestMetrics() external view returns (SocialMetrics memory) {
        return latestMetrics;
    }

    function getOracleConfig() external view returns (
        address _oracle,
        bytes32 _jobId,
        uint256 _fee
    ) {
        return (oracle, jobId, fee);
    }
}