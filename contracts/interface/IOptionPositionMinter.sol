//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface IOptionPositionMinter is IERC721Enumerable {
    function mint(address to) external returns (uint256 tokenId);

    function burnToken(uint256 tokenId) external;
}