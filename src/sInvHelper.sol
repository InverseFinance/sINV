interface IsInv {
    function asset() external view returns (address);
    function getInvReserve() external view returns (uint);
    function getInvReserve(uint dbrReserve) external view returns (uint);
    function getDbrReserve() external view returns (uint);
    function buyDBR(uint exactInvIn, uint exactDbrOut, address to) external;
}

interface IERC20 {
    function approve(address,uint) external returns (bool);
    function transferFrom(address,address,uint) external returns (bool);
}

contract sInvHelper {

    IsInv public immutable sInv;
    IERC20 public immutable inv;

    constructor(
        address _sInv
    ) {
        sInv = IsInv(_sInv);
        inv = IERC20(sInv.asset());
        inv.approve(_sInv, type(uint).max);
    }

    function getDbrOut(uint invIn) public view returns (uint dbrOut) {
        require(invIn > 0, "invIn must be positive");
        uint dbrReserve = sInv.getDbrReserve();
        uint invReserve = sInv.getInvReserve(dbrReserve);
        uint numerator = invIn * dbrReserve;
        uint denominator = invReserve + invIn;
        dbrOut = numerator / denominator;
    }

    function getInvIn(uint dbrOut) public view returns (uint invIn) {
        require(dbrOut > 0, "dbrOut must be positive");
        uint dbrReserve = sInv.getDbrReserve();
        uint invReserve = sInv.getInvReserve(dbrReserve);
        uint numerator = dbrOut * invReserve;
        uint denominator = dbrReserve - dbrOut;
        invIn = (numerator / denominator) + 1;
    }

    function swapExactInvForDbr(uint invIn, uint dbrOutMin) external returns (uint dbrOut) {
        dbrOut = getDbrOut(invIn);
        require(dbrOut >= dbrOutMin, "dbrOut must be greater than dbrOutMin");
        inv.transferFrom(msg.sender, address(this), invIn);
        sInv.buyDBR(invIn, dbrOut, msg.sender);
    }

    function swapInvForExactDbr(uint dbrOut, uint invInMax) external returns (uint invIn) {
        invIn = getInvIn(dbrOut);
        require(invIn <= invInMax, "invIn must be less than invInMax");
        inv.transferFrom(msg.sender, address(this), invIn);
        sInv.buyDBR(invIn, dbrOut, msg.sender);
    }

}
