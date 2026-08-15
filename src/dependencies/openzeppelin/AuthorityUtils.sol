// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (access/manager/AuthorityUtils.sol)

pragma solidity ^0.8.20;

import {IAuthority} from "./IAuthority.sol";

library AuthorityUtils {
    /**
     * @dev Since `AccessManager` implements an extended IAuthority interface, invoking `canCall` with backwards compatibility
     * for the preexisting `IAuthority` interface requires special care to avoid reverting on insufficient return data.
     * This helper function takes care of invoking `canCall` in a backwards compatible way without reverting.
     */
    function canCallWithDelay(address authority, address caller, address target, bytes4 selector)
        internal
        view
        returns (bool immediate, uint32 delay)
    {
        //@note
        //Intention
        //  1) Reset tmp pointer 0x00, 0x20
        //  2) authority.canCall(caller, target, selector)
        //  3) If call success -> immediate = mload(0x00)
        //                        delay = mload(0x20) > uint32_max ? 0 : mload(0x20)
        //Follow-up
        //  3) Why IAuthority.canCall just return bool but staticall() return immediate and delay?
        //    -> backward compatibility with AuthorityUtils in OpenZeppelin Contracts v5.3.0, which returns (bool, uint32).
        //  3) return bool take 1 word?
        //    -> Yes. https://docs.soliditylang.org/en/latest/abi-spec.html#function-selector-and-argument-encoding.

        bytes memory data = abi.encodeCall(IAuthority.canCall, (caller, target, selector));

        assembly ("memory-safe") {
            //1 {
            mstore(0x00, 0x00)
            mstore(0x20, 0x00)
            //} 1

            //2 {
            if staticcall(gas(), authority, add(data, 0x20), mload(data), 0x00, 0x40) {
                immediate := mload(0x00)
                delay := mload(0x20)

                // If delay does not fit in a uint32, return 0 (no delay)
                // equivalent to: if gt(delay, 0xFFFFFFFF) { delay := 0 }
                delay := mul(delay, iszero(shr(32, delay)))
            }
            //} 2
        }
    }
}
