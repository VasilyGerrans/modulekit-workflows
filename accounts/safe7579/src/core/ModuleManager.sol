// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { SentinelListLib } from "sentinellist/SentinelList.sol";
import { SentinelList4337Lib } from "sentinellist/SentinelList4337.sol";
import { IModule } from "erc7579/interfaces/IERC7579Module.sol";
import { ExecutionHelper } from "./ExecutionHelper.sol";
import { Receiver } from "erc7579/core/Receiver.sol";
import { AccessControl } from "./AccessControl.sol";

struct ModuleManagerStorage {
    // linked list of executors. List is initialized by initializeAccount()
    SentinelListLib.SentinelList _executors;
    // single fallback handler for all fallbacks
    address fallbackHandler;
}

/**
 * @title ModuleManager
 * Contract that implements ERC7579 Module compatibility for Safe accounts
 * @author zeroknots.eth | rhinestone.wtf
 */
abstract contract ModuleManager is AccessControl, Receiver, ExecutionHelper {
    using SentinelListLib for SentinelListLib.SentinelList;
    using SentinelList4337Lib for SentinelList4337Lib.SentinelList;

    error InvalidModule(address module);
    error LinkedListError();
    error CannotRemoveLastValidator();
    error InitializerError();
    error ValidatorStorageHelperError();
    error NoFallbackHandler();

    mapping(address smartAccount => ModuleManagerStorage moduleManagerStorage) internal
        $moduleManager;

    SentinelList4337Lib.SentinelList internal $validators;

    modifier onlyExecutorModule() {
        if (!_isExecutorInstalled(_msgSender())) revert InvalidModule(_msgSender());
        _;
    }

    /**
     * Initializes linked list that handles installed Validator and Executor
     */
    function _initModuleManager() internal {
        ModuleManagerStorage storage $mms = $moduleManager[msg.sender];
        // this will revert if list is already initialized
        $validators.init({ account: msg.sender });
        $mms._executors.init();
    }

    /////////////////////////////////////////////////////
    //  Manage Validators
    ////////////////////////////////////////////////////
    /**
     * install and initialize validator module
     */
    function _installValidator(address validator, bytes memory data) internal virtual {
        $validators.push({ account: msg.sender, newEntry: validator });

        // Initialize Validator Module via Safe
        _execute({
            safe: msg.sender,
            target: validator,
            value: 0,
            callData: abi.encodeCall(IModule.onInstall, (data))
        });
    }

    /**
     * Uninstall and de-initialize validator module
     */
    function _uninstallValidator(address validator, bytes memory data) internal {
        (address prev, bytes memory disableModuleData) = abi.decode(data, (address, bytes));
        $validators.pop({ account: msg.sender, prevEntry: prev, popEntry: validator });

        // De-Initialize Validator Module via Safe
        _execute({
            safe: msg.sender,
            target: validator,
            value: 0,
            callData: abi.encodeCall(IModule.onUninstall, (disableModuleData))
        });
    }

    /**
     * Helper function that will calculate storage slot for
     * validator address within the linked list in ValidatorStorageHelper
     * and use Safe's getStorageAt() to read 32bytes from Safe's storage
     */
    function _isValidatorInstalled(address validator)
        internal
        view
        virtual
        returns (bool isInstalled)
    {
        isInstalled = $validators.contains({ account: msg.sender, entry: validator });
    }

    function getValidatorPaginated(
        address start,
        uint256 pageSize
    )
        external
        view
        virtual
        returns (address[] memory array, address next)
    {
        return $validators.getEntriesPaginated({
            account: msg.sender,
            start: start,
            pageSize: pageSize
        });
    }

    /////////////////////////////////////////////////////
    //  Manage Executors
    ////////////////////////////////////////////////////

    function _installExecutor(address executor, bytes memory data) internal {
        SentinelListLib.SentinelList storage $executors = $moduleManager[msg.sender]._executors;
        $executors.push(executor);
        // Initialize Executor Module via Safe
        _execute({
            safe: msg.sender,
            target: executor,
            value: 0,
            callData: abi.encodeCall(IModule.onInstall, (data))
        });
    }

    function _uninstallExecutor(address executor, bytes calldata data) internal {
        SentinelListLib.SentinelList storage $executors = $moduleManager[msg.sender]._executors;
        (address prev, bytes memory disableModuleData) = abi.decode(data, (address, bytes));
        $executors.pop(prev, executor);

        // De-Initialize Executor Module via Safe
        _execute({
            safe: msg.sender,
            target: executor,
            value: 0,
            callData: abi.encodeCall(IModule.onUninstall, (disableModuleData))
        });
    }

    function _isExecutorInstalled(address executor) internal view virtual returns (bool) {
        SentinelListLib.SentinelList storage $executors = $moduleManager[msg.sender]._executors;
        return $executors.contains(executor);
    }

    /**
     * THIS IS NOT PART OF THE STANDARD
     * Helper Function to access linked list
     */
    function getExecutorsPaginated(
        address cursor,
        uint256 size
    )
        external
        view
        virtual
        returns (address[] memory array, address next)
    {
        SentinelListLib.SentinelList storage $executors = $moduleManager[msg.sender]._executors;
        return $executors.getEntriesPaginated(cursor, size);
    }

    /////////////////////////////////////////////////////
    //  Manage Fallback
    ////////////////////////////////////////////////////
    function _installFallbackHandler(address handler, bytes calldata initData) internal virtual {
        ModuleManagerStorage storage $mms = $moduleManager[msg.sender];
        $mms.fallbackHandler = handler;
        // Initialize Fallback Module via Safe
        _execute({
            safe: msg.sender,
            target: handler,
            value: 0,
            callData: abi.encodeCall(IModule.onInstall, (initData))
        });
    }

    function _uninstallFallbackHandler(address handler, bytes calldata initData) internal virtual {
        ModuleManagerStorage storage $mms = $moduleManager[msg.sender];
        $mms.fallbackHandler = address(0);
        // De-Initialize Fallback Module via Safe
        _execute({
            safe: msg.sender,
            target: handler,
            value: 0,
            callData: abi.encodeCall(IModule.onUninstall, (initData))
        });
    }

    function _getFallbackHandler() internal view virtual returns (address fallbackHandler) {
        ModuleManagerStorage storage $mms = $moduleManager[msg.sender];
        return $mms.fallbackHandler;
    }

    function _isFallbackHandlerInstalled(address _handler) internal view virtual returns (bool) {
        return _getFallbackHandler() == _handler;
    }

    function getActiveFallbackHandler() external view virtual returns (address) {
        return _getFallbackHandler();
    }

    // FALLBACK
    // solhint-disable-next-line no-complex-fallback
    fallback() external payable override(Receiver) receiverFallback {
        address handler = _getFallbackHandler();
        if (handler == address(0)) revert NoFallbackHandler();
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // When compiled with the optimizer, the compiler relies on a certain assumptions on how
            // the
            // memory is used, therefore we need to guarantee memory safety (keeping the free memory
            // point 0x40 slot intact,
            // not going beyond the scratch space, etc)
            // Solidity docs: https://docs.soliditylang.org/en/latest/assembly.html#memory-safety
            function allocate(length) -> pos {
                pos := mload(0x40)
                mstore(0x40, add(pos, length))
            }

            let calldataPtr := allocate(calldatasize())
            calldatacopy(calldataPtr, 0, calldatasize())

            // The msg.sender address is shifted to the left by 12 bytes to remove the padding
            // Then the address without padding is stored right after the calldata
            let senderPtr := allocate(20)
            mstore(senderPtr, shl(96, caller()))

            // Add 20 bytes for the address appended add the end
            let success := call(gas(), handler, 0, calldataPtr, add(calldatasize(), 20), 0, 0)

            let returnDataPtr := allocate(returndatasize())
            returndatacopy(returnDataPtr, 0, returndatasize())
            if iszero(success) { revert(returnDataPtr, returndatasize()) }
            return(returnDataPtr, returndatasize())
        }
        /* solhint-enable no-inline-assembly */
    }
}
