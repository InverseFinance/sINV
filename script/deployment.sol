pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {sINV} from "src/sInv.sol";

contract DeploymentScript is Script {
    function run() external {
        uint deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address inv = 0x41D5D79431A913C4aE7d69a668ecdfE5fF9DFB68;
        address invMarket = 0xb516247596Ca36bf32876199FBdCaD6B3322330B;
        address gov = 0x926dF14a23BE491164dCF93f4c468A50ef659D5B;
        address guardian = 0x4b6c63E6a94ef26E2dF60b89372db2d8e211F1B7;
        uint depositLimit = 10_000 ether;
        uint K = 2.5 * 1e44;
        vm.startBroadcast(deployerPrivateKey);
        sINV sInv = new sINV(inv, invMarket, gov, guardian, depositLimit, K);
        vm.stopBroadcast();
    }
}
