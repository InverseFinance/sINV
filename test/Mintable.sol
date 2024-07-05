pragma solidity ^0.8.21;

import "lib/solmate/src/tokens/ERC20.sol";

contract Mintable is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {
    
    }

    function mint(address to, uint amount) external {
        _mint(to, amount);
    }

}
