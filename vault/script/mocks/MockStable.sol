// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockStable
 * @notice Minimal mintable ERC20 with configurable decimals, for TESTNET deployment only.
 *         Real USDC/USDT do not exist at canonical addresses on Sepolia, so the Sepolia deploy
 *         stands up two of these (6-dp, like the real stables) to back the vault pool + deposits.
 * @dev Open `mint` — anyone can mint. NEVER deploy to a production chain.
 */
contract MockStable is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
