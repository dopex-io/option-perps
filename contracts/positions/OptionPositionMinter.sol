//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// Contracts
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";

contract OptionPositionMinter is
  ReentrancyGuard,
  ERC721('OP-OptionPosition', 'OPOP'),
  ERC721Enumerable,
  Ownable {

  using Counters for Counters.Counter;

  /// @dev Token ID counter for straddle positions
  Counters.Counter private _tokenIdCounter;

  address public optionPerpContract;

  constructor() {
    optionPerpContract = msg.sender;
  }

  function setOptionPerpContract(address _optionPerpContract)
  public
  onlyOwner {
    optionPerpContract = _optionPerpContract;
  }

  function mint(address to) public returns (uint tokenId) {
    require(
      msg.sender == optionPerpContract,
      "Only option perp contract can mint an option perp position token"
    );

    tokenId = _tokenIdCounter.current();

    _tokenIdCounter.increment();

    _safeMint(to, tokenId);
    return tokenId;
  }

  // The following functions are overrides required by Solidity.
  function _beforeTokenTransfer(
      address from,
      address to,
      uint256 tokenId,
      uint256 batchSize
  ) internal override(ERC721, ERC721Enumerable) {
      super._beforeTokenTransfer(from, to, tokenId, batchSize);
  }

  function supportsInterface(bytes4 interfaceId)
      public
      view
      override(ERC721, ERC721Enumerable)
      returns (bool)
  {
      return super.supportsInterface(interfaceId);
  }

  /// @notice Returns the tokenIds owned by a wallet
  /// @param owner wallet owner
  function positionsOfOwner(address owner)
      public
      view
      returns (uint256[] memory tokenIds)
  {
    uint256 ownerTokenCount = balanceOf(owner);

    tokenIds = new uint256[](ownerTokenCount);
    uint256 start;
    uint256 idx;

    while (start < ownerTokenCount) {
        uint256 tokenId = tokenOfOwnerByIndex(owner, idx);
        tokenIds[start] = tokenId;
        ++start;
        ++idx;
    }
  }
}