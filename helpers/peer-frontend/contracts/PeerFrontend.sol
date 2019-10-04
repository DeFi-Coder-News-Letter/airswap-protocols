/*
  Copyright 2019 Swap Holdings Ltd.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/

pragma solidity 0.5.10;
pragma experimental ABIEncoderV2;

import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "@airswap/indexer/contracts/interfaces/IIndexer.sol";
import "@airswap/peer/contracts/interfaces/IPeer.sol";
import "@airswap/swap/contracts/interfaces/ISwap.sol";

/**
  * @title PeerFrontend: Onchain Liquidity provider for the Swap Protocol
  */
contract PeerFrontend {

  uint256 constant public MAX_INT =  2**256 - 1;

  IIndexer public indexer;
  ISwap public swapContract;

  constructor(address _indexer, address _swap) public {
    indexer = IIndexer(_indexer);
    swapContract = ISwap(_swap);
  }

  /**
    * @notice Get a Sender-Side Quote from the Onchain Liquidity provider
    * @dev want to fetch the lowest _signerAmount for requested _senderAmount
    * @dev if no suitable Peer found, defaults to 0x0 peerLocator
    * @param _senderAmount uint256 The amount of ERC-20 token the peer would send
    * @param _senderToken address The address of an ERC-20 token the peer would send
    * @param _signerToken address The address of an ERC-20 token the signer would send
    * @param _maxIntents uint256 The maximum number of Peers to query
    * @return peerAddress bytes32 The locator to connect to the peer
    * @return lowestCost uint256 The amount of ERC-20 tokens the signer would send
    */
  function getBestSenderSideQuote(
    uint256 _senderAmount,
    address _senderToken,
    address _signerToken,
    uint256 _maxIntents
  ) public view returns (bytes32 peerAddress, uint256 lowestAmount) {


    // use the indexer to query peers
    lowestAmount = MAX_INT;

    // Fetch an array of locators from the Indexer.
    bytes32[] memory locators = indexer.getIntents(
      _signerToken,
      _senderToken,
      _maxIntents
      );

    // Iterate through locators.
    for (uint256 i; i < locators.length; i++) {

      // Get a buy quote from the Peer.
      uint256 signerAmount = IPeer(address(bytes20(locators[i])))
        .getSignerSideQuote(_senderAmount, _senderToken, _signerToken);

      // Update the lowest cost.
      if (signerAmount > 0 && signerAmount < lowestAmount) {
        peerAddress = locators[i];
        lowestAmount = signerAmount;
      }
    }

    // Return the Peer address and amount.
    return (peerAddress, lowestAmount);

  }

  /**
    * @notice Get a Signer-Side Quote from the Onchain Liquidity provider
    * @dev want to fetch the highest _senderAmount for requested _signerAmount
    * @dev if no suitable Peer found, peerLocator will be 0x0
    * @param _signerAmount uint256 The amount of ERC-20 token the signer would send
    * @param _signerToken address The address of an ERC-20 token the signer would send
    * @param _senderToken address The address of an ERC-20 token the peer would send
    * @param _maxIntents uint256 The maximum number of Peers to query
    * @return peerLocator bytes32  The locator to connect to the peer
    * @return highAmount uint256 The amount of ERC-20 tokens the peer would send
    */
  function getBestSignerSideQuote(
    uint256 _signerAmount,
    address _signerToken,
    address _senderToken,
    uint256 _maxIntents
  ) public view returns (bytes32 peerLocator, uint256 highAmount) {

    // use the indexer to query peers
    highAmount = 0;

    // Fetch an array of locators from the Indexer.
    bytes32[] memory locators = indexer.getIntents(
      _signerToken,
      _senderToken,
      _maxIntents
      );

    // Iterate through locators.
    for (uint256 i; i < locators.length; i++) {

      // Get a buy quote from the Peer.
      uint256 senderAmount = IPeer(address(bytes20(locators[i])))
        .getSenderSideQuote(_signerAmount, _signerToken, _senderToken);

      // Update the highest amount.
      if (senderAmount > 0 && senderAmount > highAmount) {
        peerLocator = locators[i];
        highAmount = senderAmount;
      }
    }

    // Return the Peer address and amount.
    return (peerLocator, highAmount);
  }

  /**
    * @notice Get and fill Sender-Side Quote from the Onchain Liquidity provider
    * @dev want to fetch the lowest _signerAmount for requested _senderAmount
    * @dev if no suitable Peer found, will revert by checking peerLocator is 0x0
    * @param _senderAmount uint256 The amount of ERC-20 token the peer would send
    * @param _senderToken address The address of an ERC-20 token the peer would send
    * @param _signerToken address The address of an ERC-20 token the signer would send
    * @param _maxIntents uint256 The maximum number of Peers to query
    */
  function fillBestSenderSideOrder(
    uint256 _senderAmount,
    address _senderToken,
    address _signerToken,
    uint256 _maxIntents
  ) external {

    // Find the best locator and amount on Indexed Peers.
    (bytes32 peerLocator, uint256 signerAmount) = getBestSenderSideQuote(
      _senderAmount,
      _senderToken,
      _signerToken,
      _maxIntents
    );

    // check if peerLocator exists
    require(peerLocator != bytes32(0), "NO_LOCATOR, BAILING");

    address peerContract = address(bytes20(peerLocator));

    // User transfers amount to the contract.
    IERC20(_signerToken).transferFrom(msg.sender, address(this), signerAmount);

    // PeerFrontend approves Swap to move its new tokens.
    IERC20(_signerToken).approve(address(swapContract), signerAmount);

    // PeerFrontend authorizes the Peer.
    swapContract.authorize(peerContract, block.timestamp + 1);

    // PeerFrontned provides unsigned order to Peer.
    IPeer(peerContract).provideOrder(Types.Order(
      uint256(keccak256(abi.encodePacked(
        block.timestamp,
        address(this),
        _signerToken,
        IPeer(peerContract).tradeWallet(),
        _senderToken))),
      block.timestamp + 1,
      Types.Party(
        address(this),
        _signerToken,
        signerAmount,
        0x277f8169
      ),
      Types.Party(
        IPeer(peerContract).tradeWallet(),
        _senderToken,
        _senderAmount,
        0x277f8169
      ),
      Types.Party(address(0), address(0), 0, bytes4(0)),
      Types.Signature(address(0), 0, 0, 0, 0)
    ));

    // PeerFrontend revokes the authorization of the Peer.
    swapContract.revoke(peerContract);

    // PeerFrontend transfers received amount to the User.
    IERC20(_senderToken).transfer(msg.sender, _senderAmount);
  }

  /**
    * @notice Get and fill Signer-Side Quote from the Onchain Liquidity provider
    * @dev want to fetch the highest _signerAmount for requested _senderAmount
    * @dev if no suitable Peer found, will revert by checking peerLocator is 0x0
    * @param _signerAmount uint256 The amount of ERC-20 token the signer would send
    * @param _signerToken address The address of an ERC-20 token the signer would send
    * @param _senderToken address The address of an ERC-20 token the peer would send
    * @param _maxIntents uint256 The maximum number of Peers to query
    */
  function fillBestSignerSideOrder(
    uint256 _signerAmount,
    address _signerToken,
    address _senderToken,
    uint256 _maxIntents
  ) external {

    // Find the best locator and amount on Indexed Peers.
    (bytes32 peerLocator, uint256 senderAmount) = getBestSignerSideQuote(
      _signerAmount,
      _signerToken,
      _senderToken,
      _maxIntents
    );

    // check if peerLocator exists
    require(peerLocator != bytes32(0), "NO_LOCATOR, BAILING");

    address peerContract = address(bytes20(peerLocator));

    // User transfers amount to the contract.
    IERC20(_signerToken).transferFrom(msg.sender, address(this), _signerAmount);

    // PeerFrontend approves Swap to move its new tokens.
    IERC20(_signerToken).approve(address(swapContract), _signerAmount);

    // PeerFrontend authorizes the Peer.
    swapContract.authorize(peerContract, block.timestamp + 1);

    // Consumer provides unsigned order to Peer.
    IPeer(peerContract).provideOrder(Types.Order(
      uint256(keccak256(abi.encodePacked(
        block.timestamp,
        address(this),
        _signerToken,
        IPeer(peerContract).tradeWallet(),
        _senderToken
      ))),
      block.timestamp + 1,
      Types.Party(
        address(this),
        _signerToken,
        _signerAmount,
        0x277f8169
      ),
      Types.Party(
        IPeer(peerContract).tradeWallet(),
        _senderToken,
        senderAmount,
        0x277f8169
      ),
      Types.Party(address(0), address(0), 0, bytes4(0)),
      Types.Signature(address(0), 0, 0, 0, 0)
    ));

    // PeerFrontend revokes the authorization of the Peer.
    swapContract.revoke(peerContract);

    // PeerFrontend transfers received amount to the User.
    IERC20(_senderToken).transfer(msg.sender, senderAmount);
  }
}