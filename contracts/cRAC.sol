//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract cRAC is ERC20 {
    constructor() ERC20("RAC", "RAC") {
        //sends the contract $1000 to begin
        _mint(msg.sender, 1000 * 10 ** decimals());
    }
}