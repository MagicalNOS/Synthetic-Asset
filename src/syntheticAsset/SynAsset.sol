// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ISynAsset} from "../interfaces/ISynAsset.sol";

abstract contract SynAsset is ERC20, AccessControl, ISynAsset {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    function totalSupply()
        public
        view
        override(ISynAsset, ERC20)
        returns (uint256)
    {
        return super.totalSupply();
    }

    // Abstract function to be implemented by specific assets
    function anchorAddress() external view virtual returns (address);
}
